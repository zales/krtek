//! The S3 driver: buckets as tables, objects as rows.
//!
//! No SDK. S3 is a REST API - list a bucket with a GET, fetch an object with a
//! GET, put one with a PUT - so what it takes is an HTTP client, a signature and
//! enough XML to read four kinds of reply, all of which are files of their own
//! here and none of which needs a network to be tested:
//!
//! * `http.zig` and `net.zig` - the socket, the TLS and HTTP/1.1, shared with
//!   whatever speaks HTTP next.
//! * `s3/sigv4.zig` - the signature, against Amazon's own worked examples.
//! * `xml.zig` - a pull parser for the replies, shared with the other store.
//! * `s3/target.zig` - what `s3://key@host:9000/bucket` means, and where the
//!   credentials come from when it says nothing.
//!
//! **A bucket is a table and an object is a row**, with `key`, `size`,
//! `modified`, `etag` and `storage` for columns. That mapping is closer than
//! Kafka's: keys come back sorted, a prefix is a `WHERE key LIKE 'a/b%'`, and a
//! key addresses a row exactly. What it will not do is pretend to be SQL - there
//! is no join, no aggregate, and no way to filter on anything but the key,
//! because ListObjectsV2 takes a prefix and nothing else. A filter S3 cannot
//! honour is refused with the reason rather than answered wrongly.
//!
//! **The body of an object is not in the grid.** A listing that fetched every
//! object to show it would cost one request per row and download the bucket to
//! draw a screen. So the grid shows what a listing gives, and `GET key` in the
//! editor - which is an S3 console - brings one object back as a value, which
//! means an image is shown as an image and anything else as hex, by the same code
//! that does it for a BLOB.
//!
//! **Paging is by continuation token, which only goes forwards.** S3 has no
//! OFFSET: page five is reached by asking for pages one to four and keeping the
//! token each one ends with. Those tokens are kept, so paging forward through a
//! bucket costs one request a page and going back costs nothing.

const std = @import("std");
const db = @import("db.zig");
const typed = @import("typed.zig");
const http = @import("http.zig");

pub const sigv4 = @import("s3/sigv4.zig");
pub const xml = @import("xml.zig");
pub const address = @import("s3/target.zig");

const List = db.List;

comptime {
    _ = sigv4;
    _ = xml;
    _ = address;
}

pub const owns = address.owns;
pub const parse = address.parse;
pub const Parts = address.Parts;

pub const KEY = "key";
pub const SIZE = "size";
pub const MODIFIED = "modified";
pub const ETAG = "etag";
pub const STORAGE = "storage";

const COLUMNS = [_][]const u8{ KEY, SIZE, MODIFIED, ETAG, STORAGE };
const NUMERIC = [_]bool{ false, true, false, false, false };

/// How many keys one page of the grid asks for when nobody said.
const PAGE: usize = 200;
/// How many pages counting will walk through before answering "who knows". A
/// bucket with millions of keys cannot be counted at all, and asking a hundred
/// times to find that out helps nobody.
const COUNT_PAGES: usize = 20;
/// How much of an object the console will bring back in one go.
const GET_LIMIT: usize = 32 << 20;
/// How long a link made with `URL` lasts.
const LINK_SECONDS: u32 = 3600;
/// How much of an object one range asks for while it is being copied. Large
/// enough that a gigabyte is a few dozen requests rather than thousands, small
/// enough that giving up on a copy does not waste much.
const RANGE: usize = 8 << 20;
/// How large an object this will send. One request carries the whole thing and
/// has to be signed over it, so this is a real ceiling until multipart uploads
/// are written - and it says so rather than failing halfway.
const UPLOAD_LIMIT: usize = 256 << 20;

pub const Db = struct {
    allocator: std.mem.Allocator,
    /// Owns everything in `parts`, which lives as long as the connection.
    home: std.heap.ArenaAllocator,
    parts: Parts = .{},
    /// One connection per host: a bucket addressed as `bucket.s3.amazonaws.com`
    /// is a different server from the one that lists the buckets.
    clients: std.StringHashMapUnmanaged(*http.Client) = .empty,
    label: List = .empty,
    version_text: List = .empty,
    last_error: List = .empty,
    progress: ?db.Progress = null,
    /// Counted because every screen is requests, and knowing how many is the
    /// difference between a slow bucket and a slow driver.
    requests: usize = 0,
    /// Rows and everything they point at, until the next statement.
    replies: std.heap.ArenaAllocator,
    pages: Pages,

    pub fn open(allocator: std.mem.Allocator, target: []const u8, report: *List) !*Db {
        const self = try allocator.create(Db);
        self.* = .{
            .allocator = allocator,
            .home = std.heap.ArenaAllocator.init(allocator),
            .replies = std.heap.ArenaAllocator.init(allocator),
            .pages = .{ .arena = std.heap.ArenaAllocator.init(allocator) },
        };
        errdefer self.close();

        const home = self.home.allocator();
        self.parts = address.parse(home, target) catch {
            try report.appendSlice(allocator, "that is not an s3 target");
            return error.Driver;
        };
        address.resolve(home, &self.parts) catch {};
        self.relabel();
        // A key with no secret is somebody who means to be asked for one: the word
        // "secret key" is what makes the interface offer the prompt.
        if (self.parts.key.len != 0 and self.parts.secret.len == 0) {
            try report.print(allocator, "the secret key for {s} is missing", .{self.parts.key});
            return error.Driver;
        }

        // One request before anything else, so a wrong key or a bucket that is not
        // there is said here rather than halfway through the first screen.
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const response = self.call(arena, if (self.parts.bucket.len != 0) .{
            .bucket = self.parts.bucket,
            .query = &.{ .{ .name = "list-type", .value = "2" }, .{ .name = "max-keys", .value = "1" } },
        } else .{}) catch {
            try report.appendSlice(allocator, self.message());
            return error.Driver;
        };
        if (!response.ok()) {
            const why = self.fail(response);
            try report.appendSlice(allocator, self.message());
            return why;
        }
        try self.version_text.appendSlice(allocator, serverName(response.get("server")));
        return self;
    }

    pub fn close(self: *Db) void {
        var walk = self.clients.iterator();
        while (walk.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.clients.deinit(self.allocator);
        self.label.deinit(self.allocator);
        self.version_text.deinit(self.allocator);
        self.last_error.deinit(self.allocator);
        self.pages.arena.deinit();
        self.replies.deinit();
        self.home.deinit();
        self.allocator.destroy(self);
    }

    pub fn watch(self: *Db, progress: ?db.Progress) void {
        self.progress = progress;
        var walk = self.clients.valueIterator();
        while (walk.next()) |client| {
            client.*.watch(progress);
        }
    }

    pub fn caps(_: *Db) db.Caps {
        return .{
            // A bucket is a table, so there is nothing left for a schema to be.
            .schemas = false,
            .hidden_row_id = false,
            .rebuild_to_alter = false,
            .databases = false,
            .label = "S3",
            .speaks_sql = false,
            .no_ddl = "a bucket is a decision about where data lives and what it costs, which is not a key press - and an object is a file, not a table",
            // A dump of keys without their objects is a list, and replaying it would
            // put empty objects where the data was.
            .dumps_rows = false,
        };
    }

    pub fn version(self: *Db) []const u8 {
        return self.version_text.items;
    }

    pub fn describe(self: *Db) []const u8 {
        return self.label.items;
    }

    pub fn message(self: *Db) []const u8 {
        return self.last_error.items;
    }

    fn relabel(self: *Db) void {
        self.label.clearRetainingCapacity();
        if (self.parts.bucket.len != 0) {
            self.label.print(self.allocator, "{s}/{s}", .{ self.parts.endpoint, self.parts.bucket }) catch {};
        } else {
            self.label.appendSlice(self.allocator, self.parts.endpoint) catch {};
        }
    }

    fn remember(self: *Db, text: []const u8) void {
        self.last_error.clearRetainingCapacity();
        self.last_error.appendSlice(self.allocator, text) catch {};
    }

    fn complain(self: *Db, comptime format: []const u8, args: anytype) void {
        self.last_error.clearRetainingCapacity();
        self.last_error.print(self.allocator, format, args) catch {};
    }

    /// A statement is starting: the spinner is told, and the last reply is let go.
    fn begin(self: *Db) void {
        if (self.progress) |progress| {
            progress.starting();
        }
        self.last_error.clearRetainingCapacity();
        _ = self.replies.reset(.retain_capacity);
    }

    // ------------------------------------------------------------- requests

    /// One request, as this driver thinks of it: which bucket, which key, what to
    /// put in the query. The host, the path, the signature and the headers follow
    /// from those and from the target.
    const Call = struct {
        method: []const u8 = "GET",
        bucket: []const u8 = "",
        key: []const u8 = "",
        query: []const sigv4.Param = &.{},
        headers: []const sigv4.Header = &.{},
        body: []const u8 = "",
        limit: usize = http.BODY_LIMIT,
    };

    /// Send it and bring back whatever came, whatever its status: a 404 is an
    /// answer and some callers want to see it. Only a connection that failed is an
    /// error here.
    fn call(self: *Db, arena: std.mem.Allocator, request: Call) db.Error!http.Response {
        var redirected = false;
        while (true) {
            const host = try self.hostFor(arena, request.bucket);
            const client = try self.clientFor(host);
            const path = try self.pathFor(arena, request.bucket, request.key);

            var payload: [64]u8 = undefined;
            sigv4.hashHex(&payload, request.body);

            var signing: std.ArrayListUnmanaged(sigv4.Header) = .empty;
            try signing.append(arena, .{ .name = "host", .value = try self.hostHeader(arena, host) });
            try signing.appendSlice(arena, request.headers);

            var headers: std.ArrayListUnmanaged(http.Header) = .empty;
            var params: []const u8 = "";
            if (self.parts.anonymous()) {
                // A public bucket takes an unsigned request, and there is nothing to
                // sign with anyway. The 403 that follows on a private one says so.
                params = try sigv4.renderQuery(arena, request.query);
                for (signing.items) |header| {
                    try headers.append(arena, .{ .name = header.name, .value = header.value });
                }
            } else {
                const signed = sigv4.sign(arena, .{
                    .key = self.parts.key,
                    .secret = self.parts.secret,
                    .token = self.parts.token,
                }, .{
                    .method = request.method,
                    .path = path,
                    .query = request.query,
                    .headers = signing.items,
                    .payload = &payload,
                }, self.parts.region, "s3", sigv4.now()) catch {
                    self.remember("the request could not be signed - is the secret key right?");
                    return error.Driver;
                };
                params = signed.query;
                for (signed.headers) |header| {
                    try headers.append(arena, .{ .name = header.name, .value = header.value });
                }
                try headers.append(arena, .{ .name = "Authorization", .value = signed.authorization });
            }

            const target = if (params.len != 0)
                try std.fmt.allocPrint(arena, "{s}?{s}", .{ path, params })
            else
                path;

            self.requests += 1;
            const response = client.send(arena, .{
                .method = request.method,
                .target = target,
                .headers = headers.items,
                .body = request.body,
                .limit = request.limit,
            }) catch |err| {
                switch (err) {
                    error.GivenUp => self.remember("given up on"),
                    error.TooLarge => self.complain("that object is larger than the {d} MB this will hold - fetch it with a tool that streams", .{request.limit >> 20}),
                    error.Malformed => self.complain("{s} answered something that is not HTTP", .{self.parts.endpoint}),
                    else => {
                        const why = client.message();
                        if (why.len != 0) {
                            self.remember(why);
                        } else {
                            self.complain("the connection to {s} is gone", .{self.parts.endpoint});
                        }
                    },
                }
                return error.Driver;
            };

            // A bucket in another region answers with the region it is in, once.
            // Following it is the difference between working and a 301 nobody can
            // read.
            if (!redirected and (response.status == 301 or response.status == 307 or response.status == 400)) {
                if (response.get("x-amz-bucket-region")) |region| {
                    if (region.len != 0 and !std.mem.eql(u8, region, self.parts.region)) {
                        try self.moveTo(region);
                        redirected = true;
                        continue;
                    }
                }
            }
            return response;
        }
    }

    /// Adopt the region the server named, and with it the endpoint if the one in
    /// use was only ever a guess from the old region.
    fn moveTo(self: *Db, region: []const u8) db.Error!void {
        const home = self.home.allocator();
        const was_default = std.mem.eql(u8, self.parts.endpoint, try address.amazonEndpoint(home, self.parts.region));
        self.parts.region = try home.dupe(u8, region);
        if (was_default) {
            self.parts.endpoint = try address.amazonEndpoint(home, region);
            var walk = self.clients.iterator();
            while (walk.next()) |entry| {
                entry.value_ptr.*.deinit();
                self.allocator.destroy(entry.value_ptr.*);
                self.allocator.free(entry.key_ptr.*);
            }
            self.clients.clearRetainingCapacity();
            self.relabel();
        }
    }

    fn hostFor(self: *Db, arena: std.mem.Allocator, bucket: []const u8) db.Error![]const u8 {
        if (bucket.len == 0 or self.parts.path_style) {
            return self.parts.endpoint;
        }
        return std.fmt.allocPrint(arena, "{s}.{s}", .{ bucket, self.parts.endpoint });
    }

    /// The `Host` header, which carries the port unless it is the usual one - and
    /// which is signed, so it has to be exactly what the server will see.
    fn hostHeader(self: *Db, arena: std.mem.Allocator, host: []const u8) db.Error![]const u8 {
        if (self.parts.port == http.defaultPort(self.parts.tls)) {
            return host;
        }
        return std.fmt.allocPrint(arena, "{s}:{d}", .{ host, self.parts.port });
    }

    fn pathFor(self: *Db, arena: std.mem.Allocator, bucket: []const u8, key: []const u8) db.Error![]const u8 {
        const tail = try sigv4.escapePath(arena, key);
        if (bucket.len == 0 or !self.parts.path_style) {
            return tail;
        }
        return std.fmt.allocPrint(arena, "/{s}{s}", .{ bucket, if (tail.len == 1) "" else tail });
    }

    fn clientFor(self: *Db, host: []const u8) db.Error!*http.Client {
        if (self.clients.get(host)) |found| {
            return found;
        }
        const made = try self.allocator.create(http.Client);
        errdefer self.allocator.destroy(made);
        made.* = try http.Client.init(self.allocator, host, self.parts.port, self.parts.tls, self.parts.verify);
        made.watch(self.progress);
        errdefer made.deinit();
        const owned = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(owned);
        try self.clients.put(self.allocator, owned, made);
        return made;
    }

    /// Turn a reply that is not a success into the message the interface shows.
    /// S3 puts a code and a sentence in the body; when it does not, the status is
    /// all there is.
    fn fail(self: *Db, response: http.Response) db.Error {
        const code = xml.find(response.body, "Code");
        const detail = xml.find(response.body, "Message");
        if (code) |name| {
            self.complain("{s}{s}{s}", .{
                name,
                if (detail != null and detail.?.len != 0) ": " else "",
                detail orelse "",
            });
        } else if (response.status == 404) {
            self.remember("there is nothing there");
        } else {
            self.complain("the server answered {d} {s}", .{ response.status, response.reason });
        }
        if (response.status == 403 and self.parts.anonymous()) {
            self.last_error.appendSlice(
                self.allocator,
                " - no credentials were found: put them in the target, in AWS_ACCESS_KEY_ID, or in ~/.aws/credentials",
            ) catch {};
        }
        return error.Driver;
    }

    // -------------------------------------------------------------- listing

    const Entry = struct {
        key: []const u8 = "",
        size: i64 = 0,
        modified: []const u8 = "",
        etag: []const u8 = "",
        storage: []const u8 = "",
    };

    const Listing = struct {
        entries: []const Entry = &.{},
        /// The prefixes one level down, which is what a bucket has instead of
        /// directories. Only filled in when the listing asked for a delimiter.
        folders: []const []const u8 = &.{},
        /// What to ask for to get the next page, or null when this was the last.
        next: ?[]const u8 = null,
    };

    fn list(
        self: *Db,
        arena: std.mem.Allocator,
        bucket: []const u8,
        prefix: []const u8,
        token: []const u8,
        limit: usize,
    ) db.Error!Listing {
        return self.listPage(arena, bucket, prefix, token, limit, false);
    }

    /// `folded` asks S3 to stop at each slash and report what is below as a
    /// prefix. A grid wants every key, because a bucket is one flat table there;
    /// the file manager wants one level, because that is what a directory is.
    fn listPage(
        self: *Db,
        arena: std.mem.Allocator,
        bucket: []const u8,
        prefix: []const u8,
        token: []const u8,
        limit: usize,
        folded: bool,
    ) db.Error!Listing {
        var params: std.ArrayListUnmanaged(sigv4.Param) = .empty;
        try params.append(arena, .{ .name = "list-type", .value = "2" });
        // Keys may hold anything, including bytes XML cannot carry; asked for
        // escaped, they always come back readable.
        try params.append(arena, .{ .name = "encoding-type", .value = "url" });
        try params.append(arena, .{
            .name = "max-keys",
            .value = try std.fmt.allocPrint(arena, "{d}", .{limit}),
        });
        if (prefix.len != 0) {
            try params.append(arena, .{ .name = "prefix", .value = prefix });
        }
        if (folded) {
            try params.append(arena, .{ .name = "delimiter", .value = "/" });
        }
        if (token.len != 0) {
            try params.append(arena, .{ .name = "continuation-token", .value = token });
        }
        const response = try self.call(arena, .{ .bucket = bucket, .query = params.items });
        if (!response.ok()) {
            return self.fail(response);
        }
        return parseListing(arena, response.body);
    }

    /// Where a page starts, for a bucket S3 will only page forwards through.
    ///
    /// Null means there is no such page: the listing ended before it. The tokens
    /// already walked past are kept, so going back a page and forward again costs
    /// nothing, and a page further on costs the pages between - which is what S3
    /// charges either way.
    fn tokenFor(
        self: *Db,
        bucket: []const u8,
        prefix: []const u8,
        size: usize,
        page: usize,
    ) db.Error!?[]const u8 {
        if (!self.pages.matches(bucket, prefix, size)) {
            try self.pages.restart(bucket, prefix, size);
        }
        while (self.pages.tokens.items.len <= page) {
            if (self.pages.ended) {
                return null;
            }
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            const last = self.pages.tokens.items[self.pages.tokens.items.len - 1];
            const walked = try self.list(scratch.allocator(), bucket, prefix, last, size);
            const next = walked.next orelse {
                self.pages.ended = true;
                return null;
            };
            const kept = self.pages.arena.allocator();
            try self.pages.tokens.append(kept, try kept.dupe(u8, next));
        }
        return self.pages.tokens.items[page];
    }

    // ------------------------------------------------------ the interface

    pub fn exec(self: *Db, sql: []const u8) db.Error!void {
        var rows = (try self.query(sql, null)) orelse return;
        rows.close();
    }

    /// A line typed in the editor, which for S3 is a console.
    pub fn query(self: *Db, sql: []const u8, rest: ?*[]const u8) db.Error!?db.Rows {
        if (rest) |out| {
            out.* = sql[sql.len..];
        }
        const trimmed = std.mem.trim(u8, sql, " \t\r\n;");
        if (trimmed.len == 0) {
            return null;
        }
        self.begin();
        return .{ .s3 = try self.console(trimmed) };
    }

    pub fn select(self: *Db, request: db.ask.Select) db.Error!?db.Rows {
        self.begin();
        const bucket = if (request.table.name.len != 0) request.table.name else self.parts.bucket;
        if (bucket.len == 0) {
            self.remember("which bucket? name one in the target, or pick one from the list");
            return error.Driver;
        }
        if (request.where_text.len != 0) {
            self.remember("a raw WHERE is SQL - S3 filters by key prefix only, with key LIKE 'a/b%'");
            return error.Driver;
        }
        if (request.order.len != 0 and !std.mem.eql(u8, request.order, KEY)) {
            self.complain("S3 gives back keys in order and cannot sort by {s}", .{request.order});
            return error.Driver;
        }
        if (request.descending) {
            self.remember("S3 lists keys in order and cannot reverse them");
            return error.Driver;
        }

        const arena = self.replies.allocator();
        const wanted = try self.whereOf(arena, request.where);

        // One key named exactly: that is a HEAD, not a listing.
        if (wanted.exact) |key| {
            var rows = self.newRows(bucket);
            const response = try self.call(arena, .{ .method = "HEAD", .bucket = bucket, .key = key });
            if (response.status == 404) {
                return .{ .s3 = if (request.count) try self.oneNumber("keys", 0) else rows };
            }
            if (!response.ok()) {
                return self.fail(response);
            }
            if (request.count) {
                return .{ .s3 = try self.oneNumber("keys", 1) };
            }
            try rows.add(&.{
                .{ .text = key },
                .{ .number = std.fmt.parseInt(i64, response.get("content-length") orelse "0", 10) catch 0 },
                .{ .text = response.get("last-modified") orelse "" },
                .{ .text = trimQuotes(response.get("etag") orelse "") },
                .{ .text = response.get("x-amz-storage-class") orelse "STANDARD" },
            });
            return .{ .s3 = rows };
        }

        const limit = if (request.limit != 0) request.limit else PAGE;
        if (request.count) {
            return .{ .s3 = try self.counting(bucket, wanted.prefix) };
        }

        const page = request.offset / limit;
        const token = (try self.tokenFor(bucket, wanted.prefix, limit, page)) orelse
            return .{ .s3 = self.newRows(bucket) };
        const listing = try self.list(arena, bucket, wanted.prefix, token, limit);
        var rows = self.newRows(bucket);
        for (listing.entries) |entry| {
            try rows.add(&.{
                .{ .text = entry.key },
                .{ .number = entry.size },
                .{ .text = entry.modified },
                .{ .text = entry.etag },
                .{ .text = entry.storage },
            });
        }
        return .{ .s3 = rows };
    }

    /// How many keys there are, where that can be found out at all: S3 has no
    /// count, so this is the listing walked through - and given up on rather than
    /// walked through a million times.
    fn counting(self: *Db, bucket: []const u8, prefix: []const u8) db.Error!Rows {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        var total: i64 = 0;
        var token: []const u8 = "";
        var page: usize = 0;
        while (page < COUNT_PAGES) : (page += 1) {
            const listing = try self.list(arena, bucket, prefix, token, 1000);
            total += @intCast(listing.entries.len);
            token = listing.next orelse return self.oneNumber("keys", total);
        }
        // More than this driver will count. Saying nothing is right: the interface
        // shows an unknown number of rows rather than a wrong one.
        return self.oneNil("keys");
    }

    pub fn apply(self: *Db, change: db.ask.Change) db.Error!void {
        self.begin();
        const bucket = if (change.table.name.len != 0) change.table.name else self.parts.bucket;
        if (bucket.len == 0) {
            self.remember("which bucket?");
            return error.Driver;
        }
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();

        switch (change.kind) {
            .delete => {
                const key = db.ask.only(change.where, KEY) orelse {
                    self.remember("which object? S3 addresses a row by its key");
                    return error.Driver;
                };
                const response = try self.call(arena, .{ .method = "DELETE", .bucket = bucket, .key = key });
                // S3 answers 204 whether or not it was there, which is what "deleted"
                // means to it.
                if (!response.ok()) {
                    return self.fail(response);
                }
                self.pages.forget();
            },
            .insert => {
                const key = flat(db.ask.valueOf(change.cells, KEY)) orelse "";
                if (key.len == 0) {
                    self.remember("an object needs a key");
                    return error.Driver;
                }
                // A row put in from the grid has no body to put with it: this makes
                // the key, empty. `PUT key text` in the console is how one gets
                // contents.
                const response = try self.call(arena, .{ .method = "PUT", .bucket = bucket, .key = key });
                if (!response.ok()) {
                    return self.fail(response);
                }
                self.pages.forget();
            },
            .update => {
                const key = db.ask.only(change.where, KEY) orelse {
                    self.remember("which object? S3 addresses a row by its key");
                    return error.Driver;
                };
                for ([_][]const u8{ SIZE, MODIFIED, ETAG }) |column| {
                    if (db.ask.valueOf(change.cells, column) != null) {
                        self.complain("{s} is the server's to say, not ours", .{column});
                        return error.Driver;
                    }
                }
                const renamed = flat(db.ask.valueOf(change.cells, KEY)) orelse "";
                const storage = flat(db.ask.valueOf(change.cells, STORAGE));
                if (renamed.len == 0 and storage == null) {
                    self.remember("nothing to change: an object's key and its storage class are what can be");
                    return error.Driver;
                }
                const target = if (renamed.len != 0) renamed else key;
                try self.copy(arena, bucket, key, target, storage);
                // S3 has no rename: what there is, is a copy and then a delete. Doing
                // it in that order is why a failure leaves the original where it was.
                if (renamed.len != 0 and !std.mem.eql(u8, renamed, key)) {
                    const gone = try self.call(arena, .{ .method = "DELETE", .bucket = bucket, .key = key });
                    if (!gone.ok()) {
                        return self.fail(gone);
                    }
                }
                self.pages.forget();
            },
        }
    }

    fn copy(
        self: *Db,
        arena: std.mem.Allocator,
        bucket: []const u8,
        from: []const u8,
        to: []const u8,
        storage: ?[]const u8,
    ) db.Error!void {
        var headers: std.ArrayListUnmanaged(sigv4.Header) = .empty;
        try headers.append(arena, .{
            .name = "x-amz-copy-source",
            .value = try std.fmt.allocPrint(arena, "/{s}{s}", .{ bucket, try sigv4.escapePath(arena, from) }),
        });
        if (storage) |class| {
            try headers.append(arena, .{ .name = "x-amz-storage-class", .value = class });
            try headers.append(arena, .{ .name = "x-amz-metadata-directive", .value = "COPY" });
        }
        const response = try self.call(arena, .{
            .method = "PUT",
            .bucket = bucket,
            .key = to,
            .headers = headers.items,
        });
        if (!response.ok()) {
            return self.fail(response);
        }
        // A copy can fail with a 200 and an error in the body, which is S3 keeping
        // the connection open while it works. Believing the status alone would
        // report a rename that did not happen.
        if (xml.find(response.body, "Code")) |code| {
            self.complain("the copy failed: {s}", .{code});
            return error.Driver;
        }
    }

    /// What a request comes to as a request, for the history and the report: the
    /// line that went to the server.
    pub fn wording(self: *Db, allocator: std.mem.Allocator, request: db.Request) db.Error![]u8 {
        var out: List = .empty;
        errdefer out.deinit(allocator);
        switch (request) {
            .select => |value| {
                const bucket = if (value.table.name.len != 0) value.table.name else self.parts.bucket;
                var scratch = std.heap.ArenaAllocator.init(allocator);
                defer scratch.deinit();
                const wanted = self.whereOf(scratch.allocator(), value.where) catch Where{};
                if (wanted.exact) |key| {
                    try out.print(allocator, "HEAD /{s}/{s}", .{ bucket, key });
                } else {
                    try out.print(allocator, "GET /{s}?list-type=2", .{bucket});
                    if (wanted.prefix.len != 0) {
                        try out.print(allocator, "&prefix={s}", .{wanted.prefix});
                    }
                    try out.print(allocator, "&max-keys={d}", .{if (value.limit != 0) value.limit else PAGE});
                    if (value.offset != 0) {
                        try out.print(allocator, " (page {d})", .{value.offset / @max(1, value.limit) + 1});
                    }
                }
            },
            .change => |value| {
                const bucket = if (value.table.name.len != 0) value.table.name else self.parts.bucket;
                const key = db.ask.only(value.where, KEY) orelse
                    flat(db.ask.valueOf(value.cells, KEY)) orelse "?";
                switch (value.kind) {
                    .delete => try out.print(allocator, "DELETE /{s}/{s}", .{ bucket, key }),
                    .insert => try out.print(allocator, "PUT /{s}/{s}", .{ bucket, key }),
                    .update => {
                        const renamed = flat(db.ask.valueOf(value.cells, KEY)) orelse key;
                        try out.print(allocator, "PUT /{s}/{s} (x-amz-copy-source: /{s}/{s})", .{ bucket, renamed, bucket, key });
                        if (!std.mem.eql(u8, renamed, key)) {
                            try out.print(allocator, " then DELETE /{s}/{s}", .{ bucket, key });
                        }
                    },
                }
            },
        }
        return out.toOwnedSlice(allocator);
    }

    /// What a filter comes to for S3: a prefix, one key, or a refusal.
    const Where = struct {
        prefix: []const u8 = "",
        exact: ?[]const u8 = null,
    };

    fn whereOf(self: *Db, arena: std.mem.Allocator, where: []const db.ask.Filter) db.Error!Where {
        var out = Where{};
        for (where) |filter| {
            if (!std.mem.eql(u8, filter.column, KEY)) {
                self.complain("S3 can only filter on the key; {s} is not something a listing knows", .{filter.column});
                return error.Driver;
            }
            switch (filter.op) {
                .eq => out.exact = try arena.dupe(u8, filter.value),
                .like => {
                    // A listing takes a prefix and nothing else, so `a/b%` works and
                    // `%b%` cannot - and saying so beats listing the bucket to filter it
                    // here and calling that the answer.
                    const pattern = filter.value;
                    const body = std.mem.trimEnd(u8, pattern, "%");
                    if (std.mem.indexOfAny(u8, body, "%_") != null) {
                        self.remember("S3 matches a prefix, not a pattern: key LIKE 'a/b%' is all it can do");
                        return error.Driver;
                    }
                    out.prefix = try arena.dupe(u8, body);
                },
                else => {
                    self.remember("S3 can compare a key with = or LIKE 'prefix%', and nothing else");
                    return error.Driver;
                },
            }
        }
        return out;
    }

    pub fn inTransaction(_: *Db) bool {
        return false;
    }

    pub fn schemas(_: *Db, arena: std.mem.Allocator) db.Error![][]const u8 {
        var list_of: std.ArrayListUnmanaged([]const u8) = .empty;
        return list_of.toOwnedSlice(arena);
    }

    /// The buckets, which are the tables. One named in the target is the only one
    /// shown, because a key that may see one bucket often may not list them all.
    pub fn objects(self: *Db, arena: std.mem.Allocator, _: []const u8) db.Error![]db.Object {
        if (self.parts.bucket.len != 0) {
            var out: std.ArrayListUnmanaged(db.Object) = .empty;
            try out.append(arena, .{ .name = try arena.dupe(u8, self.parts.bucket), .kind = .table });
            return out.items;
        }
        return self.buckets(arena);
    }

    /// Every bucket this key can see, whatever the target named.
    fn buckets(self: *Db, arena: std.mem.Allocator) db.Error![]db.Object {
        var out: std.ArrayListUnmanaged(db.Object) = .empty;
        const response = try self.call(arena, .{});
        if (!response.ok()) {
            return self.fail(response);
        }
        var reader = xml.Reader{ .text = response.body };
        var current: []const u8 = "";
        var inside = false;
        while (reader.next()) |event| {
            switch (event) {
                .open => |name| {
                    current = name;
                    if (std.mem.eql(u8, name, "Bucket")) {
                        inside = true;
                    }
                },
                .close => |name| {
                    if (std.mem.eql(u8, name, "Bucket")) {
                        inside = false;
                    }
                    current = "";
                },
                .text => |text| {
                    if (inside and std.mem.eql(u8, current, "Name")) {
                        try out.append(arena, .{ .name = try xml.unescape(arena, text), .kind = .table });
                    }
                },
            }
        }
        return out.items;
    }

    pub fn columns(_: *Db, arena: std.mem.Allocator, _: db.Table) db.Error![]db.Column {
        var out: std.ArrayListUnmanaged(db.Column) = .empty;
        try out.append(arena, .{ .name = KEY, .type = "string", .notnull = true, .pk = true, .original = KEY });
        try out.append(arena, .{ .name = SIZE, .type = "integer", .original = SIZE });
        try out.append(arena, .{ .name = MODIFIED, .type = "timestamp", .original = MODIFIED });
        try out.append(arena, .{ .name = ETAG, .type = "string", .original = ETAG });
        try out.append(arena, .{ .name = STORAGE, .type = "string", .original = STORAGE });
        return out.items;
    }

    pub fn indexes(_: *Db, arena: std.mem.Allocator, _: db.Table) db.Error![]db.Index {
        var out: std.ArrayListUnmanaged(db.Index) = .empty;
        try out.append(arena, .{ .name = KEY, .kind = "PRIMARY", .columns = KEY });
        return out.items;
    }

    pub fn foreignKeys(_: *Db, _: std.mem.Allocator, _: db.Table) db.Error![]db.ForeignKey {
        return &[_]db.ForeignKey{};
    }

    pub fn definition(_: *Db, _: std.mem.Allocator, _: db.Table) db.Error!?[]const u8 {
        return null;
    }

    /// One listing: exact for a bucket that fits in it, and unknown for one that
    /// does not - S3 has no count, and walking a million keys to draw a header is
    /// not a trade anybody would make. The interface draws `of ?` for that.
    pub fn rowCount(self: *Db, table: db.Table) ?i64 {
        const bucket = if (table.name.len != 0) table.name else self.parts.bucket;
        if (bucket.len == 0) {
            return null;
        }
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const listing = self.list(scratch.allocator(), bucket, "", "", 1000) catch return null;
        if (listing.next != null) {
            return null;
        }
        return @intCast(listing.entries.len);
    }

    pub fn rowKey(_: *Db, arena: std.mem.Allocator, _: db.Table) db.Error!db.RowKey {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        try out.append(arena, KEY);
        return .{ .columns = out.items };
    }

    pub fn alterContext(_: *Db, _: std.mem.Allocator, _: db.Table, _: []const db.Column) db.Error!db.AlterContext {
        return .{};
    }

    pub fn settings(self: *Db, arena: std.mem.Allocator) db.Error![]db.Setting {
        var out: std.ArrayListUnmanaged(db.Setting) = .empty;
        try out.append(arena, .{ .label = "endpoint", .value = try std.fmt.allocPrint(arena, "{s}:{d}", .{ self.parts.endpoint, self.parts.port }) });
        try out.append(arena, .{ .label = "region", .value = self.parts.region });
        try out.append(arena, .{ .label = "addressing", .value = if (self.parts.path_style) "path" else "virtual host" });
        try out.append(arena, .{ .label = "encrypted", .value = if (self.parts.tls) "yes, TLS" else "no" });
        try out.append(arena, .{ .label = "credentials", .value = self.parts.source });
        if (!self.parts.anonymous()) {
            try out.append(arena, .{ .label = "access key", .value = try masked(arena, self.parts.key) });
        }
        if (self.parts.bucket.len != 0) {
            try out.append(arena, .{ .label = "bucket", .value = self.parts.bucket });
        }
        try out.append(arena, .{ .label = "requests made", .value = try std.fmt.allocPrint(arena, "{d}", .{self.requests}) });
        return out.items;
    }

    /// One command per line, as in the other console drivers.
    pub fn split(_: *Db, arena: std.mem.Allocator, sql: []const u8) db.Error![]db.Statement {
        var out: std.ArrayListUnmanaged(db.Statement) = .empty;
        var lines = std.mem.splitScalar(u8, sql, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len != 0 and !std.mem.startsWith(u8, line, "--") and !std.mem.startsWith(u8, line, "#")) {
                try out.append(arena, .{ .sql = line });
            }
        }
        return out.items;
    }

    pub fn ddl(_: *Db) db.Ddl {
        return .{ .s3 = .{} };
    }

    // -------------------------------------------------------------- console

    fn console(self: *Db, text: []const u8) db.Error!Rows {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const args = try typed.split(arena, text);
        if (args.len == 0) {
            return self.oneText("s3", "");
        }
        const command = args[0];
        const bucket = self.parts.bucket;

        if (eql(command, "HELP") or eql(command, "?")) {
            return self.help();
        }
        if (eql(command, "BUCKETS")) {
            var rows = self.newNamed(&.{"bucket"}, &.{false});
            for (try self.buckets(self.replies.allocator())) |object| {
                try rows.add(&.{.{ .text = object.name }});
            }
            return rows;
        }
        if (eql(command, "LS") or eql(command, "LIST")) {
            const which = if (args.len > 1 and looksLikeBucket(args[1])) args[1] else bucket;
            const prefix = if (args.len > 1 and !looksLikeBucket(args[1])) args[1] else if (args.len > 2) args[2] else "";
            if (which.len == 0) {
                self.remember("which bucket? try BUCKETS, or name one: LS photos");
                return error.Driver;
            }
            const listing = try self.list(self.replies.allocator(), which, prefix, "", PAGE);
            var rows = self.newRows(which);
            for (listing.entries) |entry| {
                try rows.add(&.{
                    .{ .text = entry.key },
                    .{ .number = entry.size },
                    .{ .text = entry.modified },
                    .{ .text = entry.etag },
                    .{ .text = entry.storage },
                });
            }
            return rows;
        }
        if (args.len < 2) {
            self.complain("{s} needs a key - try HELP", .{command});
            return error.Driver;
        }
        const key = args[1];
        if (bucket.len == 0) {
            self.remember("no bucket in this connection: name one in the target to use the console");
            return error.Driver;
        }

        if (eql(command, "GET") or eql(command, "CAT")) {
            // Into the arena the rows live in: the body is the value shown.
            const response = try self.call(self.replies.allocator(), .{
                .bucket = bucket,
                .key = key,
                .limit = GET_LIMIT,
            });
            if (!response.ok()) {
                return self.fail(response);
            }
            var rows = self.newNamed(&.{ KEY, SIZE, "type", "value" }, &.{ false, true, false, false });
            try rows.add(&.{
                .{ .text = key },
                .{ .number = @intCast(response.body.len) },
                .{ .text = response.get("content-type") orelse "" },
                if (typed.readable(response.body)) .{ .text = response.body } else .{ .blob = response.body },
            });
            return rows;
        }
        if (eql(command, "HEAD") or eql(command, "STAT")) {
            const response = try self.call(arena, .{ .method = "HEAD", .bucket = bucket, .key = key });
            if (!response.ok()) {
                return self.fail(response);
            }
            var rows = self.newNamed(&.{ "header", "value" }, &.{ false, false });
            const replies = self.replies.allocator();
            for (response.headers) |header| {
                try rows.add(&.{
                    .{ .text = try replies.dupe(u8, header.name) },
                    .{ .text = try replies.dupe(u8, header.value) },
                });
            }
            return rows;
        }
        if (eql(command, "PUT")) {
            const body = if (args.len > 2) args[2] else "";
            const response = try self.call(arena, .{
                .method = "PUT",
                .bucket = bucket,
                .key = key,
                .body = body,
            });
            if (!response.ok()) {
                return self.fail(response);
            }
            self.pages.forget();
            return self.oneText("put", key);
        }
        if (eql(command, "DEL") or eql(command, "RM") or eql(command, "DELETE")) {
            const response = try self.call(arena, .{ .method = "DELETE", .bucket = bucket, .key = key });
            if (!response.ok()) {
                return self.fail(response);
            }
            self.pages.forget();
            return self.oneText("deleted", key);
        }
        if (eql(command, "URL") or eql(command, "LINK") or eql(command, "SIGN")) {
            return self.link(arena, bucket, key, if (args.len > 2)
                std.fmt.parseInt(u32, args[2], 10) catch LINK_SECONDS
            else
                LINK_SECONDS);
        }
        self.complain("no such command: {s} - try HELP", .{command});
        return error.Driver;
    }

    /// A link anybody can open, for as long as it lasts.
    fn link(self: *Db, arena: std.mem.Allocator, bucket: []const u8, key: []const u8, seconds: u32) db.Error!Rows {
        if (self.parts.anonymous()) {
            self.remember("a link is signed, and there is no key to sign it with");
            return error.Driver;
        }
        const host = try self.hostFor(arena, bucket);
        const signature = sigv4.presign(arena, .{
            .key = self.parts.key,
            .secret = self.parts.secret,
            .token = self.parts.token,
        }, .{
            .method = "GET",
            .path = try self.pathFor(arena, bucket, key),
            .headers = &.{.{ .name = "host", .value = try self.hostHeader(arena, host) }},
        }, self.parts.region, "s3", sigv4.now(), seconds) catch {
            self.remember("the link could not be signed");
            return error.Driver;
        };
        const replies = self.replies.allocator();
        const url = try std.fmt.allocPrint(replies, "{s}://{s}{s}?{s}", .{
            if (self.parts.tls) "https" else "http",
            try self.hostHeader(replies, host),
            try self.pathFor(replies, bucket, key),
            signature,
        });
        var rows = self.newNamed(&.{ "url", "lasts (s)" }, &.{ false, true });
        try rows.add(&.{ .{ .text = url }, .{ .number = seconds } });
        return rows;
    }

    // ------------------------------------------------- as a place holding files

    /// The same connection seen as somewhere files can be copied to and from.
    pub fn files(self: *Db) db.store.Store {
        return .{ .s3 = .{ .owner = self } };
    }

    /// A bucket has no directories, only keys with slashes in them - so a
    /// listing that stops at each slash is what makes it look like one, and the
    /// prefixes it reports back are the folders. A path here is
    /// `/bucket/some/prefix/`, and `/` is the list of buckets.
    pub const Files = struct {
        owner: *Db,

        pub fn label(self: Files) []const u8 {
            return self.owner.parts.endpoint;
        }

        pub fn message(self: Files) []const u8 {
            return self.owner.last_error.items;
        }

        pub fn start(self: Files, arena: std.mem.Allocator) db.store.Error![]const u8 {
            if (self.owner.parts.bucket.len == 0) {
                return "/";
            }
            return std.fmt.allocPrint(arena, "/{s}", .{self.owner.parts.bucket}) catch error.OutOfMemory;
        }

        /// A path split into the bucket and the key under it.
        const Split = struct {
            bucket: []const u8 = "",
            key: []const u8 = "",
        };

        fn partsOf(path: []const u8) Split {
            const trimmed = std.mem.trimStart(u8, path, "/");
            const slash = std.mem.indexOfScalar(u8, trimmed, '/') orelse return .{ .bucket = trimmed };
            return .{ .bucket = trimmed[0..slash], .key = trimmed[slash + 1 ..] };
        }

        /// A key that names a folder ends in a slash, and the empty one does not:
        /// asking for `prefix//` finds nothing.
        fn asFolder(arena: std.mem.Allocator, key: []const u8) db.store.Error![]const u8 {
            if (key.len == 0 or std.mem.endsWith(u8, key, "/")) {
                return key;
            }
            return std.fmt.allocPrint(arena, "{s}/", .{key}) catch error.OutOfMemory;
        }

        fn blame(self: Files, response: http.Response) db.store.Error {
            _ = self.owner.fail(response) catch {};
            return error.Store;
        }

        pub fn list(self: Files, arena: std.mem.Allocator, path: []const u8) db.store.Error![]db.store.Entry {
            var out: std.ArrayListUnmanaged(db.store.Entry) = .empty;
            const where = partsOf(path);
            if (where.bucket.len == 0) {
                const found = self.owner.buckets(arena) catch return error.Store;
                for (found) |one| {
                    out.append(arena, .{ .name = one.name, .kind = .dir }) catch return error.OutOfMemory;
                }
                return out.items;
            }

            const prefix = try asFolder(arena, where.key);
            var token: []const u8 = "";
            // Every page, because a directory listing that stopped at a thousand
            // would be a listing that quietly leaves files out of a copy.
            while (true) {
                const page = self.owner.listPage(arena, where.bucket, prefix, token, 1000, true) catch return error.Store;
                for (page.folders) |one| {
                    const name = std.mem.trimEnd(u8, one[prefix.len..], "/");
                    if (name.len != 0) {
                        out.append(arena, .{ .name = name, .kind = .dir }) catch return error.OutOfMemory;
                    }
                }
                for (page.entries) |entry| {
                    const name = entry.key[@min(prefix.len, entry.key.len)..];
                    // The empty object that stands for the folder itself is the folder,
                    // not a file in it.
                    if (name.len == 0) {
                        continue;
                    }
                    out.append(arena, .{
                        .name = name,
                        .kind = .file,
                        .size = @intCast(@max(entry.size, 0)),
                        .modified = whenever(entry.modified),
                    }) catch return error.OutOfMemory;
                }
                token = page.next orelse break;
            }
            return out.items;
        }

        pub fn stat(self: Files, arena: std.mem.Allocator, path: []const u8) db.store.Error!db.store.Entry {
            const where = partsOf(path);
            if (where.bucket.len == 0 or where.key.len == 0) {
                return .{ .name = db.store.basename(path), .kind = .dir };
            }
            const response = self.owner.call(arena, .{
                .method = "HEAD",
                .bucket = where.bucket,
                .key = where.key,
            }) catch return error.Store;
            if (response.ok()) {
                return .{
                    .name = db.store.basename(path),
                    .kind = .file,
                    .size = std.fmt.parseInt(u64, response.get("content-length") orelse "0", 10) catch 0,
                };
            }
            // Not an object, so it is a folder if anything is under it. A prefix
            // with nothing under it does not exist at all, which is S3 all over.
            const prefix = try asFolder(arena, where.key);
            const page = self.owner.listPage(arena, where.bucket, prefix, "", 1, true) catch return error.Store;
            if (page.entries.len != 0 or page.folders.len != 0) {
                return .{ .name = db.store.basename(path), .kind = .dir };
            }
            self.owner.complain("{s} is not there", .{path});
            return error.Store;
        }

        pub fn openRead(self: Files, arena: std.mem.Allocator, path: []const u8) db.store.Error!Ranged {
            const where = partsOf(path);
            const what = try self.stat(arena, path);
            return .{
                .owner = self.owner,
                .bucket = self.owner.allocator.dupe(u8, where.bucket) catch return error.OutOfMemory,
                .key = self.owner.allocator.dupe(u8, where.key) catch return error.OutOfMemory,
                .size = what.size,
            };
        }

        pub fn openWrite(self: Files, _: std.mem.Allocator, path: []const u8, size: u64) db.store.Error!Upload {
            if (size > UPLOAD_LIMIT) {
                self.owner.complain(
                    "{s} is {d} MB, and an object goes up in one request here - the ceiling is {d} MB",
                    .{ path, size >> 20, UPLOAD_LIMIT >> 20 },
                );
                return error.Store;
            }
            const where = partsOf(path);
            return .{
                .owner = self.owner,
                .bucket = self.owner.allocator.dupe(u8, where.bucket) catch return error.OutOfMemory,
                .key = self.owner.allocator.dupe(u8, where.key) catch return error.OutOfMemory,
            };
        }

        /// A folder is an empty object whose name ends in a slash: the convention
        /// every S3 browser follows, because S3 itself has no such thing.
        pub fn makeDir(self: Files, arena: std.mem.Allocator, path: []const u8) db.store.Error!void {
            const where = partsOf(path);
            if (where.key.len == 0) {
                return;
            }
            const response = self.owner.call(arena, .{
                .method = "PUT",
                .bucket = where.bucket,
                .key = try asFolder(arena, where.key),
            }) catch return error.Store;
            if (!response.ok()) {
                return self.blame(response);
            }
            self.owner.pages.forget();
        }

        pub fn remove(self: Files, arena: std.mem.Allocator, path: []const u8, kind: db.store.Kind) db.store.Error!void {
            const where = partsOf(path);
            const key = if (kind == .dir) try asFolder(arena, where.key) else where.key;
            const response = self.owner.call(arena, .{
                .method = "DELETE",
                .bucket = where.bucket,
                .key = key,
            }) catch return error.Store;
            // A folder marker that was never there is not a failure: the folder
            // existed because of what was under it, and that is gone by now.
            if (!response.ok() and !(kind == .dir and response.status == 404)) {
                return self.blame(response);
            }
            self.owner.pages.forget();
        }

        /// S3 has no rename, so this is a copy and a delete - and says so if it
        /// gets halfway.
        pub fn rename(self: Files, arena: std.mem.Allocator, from: []const u8, to: []const u8) db.store.Error!void {
            const source = partsOf(from);
            const target = partsOf(to);
            const origin = std.fmt.allocPrint(arena, "/{s}/{s}", .{ source.bucket, source.key }) catch return error.OutOfMemory;
            const response = self.owner.call(arena, .{
                .method = "PUT",
                .bucket = target.bucket,
                .key = target.key,
                .headers = &.{.{ .name = "x-amz-copy-source", .value = origin }},
            }) catch return error.Store;
            if (!response.ok()) {
                return self.blame(response);
            }
            try self.remove(arena, from, .file);
        }
    };

    /// An object read in pieces. S3 will not stream a body out of this program's
    /// HTTP client without rewriting it, but it will answer a range - so a large
    /// object arrives a slice at a time and never sits in memory whole.
    pub const Ranged = struct {
        owner: *Db,
        bucket: []const u8,
        key: []const u8,
        size: u64 = 0,
        at: u64 = 0,
        held: []const u8 = &.{},
        taken: usize = 0,
        scratch: ?std.heap.ArenaAllocator = null,

        pub fn read(self: *Ranged, into: []u8) db.store.Error!usize {
            if (self.taken == self.held.len) {
                if (self.at >= self.size) {
                    return 0;
                }
                try self.fetch();
            }
            const count = @min(into.len, self.held.len - self.taken);
            @memcpy(into[0..count], self.held[self.taken .. self.taken + count]);
            self.taken += count;
            return count;
        }

        fn fetch(self: *Ranged) db.store.Error!void {
            if (self.scratch) |*old| {
                old.deinit();
            }
            self.scratch = std.heap.ArenaAllocator.init(self.owner.allocator);
            const arena = self.scratch.?.allocator();

            const last = @min(self.at + RANGE, self.size) - 1;
            const range = std.fmt.allocPrint(arena, "bytes={d}-{d}", .{ self.at, last }) catch return error.OutOfMemory;
            const response = self.owner.call(arena, .{
                .bucket = self.bucket,
                .key = self.key,
                .headers = &.{.{ .name = "range", .value = range }},
                .limit = RANGE + (1 << 20),
            }) catch return error.Store;
            if (!response.ok()) {
                _ = self.owner.fail(response) catch {};
                return error.Store;
            }
            self.held = response.body;
            self.taken = 0;
            self.at += response.body.len;
            // A server that ignores the range hands back the whole object, and
            // asking again from where it left off would fetch it all over again.
            if (response.body.len == 0) {
                self.at = self.size;
            }
        }

        pub fn close(self: *Ranged) void {
            if (self.scratch) |*old| {
                old.deinit();
            }
            self.scratch = null;
            self.owner.allocator.free(self.bucket);
            self.owner.allocator.free(self.key);
        }
    };

    /// An object written in one go. What arrives is held until the end because a
    /// request has to say how long it is and be signed over what it holds.
    pub const Upload = struct {
        owner: *Db,
        bucket: []const u8,
        key: []const u8,
        held: List = .empty,

        pub fn write(self: *Upload, bytes: []const u8) db.store.Error!void {
            self.held.appendSlice(self.owner.allocator, bytes) catch return error.OutOfMemory;
            if (self.held.items.len > UPLOAD_LIMIT) {
                return error.Store;
            }
        }

        pub fn finish(self: *Upload) db.store.Error!void {
            defer self.release();
            var scratch = std.heap.ArenaAllocator.init(self.owner.allocator);
            defer scratch.deinit();
            const response = self.owner.call(scratch.allocator(), .{
                .method = "PUT",
                .bucket = self.bucket,
                .key = self.key,
                .body = self.held.items,
            }) catch return error.Store;
            if (!response.ok()) {
                _ = self.owner.fail(response) catch {};
                return error.Store;
            }
            self.owner.pages.forget();
        }

        pub fn abandon(self: *Upload) void {
            self.release();
        }

        fn release(self: *Upload) void {
            self.held.deinit(self.owner.allocator);
            self.owner.allocator.free(self.bucket);
            self.owner.allocator.free(self.key);
        }
    };

    fn help(self: *Db) db.Error!Rows {
        var rows = self.newNamed(&.{ "command", "what it does" }, &.{ false, false });
        const LINES = [_][2][]const u8{
            .{ "BUCKETS", "every bucket this key can see" },
            .{ "LS [bucket] [prefix]", "one page of keys" },
            .{ "GET key", "the object itself, shown as a value" },
            .{ "HEAD key", "what the server says about it" },
            .{ "PUT key [text]", "write an object" },
            .{ "DEL key", "remove one" },
            .{ "URL key [seconds]", "a signed link anybody can open" },
        };
        for (LINES) |line| {
            try rows.add(&.{ .{ .text = line[0] }, .{ .text = line[1] } });
        }
        return rows;
    }

    // ---------------------------------------------------------------- rows

    fn newRows(self: *Db, bucket: []const u8) Rows {
        return .{
            .owner = self,
            .names = &COLUMNS,
            .numeric = &NUMERIC,
            .table = bucket,
        };
    }

    fn newNamed(self: *Db, names: []const []const u8, numeric: []const bool) Rows {
        return .{ .owner = self, .names = names, .numeric = numeric };
    }

    /// A cursor with one column, whose name is not a literal - so it is copied
    /// into the arena the rows live in. Pointing at the caller's stack was a crash
    /// exactly one command later.
    fn oneColumn(self: *Db, name: []const u8, numeric: bool) db.Error!Rows {
        const arena = self.replies.allocator();
        return .{
            .owner = self,
            .names = try arena.dupe([]const u8, &.{try arena.dupe(u8, name)}),
            .numeric = try arena.dupe(bool, &.{numeric}),
        };
    }

    fn oneText(self: *Db, name: []const u8, text: []const u8) db.Error!Rows {
        var rows = try self.oneColumn(name, false);
        try rows.add(&.{.{ .text = try self.replies.allocator().dupe(u8, text) }});
        return rows;
    }

    fn oneNumber(self: *Db, name: []const u8, number: i64) db.Error!Rows {
        var rows = try self.oneColumn(name, true);
        try rows.add(&.{.{ .number = number }});
        return rows;
    }

    fn oneNil(self: *Db, name: []const u8) db.Error!Rows {
        var rows = try self.oneColumn(name, true);
        try rows.add(&.{.{ .nil = {} }});
        return rows;
    }
};

/// The tokens that start each page of one listing. S3 pages forwards only, so
/// these are what makes going back to page two free.
const Pages = struct {
    arena: std.heap.ArenaAllocator,
    bucket: []const u8 = "",
    prefix: []const u8 = "",
    size: usize = 0,
    tokens: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Whether the listing was walked to its end, so a page beyond it is known to
    /// be empty without asking.
    ended: bool = false,

    fn matches(self: *Pages, bucket: []const u8, prefix: []const u8, size: usize) bool {
        return self.size == size and
            std.mem.eql(u8, self.bucket, bucket) and
            std.mem.eql(u8, self.prefix, prefix);
    }

    fn restart(self: *Pages, bucket: []const u8, prefix: []const u8, size: usize) !void {
        _ = self.arena.reset(.retain_capacity);
        const kept = self.arena.allocator();
        self.tokens = .empty;
        self.bucket = try kept.dupe(u8, bucket);
        self.prefix = try kept.dupe(u8, prefix);
        self.size = size;
        self.ended = false;
        // Page one starts at no token at all.
        try self.tokens.append(kept, "");
    }

    /// Something was written: what was paged through is no longer what is there.
    fn forget(self: *Pages) void {
        self.size = 0;
        self.ended = false;
    }
};

// ------------------------------------------------------------------ replies

/// One `ListObjectsV2` reply. Separate from the connection so it can be tested
/// against what S3 actually sends, which is how the encoding of a key with a
/// space in it stopped being a guess.
pub fn parseListing(arena: std.mem.Allocator, body: []const u8) !Db.Listing {
    var entries: std.ArrayListUnmanaged(Db.Entry) = .empty;
    var folders: std.ArrayListUnmanaged([]const u8) = .empty;
    var next: ?[]const u8 = null;
    var truncated = false;

    var reader = xml.Reader{ .text = body };
    var current: []const u8 = "";
    var inside = false;
    var folding = false;
    var entry = Db.Entry{};
    while (reader.next()) |event| {
        switch (event) {
            .open => |name| {
                current = name;
                if (std.mem.eql(u8, name, "Contents")) {
                    entry = .{};
                    inside = true;
                } else if (std.mem.eql(u8, name, "CommonPrefixes")) {
                    folding = true;
                }
            },
            .close => |name| {
                if (std.mem.eql(u8, name, "Contents")) {
                    try entries.append(arena, entry);
                    inside = false;
                } else if (std.mem.eql(u8, name, "CommonPrefixes")) {
                    folding = false;
                }
                current = "";
            },
            .text => |text| {
                if (folding) {
                    if (std.mem.eql(u8, current, "Prefix")) {
                        try folders.append(arena, try unescapeKey(arena, text));
                    }
                } else if (inside) {
                    if (std.mem.eql(u8, current, "Key")) {
                        entry.key = try unescapeKey(arena, text);
                    } else if (std.mem.eql(u8, current, "Size")) {
                        entry.size = std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t\r\n"), 10) catch 0;
                    } else if (std.mem.eql(u8, current, "LastModified")) {
                        entry.modified = try xml.unescape(arena, text);
                    } else if (std.mem.eql(u8, current, "ETag")) {
                        entry.etag = trimQuotes(try xml.unescape(arena, text));
                    } else if (std.mem.eql(u8, current, "StorageClass")) {
                        entry.storage = try xml.unescape(arena, text);
                    }
                } else if (std.mem.eql(u8, current, "NextContinuationToken")) {
                    next = try xml.unescape(arena, text);
                } else if (std.mem.eql(u8, current, "IsTruncated")) {
                    truncated = std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n"), "true");
                }
            },
        }
    }
    return .{
        .entries = entries.items,
        .folders = folders.items,
        // A token without a truncated listing is not a next page: it is the last
        // answer repeating itself, and following it would loop forever.
        .next = if (truncated) next else null,
    };
}

/// A time as S3 writes one - `2015-08-30T12:36:00.000Z` - in seconds. Zero for
/// anything that does not look like one, because a listing with an odd date in
/// it is still a listing and refusing to show it would help nobody.
fn whenever(text: []const u8) i64 {
    if (text.len < 19 or text[4] != '-' or text[10] != 'T') {
        return 0;
    }
    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return 0;
    const month = std.fmt.parseInt(i64, text[5..7], 10) catch return 0;
    const day = std.fmt.parseInt(i64, text[8..10], 10) catch return 0;
    const hour = std.fmt.parseInt(i64, text[11..13], 10) catch return 0;
    const minute = std.fmt.parseInt(i64, text[14..16], 10) catch return 0;
    const second = std.fmt.parseInt(i64, text[17..19], 10) catch return 0;
    return days(year, month, day) * 86400 + hour * 3600 + minute * 60 + second;
}

/// Days from 1970 to that date. The civil calendar arithmetic that every C
/// library hides inside timegm, which is not portable enough to call.
fn days(year: i64, month: i64, day: i64) i64 {
    const shifted = year - @intFromBool(month <= 2);
    const era = @divFloor(shifted, 400);
    const of_era = shifted - era * 400;
    const of_year = @divTrunc(153 * (month + (if (month > 2) @as(i64, -3) else 9)) + 2, 5) + day - 1;
    const day_of_era = of_era * 365 + @divTrunc(of_era, 4) - @divTrunc(of_era, 100) + of_year;
    return era * 146097 + day_of_era - 719468;
}

/// A key as `encoding-type=url` sends it. That encoding is the one a form uses,
/// so a space arrives as `+` and a real plus as `%2B` - a key called `a+b` came
/// back as `a b` until this told the two apart.
fn unescapeKey(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const entities = try xml.unescape(arena, text);
    if (std.mem.indexOfAny(u8, entities, "%+") == null) {
        return entities;
    }
    var out: List = .empty;
    var at: usize = 0;
    while (at < entities.len) {
        if (entities[at] == '+') {
            try out.append(arena, ' ');
            at += 1;
            continue;
        }
        if (entities[at] == '%' and at + 2 < entities.len) {
            const high = std.fmt.charToDigit(entities[at + 1], 16) catch {
                try out.append(arena, entities[at]);
                at += 1;
                continue;
            };
            const low = std.fmt.charToDigit(entities[at + 2], 16) catch {
                try out.append(arena, entities[at]);
                at += 1;
                continue;
            };
            try out.append(arena, high * 16 + low);
            at += 3;
            continue;
        }
        try out.append(arena, entities[at]);
        at += 1;
    }
    return out.items;
}

/// An ETag arrives in quotes, which are not part of it.
fn trimQuotes(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, "\"");
}

/// Who answered, for the header. Everything that speaks S3 says so here, and
/// knowing whether it is Amazon or MinIO explains half the surprises.
fn serverName(header: ?[]const u8) []const u8 {
    const text = header orelse return "S3";
    if (std.ascii.indexOfIgnoreCase(text, "minio") != null) {
        return "MinIO";
    }
    if (std.ascii.indexOfIgnoreCase(text, "amazons3") != null) {
        return "Amazon S3";
    }
    return "S3";
}

/// All but the last four characters of a key id: enough to tell two keys apart,
/// not enough to be worth reading over a shoulder.
fn masked(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    if (key.len <= 4) {
        return "****";
    }
    return std.fmt.allocPrint(arena, "****{s}", .{key[key.len - 4 ..]});
}

fn eql(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

/// A bucket name has no slash in it; a prefix nearly always does. Which is how
/// `LS photos` and `LS 2015/august` tell themselves apart.
fn looksLikeBucket(word: []const u8) bool {
    return std.mem.indexOfScalar(u8, word, '/') == null and !std.mem.endsWith(u8, word, "%");
}

/// A cell of a change that was actually given a value.
fn flat(value: ??[]const u8) ?[]const u8 {
    const inner = value orelse return null;
    return inner orelse null;
}

// ------------------------------------------------------------------- cursor

pub const Value = union(enum) {
    nil: void,
    text: []const u8,
    blob: []const u8,
    number: i64,

    /// What this means to the grid. The one thing a driver's own value type
    /// has to say for itself; the walking and holding is db.Built's.
    pub fn asValue(self: @This()) db.Value {
        return switch (self) {
            .nil => .{ .null = {} },
            .number => |number| .{ .int = number },
            .text => |text| .{ .text = text },
            .blob => |bytes| .{ .blob = bytes },
        };
    }
};

/// Every reply is small enough to hold, so the cursor is a list of rows rather
/// than something that streams.
pub const Rows = db.Built(Db, Value);

// ---------------------------------------------------------------------- DDL

/// S3 has no schema to define. A bucket can be made and unmade, and everything
/// else says so rather than writing something that could not work.
pub const Ddl = struct {
    pub fn types(_: Ddl) []const []const u8 {
        return &[_][]const u8{ "string", "integer", "timestamp" };
    }

    fn refuse(out: *List, a: std.mem.Allocator, what: []const u8) !void {
        try out.appendSlice(a, "-- S3 has no ");
        try out.appendSlice(a, what);
        try out.appendSlice(a, ", so nothing was done\n");
    }

    pub fn createTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const db.Column, _: []const db.ForeignKey) !void {
        try refuse(out, a, "tables to create - a bucket is made where it is billed");
    }

    pub fn alterTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: []const db.Column, _: db.AlterContext) !void {
        try refuse(out, a, "columns to alter: an object is a key and its bytes");
    }

    pub fn addForeignKey(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: db.ForeignKey, _: db.AlterContext) !void {
        try refuse(out, a, "foreign keys");
    }

    pub fn createIndex(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: []const []const u8, _: bool, _: []const u8) !void {
        try refuse(out, a, "indexes: the key is the index");
    }

    pub fn createView(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8) !void {
        try refuse(out, a, "views");
    }

    pub fn createTrigger(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: []const u8, _: []const u8, _: []const u8, _: []const u8) !void {
        try refuse(out, a, "triggers");
    }

    pub fn renameTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8) !void {
        try refuse(out, a, "buckets to rename");
    }

    pub fn copyTable(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table, _: []const u8, _: bool) !void {
        try refuse(out, a, "buckets to copy in one go");
    }

    pub fn dropObject(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Kind, _: db.Table) !void {
        try refuse(out, a, "a drop that would not delete somebody's data by accident");
    }

    pub fn truncate(_: Ddl, out: *List, a: std.mem.Allocator, _: db.Table) !void {
        try refuse(out, a, "a way to empty a bucket in one request");
    }
};

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "a listing is read the way S3 sends one" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const listing = try parseListing(arena,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        \\  <Name>photos</Name>
        \\  <Prefix>2015%2F</Prefix>
        \\  <KeyCount>2</KeyCount>
        \\  <MaxKeys>2</MaxKeys>
        \\  <IsTruncated>true</IsTruncated>
        \\  <NextContinuationToken>1ueGcxLPRx1Tr</NextContinuationToken>
        \\  <Contents>
        \\    <Key>2015%2Faugust+trip.jpg</Key>
        \\    <LastModified>2015-08-30T12:36:00.000Z</LastModified>
        \\    <ETag>&quot;fba9dede5f27731c9771645a39863328&quot;</ETag>
        \\    <Size>434234</Size>
        \\    <StorageClass>STANDARD</StorageClass>
        \\    <Owner><ID>abcd</ID><DisplayName>somebody</DisplayName></Owner>
        \\  </Contents>
        \\  <Contents>
        \\    <Key>2015%2Fc%2B%2B%20notes.txt</Key>
        \\    <LastModified>2015-09-01T09:00:00.000Z</LastModified>
        \\    <ETag>&quot;d41d8cd98f00b204e9800998ecf8427e&quot;</ETag>
        \\    <Size>0</Size>
        \\    <StorageClass>GLACIER</StorageClass>
        \\  </Contents>
        \\</ListBucketResult>
    );
    try testing.expectEqual(@as(usize, 2), listing.entries.len);
    // The key comes back as it is, not as it was escaped to travel - and a space
    // travels as a `+`, which is the encoding S3 asks to be understood by.
    try testing.expectEqualStrings("2015/august trip.jpg", listing.entries[0].key);
    try testing.expectEqual(@as(i64, 434234), listing.entries[0].size);
    try testing.expectEqualStrings("2015-08-30T12:36:00.000Z", listing.entries[0].modified);
    // An ETag arrives in quotes, which are not part of it.
    try testing.expectEqualStrings("fba9dede5f27731c9771645a39863328", listing.entries[0].etag);
    try testing.expectEqualStrings("STANDARD", listing.entries[0].storage);
    // The owner is inside Contents and is not one of the columns; it must not be
    // mistaken for the key of the next object. And a plus that is a plus arrives
    // escaped, which is how it is told from a space.
    try testing.expectEqualStrings("2015/c++ notes.txt", listing.entries[1].key);
    try testing.expectEqual(@as(i64, 0), listing.entries[1].size);
    try testing.expectEqualStrings("GLACIER", listing.entries[1].storage);
    try testing.expectEqualStrings("1ueGcxLPRx1Tr", listing.next.?);
}

test "a folded listing has the folders as well as the keys" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    // What `delimiter=/` gets back: what is in this directory, and what is below
    // it as prefixes. Without the second there are no folders in a bucket at all.
    const listing = try parseListing(arena,
        \\<ListBucketResult>
        \\  <Name>photos</Name>
        \\  <Prefix>2015%2F</Prefix>
        \\  <Delimiter>%2F</Delimiter>
        \\  <IsTruncated>false</IsTruncated>
        \\  <Contents>
        \\    <Key>2015%2Fnote.txt</Key>
        \\    <LastModified>2015-08-30T12:36:00.000Z</LastModified>
        \\    <Size>12</Size>
        \\  </Contents>
        \\  <CommonPrefixes><Prefix>2015%2Faugust%2F</Prefix></CommonPrefixes>
        \\  <CommonPrefixes><Prefix>2015%2Fseptember%2F</Prefix></CommonPrefixes>
        \\</ListBucketResult>
    );
    try testing.expectEqual(@as(usize, 1), listing.entries.len);
    try testing.expectEqualStrings("2015/note.txt", listing.entries[0].key);
    try testing.expectEqual(@as(usize, 2), listing.folders.len);
    try testing.expectEqualStrings("2015/august/", listing.folders[0]);
    try testing.expectEqualStrings("2015/september/", listing.folders[1]);
    // The Prefix of the listing itself is not one of the folders: it is where the
    // listing was taken from, and counting it would put a directory inside itself.
    for (listing.folders) |one| {
        try testing.expect(!std.mem.eql(u8, one, "2015/"));
    }
}

test "the time on an object becomes a number" {
    // The moment AWS uses in its own worked examples.
    try testing.expectEqual(@as(i64, 1440938160), whenever("2015-08-30T12:36:00.000Z"));
    try testing.expectEqual(@as(i64, 0), whenever("1970-01-01T00:00:00.000Z"));
    // A leap day, because the arithmetic is where this would go wrong.
    try testing.expectEqual(@as(i64, 1709208000), whenever("2024-02-29T12:00:00.000Z"));
    // And anything that is not a time at all is nothing rather than a wrong date.
    try testing.expectEqual(@as(i64, 0), whenever(""));
    try testing.expectEqual(@as(i64, 0), whenever("yesterday"));
}

test "the last page has no next, whatever token it carries" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const listing = try parseListing(arena,
        \\<ListBucketResult>
        \\  <IsTruncated>false</IsTruncated>
        \\  <NextContinuationToken>stale</NextContinuationToken>
        \\  <Contents><Key>only.txt</Key><Size>3</Size></Contents>
        \\</ListBucketResult>
    );
    try testing.expectEqual(@as(usize, 1), listing.entries.len);
    try testing.expect(listing.next == null);

    // An empty bucket is an empty listing and not an error.
    const empty = try parseListing(arena, "<ListBucketResult><KeyCount>0</KeyCount><IsTruncated>false</IsTruncated></ListBucketResult>");
    try testing.expectEqual(@as(usize, 0), empty.entries.len);
    try testing.expect(empty.next == null);
}

test "a command line comes apart the way a shell would do it" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const args = try typed.split(arena, "PUT \"august trip.txt\" 'hello there'");
    try testing.expectEqual(@as(usize, 3), args.len);
    try testing.expectEqualStrings("PUT", args[0]);
    try testing.expectEqualStrings("august trip.txt", args[1]);
    try testing.expectEqualStrings("hello there", args[2]);

    try testing.expectEqual(@as(usize, 0), (try typed.split(arena, "   ")).len);
}

test "a bucket and a prefix tell themselves apart" {
    try testing.expect(looksLikeBucket("photos"));
    try testing.expect(!looksLikeBucket("2015/august"));
    try testing.expect(!looksLikeBucket("2015%"));
}

test "text is shown as text and everything else as bytes" {
    try testing.expect(typed.readable("ahoj, světe\n"));
    try testing.expect(typed.readable(""));
    try testing.expect(typed.readable("{\"a\":1}\r\n\t"));
    // A PNG's own first bytes, which are exactly what the image viewer wants.
    try testing.expect(!typed.readable(&.{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a }));
    try testing.expect(!typed.readable(&.{ 'a', 0x00, 'b' }));
    // Valid UTF-8 is not enough on its own: a control byte is not text.
    try testing.expect(!typed.readable(&.{ 'a', 0x07 }));
    try testing.expect(!typed.readable(&.{ 0xff, 0xfe }));
}

test "an access key is not shown in full" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    try testing.expectEqualStrings("****MPLE", try masked(scratch.allocator(), "AKIAIOSFODNN7EXAMPLE"));
    try testing.expectEqualStrings("****", try masked(scratch.allocator(), "AKI"));
}
