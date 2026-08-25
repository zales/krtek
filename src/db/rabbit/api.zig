//! What the management API answers, and what this driver makes a table of.
//!
//! Every list endpoint gives back the same shape - an array of objects, or, when
//! asked for a page, `{items: [...], item_count: n}` - so a table here is a path
//! and a list of columns saying where in each object its value is. Adding
//! `shovels` or `policies` later is a few lines in `TABLES` and nothing else.
//!
//! JSON in, rows out, and no connection anywhere near it: the tests below run
//! against replies recorded from a real broker.

const std = @import("std");
const db = @import("../db.zig");

const List = db.List;
const Value = std.json.Value;

pub const Column = struct {
    name: []const u8,
    /// Where the value is in the object, dotted for a nested one:
    /// `channel_details.name`.
    from: []const u8,
    numeric: bool = false,
};

pub const Table = struct {
    name: []const u8,
    /// Under `/api`, with `{vhost}` where the vhost goes.
    path: []const u8,
    /// Whether the endpoint takes `page` and `page_size`, which is also what
    /// makes an exact row count one request rather than all of them.
    paged: bool = true,
    /// The broker's own running state rather than anything declared: shown, but
    /// left out of a dump.
    internal: bool = false,
    columns: []const Column,
    /// What addresses one row.
    key: []const []const u8 = &.{"name"},
    /// Whether a row can be added or removed, and what to call one.
    insert: bool = false,
    remove: bool = false,
    singular: []const u8 = "row",
};

pub const TABLES = [_]Table{
    .{
        .name = "queues",
        .path = "/api/queues/{vhost}",
        .singular = "queue",
        .insert = true,
        .remove = true,
        .columns = &.{
            .{ .name = "name", .from = "name" },
            .{ .name = "type", .from = "type" },
            .{ .name = "state", .from = "state" },
            .{ .name = "messages", .from = "messages", .numeric = true },
            .{ .name = "ready", .from = "messages_ready", .numeric = true },
            .{ .name = "unacked", .from = "messages_unacknowledged", .numeric = true },
            .{ .name = "consumers", .from = "consumers", .numeric = true },
            .{ .name = "memory", .from = "memory", .numeric = true },
            .{ .name = "durable", .from = "durable" },
            .{ .name = "node", .from = "node" },
        },
    },
    .{
        .name = "exchanges",
        .path = "/api/exchanges/{vhost}",
        .singular = "exchange",
        .insert = true,
        .remove = true,
        .columns = &.{
            .{ .name = "name", .from = "name" },
            .{ .name = "type", .from = "type" },
            .{ .name = "durable", .from = "durable" },
            .{ .name = "auto_delete", .from = "auto_delete" },
            .{ .name = "internal", .from = "internal" },
        },
    },
    .{
        .name = "bindings",
        .path = "/api/bindings/{vhost}",
        .singular = "binding",
        .remove = true,
        // A binding has no name: what addresses one is where it comes from, where
        // it goes, and the key that got it there.
        .key = &.{ "source", "destination", "destination_type", "properties" },
        .columns = &.{
            .{ .name = "source", .from = "source" },
            .{ .name = "destination", .from = "destination" },
            .{ .name = "destination_type", .from = "destination_type" },
            .{ .name = "routing_key", .from = "routing_key" },
            .{ .name = "arguments", .from = "arguments" },
            // The API's own name for a binding, which is what a delete needs.
            .{ .name = "properties", .from = "properties_key" },
        },
    },
    .{
        .name = "consumers",
        .path = "/api/consumers/{vhost}",
        .singular = "consumer",
        .internal = true,
        .key = &.{"consumer_tag"},
        .columns = &.{
            .{ .name = "queue", .from = "queue.name" },
            .{ .name = "consumer_tag", .from = "consumer_tag" },
            .{ .name = "channel", .from = "channel_details.name" },
            .{ .name = "ack_required", .from = "ack_required" },
            .{ .name = "prefetch", .from = "prefetch_count", .numeric = true },
        },
    },
    .{
        .name = "connections",
        .path = "/api/vhosts/{vhost}/connections",
        .singular = "connection",
        .internal = true,
        // Closing one is the point of having them here at all.
        .remove = true,
        .columns = &.{
            .{ .name = "name", .from = "name" },
            .{ .name = "user", .from = "user" },
            .{ .name = "state", .from = "state" },
            .{ .name = "protocol", .from = "protocol" },
            .{ .name = "channels", .from = "channels", .numeric = true },
            .{ .name = "peer_host", .from = "peer_host" },
            .{ .name = "client", .from = "client_properties.product" },
        },
    },
    .{
        .name = "channels",
        .path = "/api/channels",
        .singular = "channel",
        .internal = true,
        .columns = &.{
            .{ .name = "name", .from = "name" },
            .{ .name = "user", .from = "user" },
            .{ .name = "vhost", .from = "vhost" },
            .{ .name = "state", .from = "state" },
            .{ .name = "consumers", .from = "consumer_count", .numeric = true },
            .{ .name = "unacked", .from = "messages_unacknowledged", .numeric = true },
            .{ .name = "prefetch", .from = "prefetch_count", .numeric = true },
        },
    },
    .{
        .name = "nodes",
        .path = "/api/nodes",
        .paged = false,
        .internal = true,
        .singular = "node",
        .columns = &.{
            .{ .name = "name", .from = "name" },
            .{ .name = "type", .from = "type" },
            .{ .name = "running", .from = "running" },
            .{ .name = "mem_used", .from = "mem_used", .numeric = true },
            .{ .name = "disk_free", .from = "disk_free", .numeric = true },
            .{ .name = "uptime", .from = "uptime", .numeric = true },
        },
    },
};

pub fn find(name: []const u8) ?Table {
    for (TABLES) |table| {
        if (std.mem.eql(u8, table.name, name)) {
            return table;
        }
    }
    return null;
}

/// One page of a listing. `total` is only there when the endpoint counted for
/// us, which is what makes `1-50 of 812` exact and free.
pub const Page = struct {
    items: []const Value = &.{},
    total: ?i64 = null,
};

/// The body of a list endpoint, whichever of its two shapes it came in.
pub fn page(arena: std.mem.Allocator, body: []const u8) !Page {
    const value = std.json.parseFromSliceLeaky(Value, arena, body, .{}) catch return error.Malformed;
    switch (value) {
        .array => |items| return .{ .items = items.items, .total = @intCast(items.items.len) },
        .object => |object| {
            const items = object.get("items") orelse return error.Malformed;
            if (items != .array) {
                return error.Malformed;
            }
            // `item_count` is how many are on this page; what the interface wants is
            // how many there are - after the name filter, when there is one.
            return .{
                .items = items.array.items,
                .total = count(object, "filtered_count") orelse count(object, "total_count"),
            };
        },
        else => return error.Malformed,
    }
}

fn count(object: std.json.ObjectMap, name: []const u8) ?i64 {
    return switch (object.get(name) orelse return null) {
        .integer => |value| value,
        else => null,
    };
}

/// The value at a dotted path, or null where anything on the way is missing.
pub fn pick(value: Value, path: []const u8) ?Value {
    var at = value;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |part| {
        if (at != .object) {
            return null;
        }
        at = at.object.get(part) orelse return null;
    }
    return if (at == .null) null else at;
}

/// A JSON value as one line of a grid. A nested object or array is flattened
/// rather than shown as `[object]`: the arguments of a queue are the interesting
/// part of it, and a cell that says nothing is worse than a long one.
pub fn flatten(arena: std.mem.Allocator, value: Value) ![]const u8 {
    var out: List = .empty;
    try write(&out, arena, value);
    return out.items;
}

fn write(out: *List, arena: std.mem.Allocator, value: Value) !void {
    switch (value) {
        .null => {},
        .bool => |flag| try out.appendSlice(arena, if (flag) "true" else "false"),
        .integer => |number| try out.print(arena, "{d}", .{number}),
        .float => |number| try out.print(arena, "{d}", .{number}),
        .number_string => |text| try out.appendSlice(arena, text),
        .string => |text| try out.appendSlice(arena, text),
        .array => |items| {
            for (items.items, 0..) |item, i| {
                if (i != 0) {
                    try out.appendSlice(arena, ", ");
                }
                try write(out, arena, item);
            }
        },
        .object => |object| {
            var walk = object.iterator();
            var first = true;
            while (walk.next()) |entry| {
                if (!first) {
                    try out.appendSlice(arena, ", ");
                }
                first = false;
                try out.appendSlice(arena, entry.key_ptr.*);
                try out.append(arena, '=');
                try write(out, arena, entry.value_ptr.*);
            }
        },
    }
}

/// What a message's payload is, given how the API says it was encoded. A payload
/// that is not text comes back base64, and a queue full of protobuf should be
/// shown as bytes rather than as mangled letters.
pub fn payload(arena: std.mem.Allocator, message: Value) !struct { bytes: []const u8, binary: bool } {
    const text = switch (pick(message, "payload") orelse Value{ .null = {} }) {
        .string => |value| value,
        else => "",
    };
    const encoding = switch (pick(message, "payload_encoding") orelse Value{ .null = {} }) {
        .string => |value| value,
        else => "string",
    };
    if (!std.mem.eql(u8, encoding, "base64")) {
        return .{ .bytes = text, .binary = false };
    }
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(text) catch return .{ .bytes = text, .binary = true };
    const bytes = try arena.alloc(u8, size);
    decoder.decode(bytes, text) catch return .{ .bytes = text, .binary = true };
    return .{ .bytes = bytes, .binary = true };
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

/// A page of queues, cut down from what a broker actually answers. The counts
/// are the broker's own three: what there is, what the filter left, and how many
/// came in this page.
const QUEUES =
    \\{"filtered_count":7,"item_count":2,"page":1,"page_count":4,"page_size":2,"total_count":9,
    \\ "items":[
    \\  {"name":"orders","node":"rabbit@one","state":"running","type":"classic","durable":true,
    \\   "messages":12,"messages_ready":10,"messages_unacknowledged":2,"consumers":1,"memory":21400,
    \\   "arguments":{"x-queue-type":"classic"}},
    \\  {"name":"dead letters","node":"rabbit@one","state":"idle","type":"quorum","durable":false,
    \\   "messages":0,"messages_ready":0,"messages_unacknowledged":0,"consumers":0,"memory":9100,
    \\   "arguments":{}}
    \\ ]}
;

test "a page of queues comes apart into rows" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const answer = try page(arena, QUEUES);
    try testing.expectEqual(@as(usize, 2), answer.items.len);
    // Two came back, but there are seven to page through: `item_count` is the page
    // and would have made the last page the whole listing.
    try testing.expectEqual(@as(i64, 7), answer.total.?);

    const queues = find("queues").?;
    try testing.expectEqualStrings("queues", queues.name);
    const first = answer.items[0];
    try testing.expectEqualStrings("orders", try flatten(arena, pick(first, "name").?));
    try testing.expectEqualStrings("12", try flatten(arena, pick(first, "messages").?));
    try testing.expectEqualStrings("true", try flatten(arena, pick(first, "durable").?));
    // A nested value is reached by its path, and one that is not there is not an
    // error - the API leaves a field out rather than sending null.
    try testing.expect(pick(first, "channel_details.name") == null);
    try testing.expect(pick(first, "nothing") == null);
    // The arguments are the interesting part of a queue, so they are shown.
    try testing.expectEqualStrings("x-queue-type=classic", try flatten(arena, pick(first, "arguments").?));
    try testing.expectEqualStrings("", try flatten(arena, pick(answer.items[1], "arguments").?));
    try testing.expectEqualStrings("dead letters", try flatten(arena, pick(answer.items[1], "name").?));
}

test "an endpoint that does not page answers with a bare array" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const answer = try page(arena,
        \\[{"name":"rabbit@one","type":"disc","running":true,"mem_used":123456,"disk_free":99}]
    );
    try testing.expectEqual(@as(usize, 1), answer.items.len);
    // Everything there is, so the count is exact for a different reason.
    try testing.expectEqual(@as(i64, 1), answer.total.?);
    try testing.expectEqualStrings("rabbit@one", try flatten(arena, pick(answer.items[0], "name").?));
    try testing.expectEqualStrings("true", try flatten(arena, pick(answer.items[0], "running").?));

    try testing.expectError(error.Malformed, page(arena, "not json"));
    try testing.expectError(error.Malformed, page(arena, "\"a string\""));
    try testing.expectError(error.Malformed, page(arena, "{\"no\":\"items\"}"));
}

test "a nested field is reached through the objects above it" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const answer = try page(arena,
        \\[{"consumer_tag":"ctag1","queue":{"name":"orders","vhost":"/"},
        \\  "channel_details":{"name":"127.0.0.1:5672 -> (1)","user":"guest"},
        \\  "ack_required":true,"prefetch_count":10}]
    );
    const one = answer.items[0];
    try testing.expectEqualStrings("orders", pick(one, "queue.name").?.string);
    try testing.expectEqualStrings("127.0.0.1:5672 -> (1)", pick(one, "channel_details.name").?.string);
    // A path that runs into something that is not an object stops there.
    try testing.expect(pick(one, "consumer_tag.name") == null);
    try testing.expect(pick(one, "queue.name.deeper") == null);
}

test "a payload that is not text comes back as bytes" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const answer = try page(arena,
        \\[{"payload":"ahoj","payload_encoding":"string","routing_key":"a"},
        \\ {"payload":"AAECAw==","payload_encoding":"base64","routing_key":"b"}]
    );
    const text = try payload(arena, answer.items[0]);
    try testing.expectEqualStrings("ahoj", text.bytes);
    try testing.expect(!text.binary);

    const bytes = try payload(arena, answer.items[1]);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3 }, bytes.bytes);
    try testing.expect(bytes.binary);
}

test "every table names columns that address a row" {
    // A key column that is not among the columns would make every row unaddressable
    // and the mistake would only show when somebody tried to delete one.
    for (TABLES) |table| {
        for (table.key) |key| {
            var found = false;
            for (table.columns) |column| {
                found = found or std.mem.eql(u8, column.name, key);
            }
            testing.expect(found) catch |err| {
                std.debug.print("{s} has no column called {s}\n", .{ table.name, key });
                return err;
            };
        }
    }
    try testing.expect(find("queues") != null);
    try testing.expect(find("nothing") == null);
}
