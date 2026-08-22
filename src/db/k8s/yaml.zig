//! Just enough YAML to read a kubeconfig.
//!
//! YAML is a large language and almost none of it is in a kubeconfig. What is
//! there is block mappings, block sequences, plain scalars and the occasional
//! `{}` - checked against a real one before this was written: no anchors, no
//! aliases, no flow collections with anything in them, no tabs, two-space indent
//! throughout. So this is a line-based reader for that shape, and about a
//! fortieth of a general parser.
//!
//! **What it does not understand, it refuses by name.** That is the whole
//! difference between this and a parser that is merely small: an anchor read as a
//! plain scalar would put `&ca` where a certificate belongs and the failure would
//! surface as a TLS error three layers away. A file this program cannot read is a
//! sentence saying which line it gave up on, and the user still has kubectl.
//!
//! Block scalars are the one thing here that a kubeconfig does not need and gets
//! anyway: `token: |` is what a few tools write, and folding it in is fifteen
//! lines against a refusal somebody would have to work around by hand.

const std = @import("std");
const db = @import("../db.zig");

const List = db.List;

pub const Error = error{ Yaml, OutOfMemory };

pub const Pair = struct {
	key: []const u8,
	value: Value,
};

pub const Value = union(enum) {
	scalar: []const u8,
	map: []const Pair,
	list: []const Value,

	/// The value under `key`, or null where this is not a map or has no such key.
	pub fn get(self: Value, key: []const u8) ?Value {
		switch (self) {
			.map => |pairs| for (pairs) |pair| {
				if (std.mem.eql(u8, pair.key, key)) {
					return pair.value;
				}
			},
			else => {},
		}
		return null;
	}

	/// The text of a scalar, or "" for anything else - which is what a caller
	/// wants everywhere here: a missing key and an empty one mean the same thing
	/// to a kubeconfig.
	pub fn text(self: Value) []const u8 {
		return switch (self) {
			.scalar => |value| value,
			else => "",
		};
	}

	/// `a.b.c`, so a caller can say where a value lives in one string.
	pub fn at(self: Value, path: []const u8) ?Value {
		var here = self;
		var parts = std.mem.splitScalar(u8, path, '.');
		while (parts.next()) |part| {
			here = here.get(part) orelse return null;
		}
		return here;
	}

	/// The members of a list, or nothing at all for anything else.
	pub fn items(self: Value) []const Value {
		return switch (self) {
			.list => |values| values,
			else => &.{},
		};
	}
};

const Line = struct {
	indent: usize,
	text: []const u8,
	/// Which line of the file this was, so a refusal can say where.
	number: usize,
};

/// Read `text` as the one document a kubeconfig is. On failure `why` says what
/// was not understood and on which line; both it and the result are in `arena`.
pub fn parse(arena: std.mem.Allocator, text: []const u8, why: *List) Error!Value {
	var lines: std.ArrayListUnmanaged(Line) = .empty;
	var walk = std.mem.splitScalar(u8, text, '\n');
	var number: usize = 0;
	var started = false;
	while (walk.next()) |raw| {
		number += 1;
		const line = std.mem.trimEnd(u8, raw, "\r");
		// Both, to find where the text starts - and then a tab anywhere in front of
		// it is refused, because YAML counts indentation in spaces and a file that
		// uses tabs would be read at the wrong depth rather than not at all.
		const body = std.mem.trimStart(u8, line, " \t");
		if (body.len == 0 or body[0] == '#') {
			continue;
		}
		// One document. A kubeconfig is never more than that, and taking the
		// first half of two would be worse than saying so.
		if (std.mem.eql(u8, body, "---")) {
			if (started) {
				break;
			}
			continue;
		}
		if (std.mem.eql(u8, body, "...")) {
			break;
		}
		const indent = line.len - body.len;
		if (std.mem.indexOfScalar(u8, line[0..indent], '\t') != null) {
			try complain(arena, why, number, "indented with a tab, which YAML does not allow");
			return error.Yaml;
		}
		started = true;
		try lines.append(arena, .{ .indent = indent, .text = body, .number = number });
	}
	if (lines.items.len == 0) {
		return .{ .map = &.{} };
	}

	var reader = Reader{ .arena = arena, .lines = lines.items, .why = why };
	const value = try reader.node(lines.items[0].indent);
	if (reader.at < reader.lines.len) {
		try complain(arena, why, reader.lines[reader.at].number, "does not line up with anything above it");
		return error.Yaml;
	}
	return value;
}

fn complain(arena: std.mem.Allocator, why: *List, number: usize, what: []const u8) Error!void {
	why.clearRetainingCapacity();
	try why.print(arena, "line {d}: {s}", .{ number, what });
}

const Reader = struct {
	arena: std.mem.Allocator,
	lines: []Line,
	why: *List,
	at: usize = 0,

	fn peek(self: *Reader) ?Line {
		return if (self.at < self.lines.len) self.lines[self.at] else null;
	}

	fn refuse(self: *Reader, number: usize, what: []const u8) Error {
		complain(self.arena, self.why, number, what) catch return error.OutOfMemory;
		return error.Yaml;
	}

    /// A mapping, a sequence or a scalar, whichever the line at `indent` begins.
	fn node(self: *Reader, indent: usize) Error!Value {
		const line = self.peek() orelse return .{ .scalar = "" };
		if (isItem(line.text)) {
			return self.list(indent);
		}
		if (splitKey(line.text) != null) {
			return self.map(indent);
		}
		// A lone scalar: the value of a sequence item, mostly - `- --region`.
		self.at += 1;
		return .{ .scalar = try self.scalar(line.text, line.number) };
	}

	fn map(self: *Reader, indent: usize) Error!Value {
		var pairs: std.ArrayListUnmanaged(Pair) = .empty;
		while (self.peek()) |line| {
			if (line.indent < indent) {
				break;
			}
			if (line.indent > indent) {
				return self.refuse(line.number, "is indented further than the key above it");
			}
			if (isItem(line.text)) {
				break;
			}
			const cut = splitKey(line.text) orelse
				return self.refuse(line.number, "is not `key: value` where a key was expected");
			const key = try self.scalar(std.mem.trim(u8, line.text[0..cut], " "), line.number);
			const rest = std.mem.trim(u8, line.text[cut + 1 ..], " ");
			self.at += 1;
			try pairs.append(self.arena, .{ .key = key, .value = try self.value(rest, indent, line.number) });
		}
		return .{ .map = pairs.items };
	}

	fn list(self: *Reader, indent: usize) Error!Value {
		var values: std.ArrayListUnmanaged(Value) = .empty;
		while (self.peek()) |line| {
			if (line.indent != indent or !isItem(line.text)) {
				break;
			}
			const rest = std.mem.trim(u8, line.text[1..], " ");
			if (rest.len == 0) {
				// The item is whatever is under it, indented further.
				self.at += 1;
				const next = self.peek() orelse return self.refuse(line.number, "is a list item with nothing in it");
				if (next.indent <= indent) {
					return self.refuse(line.number, "is a list item with nothing in it");
				}
				try values.append(self.arena, try self.node(next.indent));
				continue;
			}
			// What follows the dash belongs to a node of its own, starting where
			// the text starts - so `- cluster:` and the `name:` under it are two
			// keys of one map, which is how a kubeconfig writes every list it has.
			const inner = indent + (line.text.len - rest.len);
			self.lines[self.at] = .{ .indent = inner, .text = rest, .number = line.number };
			try values.append(self.arena, try self.node(inner));
		}
		return .{ .list = values.items };
	}

	/// What a key is worth: what was written after the colon, or - where nothing
	/// was - whatever is indented under it.
	fn value(self: *Reader, rest: []const u8, indent: usize, number: usize) Error!Value {
		if (rest.len != 0) {
			if (rest[0] == '|' or rest[0] == '>') {
				return .{ .scalar = try self.block(rest, indent) };
			}
			if (std.mem.eql(u8, rest, "{}")) {
				return .{ .map = &.{} };
			}
			if (std.mem.eql(u8, rest, "[]")) {
				return .{ .list = &.{} };
			}
			if (rest[0] == '{' or rest[0] == '[') {
				return self.refuse(number, "is a flow collection, which this reader does not do");
			}
			return .{ .scalar = try self.scalar(rest, number) };
		}
		const next = self.peek() orelse return .{ .scalar = "" };
		// A sequence may sit at the key's own indent, which is the one place YAML
		// lets a child not be indented at all.
		if (next.indent > indent or (next.indent == indent and isItem(next.text))) {
			return self.node(next.indent);
		}
		return .{ .scalar = "" };
	}

	/// `|`, `|-`, `>` and `>-`: the lines under it, joined with newlines or with
	/// spaces, less the indentation they share.
	fn block(self: *Reader, header: []const u8, indent: usize) Error![]const u8 {
		const folded = header[0] == '>';
		const chomp = header.len > 1 and header[1] == '-';
		var out: List = .empty;
		var first = true;
		var inner: ?usize = null;
		while (self.peek()) |line| {
			if (line.indent <= indent) {
				break;
			}
			if (inner == null) {
				inner = line.indent;
			}
			if (!first) {
				try out.append(self.arena, if (folded) ' ' else '\n');
			}
			first = false;
			try out.appendSlice(self.arena, line.text);
			self.at += 1;
		}
		if (!chomp and out.items.len != 0) {
			try out.append(self.arena, '\n');
		}
		return out.items;
	}

	/// A plain scalar as it stands, or a quoted one with its quoting undone.
	/// Anything that starts with a character YAML gives a meaning to and this
	/// reader does not is refused rather than taken literally.
	fn scalar(self: *Reader, raw: []const u8, number: usize) Error![]const u8 {
		if (raw.len == 0) {
			return "";
		}
		switch (raw[0]) {
			'&' => return self.refuse(number, "is an anchor, which this reader does not do"),
			'*' => return self.refuse(number, "is an alias, which this reader does not do"),
			'!' => return self.refuse(number, "is a tag, which this reader does not do"),
			'\'' => return unquoteSingle(self.arena, raw, self, number),
			'"' => return unquoteDouble(self.arena, raw, self, number),
			else => {},
		}
		// A trailing comment, which needs a space in front of it to be one.
		var end = raw.len;
		var i: usize = 1;
		while (i < raw.len) : (i += 1) {
			if (raw[i] == '#' and raw[i - 1] == ' ') {
				end = i - 1;
				break;
			}
		}
		return std.mem.trimEnd(u8, raw[0..end], " ");
	}
};

fn unquoteSingle(arena: std.mem.Allocator, raw: []const u8, reader: *Reader, number: usize) Error![]const u8 {
	if (raw.len < 2 or raw[raw.len - 1] != '\'') {
		return reader.refuse(number, "opens a quote it never closes");
	}
	var out: List = .empty;
	var i: usize = 1;
	while (i < raw.len - 1) : (i += 1) {
		// Inside single quotes the only escape there is doubles the quote.
		if (raw[i] == '\'' and i + 1 < raw.len - 1 and raw[i + 1] == '\'') {
			i += 1;
		}
		try out.append(arena, raw[i]);
	}
	return out.items;
}

fn unquoteDouble(arena: std.mem.Allocator, raw: []const u8, reader: *Reader, number: usize) Error![]const u8 {
	if (raw.len < 2 or raw[raw.len - 1] != '"') {
		return reader.refuse(number, "opens a quote it never closes");
	}
	var out: List = .empty;
	var i: usize = 1;
	while (i < raw.len - 1) : (i += 1) {
		if (raw[i] != '\\' or i + 1 >= raw.len - 1) {
			try out.append(arena, raw[i]);
			continue;
		}
		i += 1;
		try out.append(arena, switch (raw[i]) {
			'n' => '\n',
			't' => '\t',
			'r' => '\r',
			'0' => 0,
			else => raw[i],
		});
	}
	return out.items;
}

/// Whether a line begins a sequence item: a dash, then a space or the end of it.
fn isItem(text: []const u8) bool {
	return text.len != 0 and text[0] == '-' and
		(text.len == 1 or text[1] == ' ') and !std.mem.eql(u8, text, "---");
}

/// Where the colon that ends a key is, or null where the line has no key on it.
/// A key ends at `: ` or at a colon that ends the line: that is what keeps
/// `server: https://host` one key and one value rather than two of each.
fn splitKey(text: []const u8) ?usize {
	var quote: u8 = 0;
	for (text, 0..) |char, i| {
		if (quote != 0) {
			if (char == quote) {
				quote = 0;
			}
			continue;
		}
		switch (char) {
			'\'', '"' => quote = char,
			':' => if (i + 1 == text.len or text[i + 1] == ' ') {
				return i;
			},
			else => {},
		}
	}
	return null;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

fn read(arena: std.mem.Allocator, text: []const u8) !Value {
	var why: List = .empty;
	return parse(arena, text, &why) catch |err| {
		std.debug.print("yaml refused: {s}\n", .{why.items});
		return err;
	};
}

test "a kubeconfig comes apart into clusters, contexts and users" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	const doc = try read(arena.allocator(),
		\\apiVersion: v1
		\\kind: Config
		\\current-context: work
		\\preferences: {}
		\\clusters:
		\\- cluster:
		\\    certificate-authority-data: QUJD
		\\    server: https://10.0.0.1:6443
		\\  name: work
		\\- cluster:
		\\    server: http://localhost:8080
		\\  name: local
		\\contexts:
		\\- context:
		\\    cluster: work
		\\    namespace: payments
		\\    user: alice
		\\  name: work
		\\users:
		\\- name: alice
		\\  user:
		\\    exec:
		\\      apiVersion: client.authentication.k8s.io/v1beta1
		\\      command: aws
		\\      args:
		\\      - --region
		\\      - eu-west-1
		\\      - eks
		\\      - get-token
		\\      env:
		\\      - name: AWS_PROFILE
		\\        value: work
	);
	try testing.expectEqualStrings("work", doc.get("current-context").?.text());
	// A colon in a value is not a key: the whole URL survives.
	const clusters = doc.get("clusters").?.items();
	try testing.expectEqual(@as(usize, 2), clusters.len);
	try testing.expectEqualStrings("work", clusters[0].get("name").?.text());
	try testing.expectEqualStrings("https://10.0.0.1:6443", clusters[0].at("cluster.server").?.text());
	try testing.expectEqualStrings("QUJD", clusters[0].at("cluster.certificate-authority-data").?.text());
	try testing.expectEqualStrings("http://localhost:8080", clusters[1].at("cluster.server").?.text());

	const contexts = doc.get("contexts").?.items();
	try testing.expectEqualStrings("payments", contexts[0].at("context.namespace").?.text());
	try testing.expectEqualStrings("alice", contexts[0].at("context.user").?.text());

	// A sequence of plain scalars, and one of maps, under the same key's child.
	const user = doc.get("users").?.items()[0];
	try testing.expectEqualStrings("aws", user.at("user.exec.command").?.text());
	const args = user.at("user.exec.args").?.items();
	try testing.expectEqual(@as(usize, 4), args.len);
	try testing.expectEqualStrings("--region", args[0].text());
	try testing.expectEqualStrings("get-token", args[3].text());
	const env = user.at("user.exec.env").?.items();
	try testing.expectEqualStrings("AWS_PROFILE", env[0].get("name").?.text());
	try testing.expectEqualStrings("work", env[0].get("value").?.text());

	// `{}` is an empty map, not the two characters.
	try testing.expect(doc.get("preferences").?.map.len == 0);
}

test "quoting, comments and an empty value" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	const doc = try read(arena.allocator(),
		\\# a comment on its own line
		\\plain: hello world   # and one after a value
		\\single: 'it''s here'
		\\double: "a\ttab and a \"quote\""
		\\hash-in-value: red#green
		\\empty:
		\\after: yes
	);
	try testing.expectEqualStrings("hello world", doc.get("plain").?.text());
	try testing.expectEqualStrings("it's here", doc.get("single").?.text());
	try testing.expectEqualStrings("a\ttab and a \"quote\"", doc.get("double").?.text());
	// A # only starts a comment after a space, so this is one value.
	try testing.expectEqualStrings("red#green", doc.get("hash-in-value").?.text());
	try testing.expectEqualStrings("", doc.get("empty").?.text());
	try testing.expectEqualStrings("yes", doc.get("after").?.text());
}

test "a block scalar is folded in rather than refused" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	const doc = try read(arena.allocator(),
		\\token: |-
		\\  one
		\\  two
		\\folded: >-
		\\  one
		\\  two
		\\after: end
	);
	try testing.expectEqualStrings("one\ntwo", doc.get("token").?.text());
	try testing.expectEqualStrings("one two", doc.get("folded").?.text());
	try testing.expectEqualStrings("end", doc.get("after").?.text());
}

test "what it does not understand it names, rather than reading it wrong" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	const cases = [_]struct { text: []const u8, says: []const u8 }{
		.{ .text = "base: &anchor\n  a: 1\n", .says = "anchor" },
		.{ .text = "a: 1\nb: *anchor\n", .says = "alias" },
		.{ .text = "a: !!binary QUJD\n", .says = "tag" },
		.{ .text = "a: 1\n\tb: 2\n", .says = "tab" },
		.{ .text = "a: [1, 2]\n", .says = "flow collection" },
		.{ .text = "a: 'unclosed\n", .says = "quote" },
		.{ .text = "a: 1\n    b: 2\n", .says = "indented further" },
	};
	for (cases) |case| {
		var why: List = .empty;
		try testing.expectError(error.Yaml, parse(arena.allocator(), case.text, &why));
		try testing.expect(std.mem.indexOf(u8, why.items, case.says) != null);
		// And it says where, so the file can be looked at.
		try testing.expect(std.mem.startsWith(u8, why.items, "line "));
	}
}

test "an empty document is an empty map, not a failure" {
	var arena = std.heap.ArenaAllocator.init(testing.allocator);
	defer arena.deinit();
	for ([_][]const u8{ "", "\n\n", "# nothing but a comment\n" }) |text| {
		const doc = try read(arena.allocator(), text);
		try testing.expect(doc.get("clusters") == null);
	}
}
