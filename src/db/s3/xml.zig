//! Just enough XML to read what S3 answers.
//!
//! S3's replies are a handful of shapes - a list of objects, a list of buckets,
//! an error - all of them elements with text in them and no attributes worth
//! reading. So this is a pull parser over a string: it hands out an element
//! opening, some text, an element closing, and knows nothing about namespaces,
//! entities beyond the five, DTDs or validation. A general XML parser would be
//! ten times this and would still only be used for these four shapes.
//!
//! It never fails. Malformed input runs out of events rather than reporting an
//! error, because a driver that got nonsense back from something claiming to be
//! S3 has nothing better to do with the reason than say the reply made no sense -
//! which the missing element already says.

const std = @import("std");
const db = @import("../db.zig");

const List = db.List;

pub const Event = union(enum) {
	open: []const u8,
	close: []const u8,
	/// Still escaped: `unescape` is the caller's to call, on the few values where
	/// an `&` is possible.
	text: []const u8,
};

pub const Reader = struct {
	text: []const u8,
	at: usize = 0,
	/// An element written `<Foo/>` closes as soon as it opens, and the close is
	/// handed out on the next call.
	pending: ?[]const u8 = null,

	pub fn next(self: *Reader) ?Event {
		if (self.pending) |name| {
			self.pending = null;
			return .{ .close = name };
		}
		while (self.at < self.text.len) {
			if (self.text[self.at] != '<') {
				const end = std.mem.indexOfScalarPos(u8, self.text, self.at, '<') orelse self.text.len;
				const chunk = self.text[self.at..end];
				self.at = end;
				if (std.mem.trim(u8, chunk, " \t\r\n").len == 0) {
					continue;
				}
				return .{ .text = chunk };
			}
			const rest = self.text[self.at..];
			// A comment, a declaration or a processing instruction: skipped whole,
			// because a `>` inside a comment is not the end of anything.
			if (std.mem.startsWith(u8, rest, "<!--")) {
				self.at = if (std.mem.indexOfPos(u8, self.text, self.at, "-->")) |end| end + 3 else self.text.len;
				continue;
			}
			if (std.mem.startsWith(u8, rest, "<?")) {
				self.at = if (std.mem.indexOfPos(u8, self.text, self.at, "?>")) |end| end + 2 else self.text.len;
				continue;
			}
			const end = std.mem.indexOfScalarPos(u8, self.text, self.at, '>') orelse return null;
			const inner = self.text[self.at + 1 .. end];
			self.at = end + 1;
			if (inner.len == 0 or inner[0] == '!') {
				continue;
			}
			if (inner[0] == '/') {
				return .{ .close = nameOf(inner[1..]) };
			}
			const tag = nameOf(inner);
			if (inner[inner.len - 1] == '/') {
				self.pending = tag;
			}
			return .{ .open = tag };
		}
		return null;
	}
};

/// The element name out of what stood inside the angle brackets, with any
/// attributes and any namespace prefix left behind.
fn nameOf(inner: []const u8) []const u8 {
	var end: usize = 0;
	while (end < inner.len and !std.ascii.isWhitespace(inner[end]) and inner[end] != '/') : (end += 1) {}
	const whole = inner[0..end];
	if (std.mem.lastIndexOfScalar(u8, whole, ':')) |colon| {
		return whole[colon + 1 ..];
	}
	return whole;
}

/// The text of the first element with this name, wherever it is. What the small
/// replies need: the code out of an error, the token that continues a listing.
pub fn find(text: []const u8, name: []const u8) ?[]const u8 {
	var reader = Reader{ .text = text };
	while (reader.next()) |event| {
		switch (event) {
			.open => |tag| {
				if (!std.mem.eql(u8, tag, name)) {
					continue;
				}
				return switch (reader.next() orelse return "") {
					.text => |value| value,
					// `<Prefix/>` and `<Prefix></Prefix>` both mean no prefix.
					else => "",
				};
			},
			else => {},
		}
	}
	return null;
}

/// The five entities XML defines and the numeric ones, which is everything S3
/// writes: a key may contain any byte, and `a&b` comes back as `a&amp;b`.
pub fn unescape(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
	if (std.mem.indexOfScalar(u8, text, '&') == null) {
		return text;
	}
	var out: List = .empty;
	var at: usize = 0;
	while (at < text.len) {
		if (text[at] != '&') {
			try out.append(arena, text[at]);
			at += 1;
			continue;
		}
		const end = std.mem.indexOfScalarPos(u8, text, at, ';') orelse {
			try out.append(arena, text[at]);
			at += 1;
			continue;
		};
		const entity = text[at + 1 .. end];
		at = end + 1;
		if (std.mem.eql(u8, entity, "amp")) {
			try out.append(arena, '&');
		} else if (std.mem.eql(u8, entity, "lt")) {
			try out.append(arena, '<');
		} else if (std.mem.eql(u8, entity, "gt")) {
			try out.append(arena, '>');
		} else if (std.mem.eql(u8, entity, "quot")) {
			try out.append(arena, '"');
		} else if (std.mem.eql(u8, entity, "apos")) {
			try out.append(arena, '\'');
		} else if (entity.len > 1 and entity[0] == '#') {
			const hex = entity[1] == 'x' or entity[1] == 'X';
			const digits = if (hex) entity[2..] else entity[1..];
			const code = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch {
				try out.print(arena, "&{s};", .{entity});
				continue;
			};
			var buffer: [4]u8 = undefined;
			const wrote = std.unicode.utf8Encode(code, &buffer) catch {
				try out.print(arena, "&{s};", .{entity});
				continue;
			};
			try out.appendSlice(arena, buffer[0..wrote]);
		} else {
			// Something else entirely: kept as it stands rather than swallowed.
			try out.print(arena, "&{s};", .{entity});
		}
	}
	return out.items;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "an element, its text and its close come out in order" {
	var reader = Reader{ .text = 
	\\<?xml version="1.0" encoding="UTF-8"?>
	\\<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
	\\  <Name>photos</Name>
	\\  <!-- a comment, which is not an element -->
	\\  <IsTruncated>false</IsTruncated>
	\\</ListBucketResult>
	};
	try testing.expectEqualStrings("ListBucketResult", reader.next().?.open);
	try testing.expectEqualStrings("Name", reader.next().?.open);
	try testing.expectEqualStrings("photos", reader.next().?.text);
	try testing.expectEqualStrings("Name", reader.next().?.close);
	try testing.expectEqualStrings("IsTruncated", reader.next().?.open);
	try testing.expectEqualStrings("false", reader.next().?.text);
	try testing.expectEqualStrings("IsTruncated", reader.next().?.close);
	try testing.expectEqualStrings("ListBucketResult", reader.next().?.close);
	try testing.expect(reader.next() == null);
}

test "an element that closes itself still closes" {
	var reader = Reader{ .text = "<Contents><Key>a</Key><Owner/></Contents>" };
	try testing.expectEqualStrings("Contents", reader.next().?.open);
	try testing.expectEqualStrings("Key", reader.next().?.open);
	try testing.expectEqualStrings("a", reader.next().?.text);
	try testing.expectEqualStrings("Key", reader.next().?.close);
	try testing.expectEqualStrings("Owner", reader.next().?.open);
	try testing.expectEqualStrings("Owner", reader.next().?.close);
	try testing.expectEqualStrings("Contents", reader.next().?.close);
	try testing.expect(reader.next() == null);
}

test "a value is found by name, wherever it is" {
	const text =
		\\<Error><Code>NoSuchBucket</Code><Message>The specified bucket does not exist</Message></Error>
	;
	try testing.expectEqualStrings("NoSuchBucket", find(text, "Code").?);
	try testing.expectEqualStrings("The specified bucket does not exist", find(text, "Message").?);
	try testing.expect(find(text, "Key") == null);
	// An empty element is found and is empty, which is not the same as missing.
	try testing.expectEqualStrings("", find("<ListBucketResult><Prefix/></ListBucketResult>", "Prefix").?);
	// A namespace prefix is not part of the name.
	try testing.expectEqualStrings("2", find("<ns:Result><ns:KeyCount>2</ns:KeyCount></ns:Result>", "KeyCount").?);
}

test "entities come back as the bytes they stand for" {
	var scratch = std.heap.ArenaAllocator.init(testing.allocator);
	defer scratch.deinit();
	const arena = scratch.allocator();

	try testing.expectEqualStrings("a&b", try unescape(arena, "a&amp;b"));
	try testing.expectEqualStrings("<x> \"y\" 'z'", try unescape(arena, "&lt;x&gt; &quot;y&quot; &apos;z&apos;"));
	try testing.expectEqualStrings("kř", try unescape(arena, "k&#345;"));
	try testing.expectEqualStrings("kř", try unescape(arena, "k&#x159;"));
	// Nothing to do, and nothing copied.
	try testing.expectEqualStrings("plain", try unescape(arena, "plain"));
	// Not an entity anybody defined: left as it was rather than eaten.
	try testing.expectEqualStrings("&nbsp;", try unescape(arena, "&nbsp;"));
	try testing.expectEqualStrings("a & b", try unescape(arena, "a & b"));
}

test "nonsense runs out of events instead of misbehaving" {
	var reader = Reader{ .text = "<Contents><Key>unterminated" };
	try testing.expectEqualStrings("Contents", reader.next().?.open);
	try testing.expectEqualStrings("Key", reader.next().?.open);
	try testing.expectEqualStrings("unterminated", reader.next().?.text);
	try testing.expect(reader.next() == null);

	var truncated = Reader{ .text = "<Contents" };
	try testing.expect(truncated.next() == null);
	try testing.expect(find("not xml at all", "Key") == null);
}
