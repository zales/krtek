//! What a Kafka request and a reply are made of.
//!
//! The protocol is length-prefixed messages with a version per API. The versions
//! this driver speaks are deliberately the newest ones that are *not* flexible:
//! from Kafka 2.4 onwards every API grew compact strings and tagged fields, and
//! none of that is needed to read a topic. Brokers still answer the older ones, so
//! there is one encoding in here instead of two.
//!
//! Nothing in this file knows about a socket. It turns numbers and strings into
//! bytes and back, which is the part worth reading on its own and the part the
//! fuzzer can reach without a broker.

const std = @import("std");
const db = @import("../db.zig");

const List = db.List;

pub const Api = enum(i16) {
    produce = 0,
    fetch = 1,
    list_offsets = 2,
    metadata = 3,
    api_versions = 18,
    create_topics = 19,
    delete_topics = 20,
    delete_records = 21,
    describe_configs = 32,
    list_groups = 16,
    sasl_handshake = 17,
    sasl_authenticate = 36,
};

/// The version this driver speaks for each API: the last one before that API
/// became flexible, so there are no compact strings or tagged fields anywhere.
pub fn versionOf(api: Api) i16 {
    return switch (api) {
        .produce => 8,
        .fetch => 11,
        .list_offsets => 5,
        .metadata => 7,
        .api_versions => 0,
        .create_topics => 3,
        .delete_topics => 3,
        .delete_records => 1,
        .describe_configs => 2,
        .list_groups => 2,
        .sasl_handshake => 1,
        .sasl_authenticate => 1,
    };
}

pub const Error = db.Error;

/// Big-endian, which is the only endianness Kafka has.
pub const Encoder = struct {
    out: *List,
    a: std.mem.Allocator,

    pub fn int8(self: Encoder, value: i8) !void {
        try self.out.append(self.a, @bitCast(value));
    }

    pub fn int16(self: Encoder, value: i16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(i16, &buf, value, .big);
        try self.out.appendSlice(self.a, &buf);
    }

    pub fn int32(self: Encoder, value: i32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(i32, &buf, value, .big);
        try self.out.appendSlice(self.a, &buf);
    }

    pub fn int64(self: Encoder, value: i64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &buf, value, .big);
        try self.out.appendSlice(self.a, &buf);
    }

    pub fn boolean(self: Encoder, value: bool) !void {
        try self.int8(if (value) 1 else 0);
    }

    pub fn string(self: Encoder, text: []const u8) !void {
        try self.int16(@intCast(text.len));
        try self.out.appendSlice(self.a, text);
    }

    /// A string that may be absent, which is a length of -1.
    pub fn nullableString(self: Encoder, text: ?[]const u8) !void {
        if (text) |bytes| {
            try self.string(bytes);
        } else {
            try self.int16(-1);
        }
    }

    pub fn byteArray(self: Encoder, value: ?[]const u8) !void {
        if (value) |slice| {
            try self.int32(@intCast(slice.len));
            try self.out.appendSlice(self.a, slice);
        } else {
            try self.int32(-1);
        }
    }

    pub fn array(self: Encoder, count: usize) !void {
        try self.int32(@intCast(count));
    }

    pub fn varint(self: Encoder, value: i32) !void {
        try self.varlong(value);
    }

    /// Zig-zag, as the record format uses it.
    pub fn varlong(self: Encoder, value: i64) !void {
        var rest: u64 = @bitCast((value << 1) ^ (value >> 63));
        while (true) {
            const byte: u8 = @intCast(rest & 0x7f);
            rest >>= 7;
            if (rest == 0) {
                try self.out.append(self.a, byte);
                return;
            }
            try self.out.append(self.a, byte | 0x80);
        }
    }
};

pub const DecodeError = error{ Malformed, OutOfMemory };

pub const Decoder = struct {
    bytes: []const u8,
    at: usize = 0,

    pub fn take(self: *Decoder, count: usize) DecodeError![]const u8 {
        if (self.at + count > self.bytes.len) {
            return error.Malformed;
        }
        defer self.at += count;
        return self.bytes[self.at .. self.at + count];
    }

    pub fn int8(self: *Decoder) DecodeError!i8 {
        const slice = try self.take(1);
        return @bitCast(slice[0]);
    }

    pub fn int16(self: *Decoder) DecodeError!i16 {
        return std.mem.readInt(i16, (try self.take(2))[0..2], .big);
    }

    pub fn int32(self: *Decoder) DecodeError!i32 {
        return std.mem.readInt(i32, (try self.take(4))[0..4], .big);
    }

    pub fn int64(self: *Decoder) DecodeError!i64 {
        return std.mem.readInt(i64, (try self.take(8))[0..8], .big);
    }

    pub fn uint32(self: *Decoder) DecodeError!u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .big);
    }

    pub fn string(self: *Decoder) DecodeError![]const u8 {
        const length = try self.int16();
        if (length < 0) {
            return "";
        }
        return self.take(@intCast(length));
    }

    pub fn nullableBytes(self: *Decoder) DecodeError!?[]const u8 {
        const length = try self.int32();
        if (length < 0) {
            return null;
        }
        return try self.take(@intCast(length));
    }

    pub fn boolean(self: *Decoder) DecodeError!bool {
        return (try self.int8()) != 0;
    }

    pub fn arrayLength(self: *Decoder) DecodeError!usize {
        const count = try self.int32();
        if (count < 0) {
            return 0;
        }
        return @intCast(count);
    }

    pub fn varint(self: *Decoder) DecodeError!i32 {
        const value = try self.varlong();
        // A varint that does not fit is malformed, not a reason to abort: every
        // length inside a record is one of these, so this is the first thing a
        // corrupted batch reaches.
        if (value > std.math.maxInt(i32) or value < std.math.minInt(i32)) {
            return error.Malformed;
        }
        return @intCast(value);
    }

    pub fn varlong(self: *Decoder) DecodeError!i64 {
        var shift: u6 = 0;
        var raw: u64 = 0;
        while (true) {
            const byte = (try self.take(1))[0];
            raw |= @as(u64, byte & 0x7f) << shift;
            if (byte & 0x80 == 0) {
                break;
            }
            if (shift >= 63) {
                return error.Malformed;
            }
            shift += 7;
        }
        // Zig-zag back to a signed number, without arithmetic that can overflow:
        // negating (raw >> 1) + 1 blows up when the halved value is i64's largest,
        // which any ten bytes of 0xff off the wire produce. Two's complement does the
        // same job with a mask - all ones for an odd number, all zeroes for an even
        // one - and cannot.
        const shifted: u64 = raw >> 1;
        const mask: u64 = 0 -% (raw & 1);
        return @bitCast(shifted ^ mask);
    }

    pub fn rest(self: *Decoder) []const u8 {
        defer self.at = self.bytes.len;
        return self.bytes[self.at..];
    }
};

/// CRC-32C, which is what a record batch carries. Table built at compile time.
pub fn crc32c(bytes: []const u8) u32 {
    const table = comptime blk: {
        @setEvalBranchQuota(20000);
        var built: [256]u32 = undefined;
        for (0..256) |i| {
            var value: u32 = @intCast(i);
            for (0..8) |_| {
                value = if (value & 1 != 0) (value >> 1) ^ 0x82f63b78 else value >> 1;
            }
            built[i] = value;
        }
        break :blk built;
    };
    var crc: u32 = 0xffffffff;
    for (bytes) |byte| {
        crc = table[(crc ^ byte) & 0xff] ^ (crc >> 8);
    }
    return crc ^ 0xffffffff;
}

/// The hash Kafka's own clients use to choose a partition for a key, so a key
/// written from here lands where it would have landed from anywhere else.
pub fn murmur2(bytes: []const u8) i32 {
    const seed: u32 = 0x9747b28c;
    const m: u32 = 0x5bd1e995;
    const r: u5 = 24;
    var h: u32 = seed ^ @as(u32, @intCast(bytes.len));
    var at: usize = 0;
    while (at + 4 <= bytes.len) : (at += 4) {
        var k: u32 = std.mem.readInt(u32, bytes[at..][0..4], .little);
        k *%= m;
        k ^= k >> r;
        k *%= m;
        h *%= m;
        h ^= k;
    }
    const left = bytes.len - at;
    if (left == 3) {
        h ^= @as(u32, bytes[at + 2]) << 16;
    }
    if (left >= 2) {
        h ^= @as(u32, bytes[at + 1]) << 8;
    }
    if (left >= 1) {
        h ^= @as(u32, bytes[at]);
        h *%= m;
    }
    h ^= h >> 13;
    h *%= m;
    h ^= h >> 15;
    return @bitCast(h);
}

/// Codes that mean the cluster has moved on rather than that the request was
/// wrong: a leader election, a broker restarting, a partition being reassigned.
/// The answer to all of them is the same - ask for metadata again and try once
/// more - which is what every Kafka client does and what this one did not.
pub fn movedOn(code: i16) bool {
    return switch (code) {
        5, // the leader is not available yet
        6, // this broker is not the leader for that partition
        7, // the request timed out
        9, // the replica is not available
        17, // the topic is being reassigned
        41, // this broker is not the controller
        => true,
        else => false,
    };
}

/// The error codes a broker sends back, in the words the protocol gives them.
pub fn errorText(code: i16) []const u8 {
    return switch (code) {
        0 => "none",
        1 => "the offset is out of range",
        2 => "the record is corrupt",
        3 => "no such topic or partition",
        5 => "the leader is not available yet",
        6 => "this broker is not the leader for that partition",
        7 => "the request timed out",
        8 => "the broker is not available",
        9 => "the replica is not available",
        10 => "the message is larger than the broker allows",
        13 => "the network failed mid-request",
        15 => "the coordinator is not available",
        17 => "the topic is being reassigned",
        19 => "not enough replicas to accept the write",
        20 => "not enough replicas after appending",
        21 => "the requested acks are invalid",
        29, 30, 31 => "not authorised for that",
        36 => "the topic already exists",
        37 => "the number of partitions is invalid",
        38 => "the replication factor is invalid",
        39 => "the replica assignment is invalid",
        40 => "the configuration is invalid",
        41 => "this broker is not the controller",
        58 => "the request is not allowed on that resource",
        87 => "the records are not in order",
        else => "an error the broker did not name",
    };
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "a varint survives the round trip, sign and all" {
    var out: List = .empty;
    defer out.deinit(testing.allocator);
    const write = Encoder{ .out = &out, .a = testing.allocator };
    const numbers = [_]i64{ 0, 1, -1, 63, 64, -64, -65, 127, 128, 300, -300, 1 << 20, -(1 << 20), std.math.maxInt(i32), std.math.minInt(i32) };
    for (numbers) |number| {
        try write.varlong(number);
    }
    var read = Decoder{ .bytes = out.items };
    for (numbers) |number| {
        try testing.expectEqual(number, try read.varlong());
    }
    try testing.expectEqual(out.items.len, read.at);
}

test "a varint of ten 0xff bytes is a number, not a crash" {
    // The largest zig-zag encoding there is. Decoding it used to negate i64's
    // largest value plus one, which overflows - and every length inside a record is
    // a varint, so any corrupt batch reached it.
    const worst = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 };
    var read = Decoder{ .bytes = &worst };
    const value = try read.varlong();
    try testing.expectEqual(std.math.minInt(i64), value);

    // And as an i32, which is what a record's lengths are read as: too large to fit
    // is malformed rather than truncated to something plausible.
    var again = Decoder{ .bytes = &worst };
    try testing.expectError(error.Malformed, again.varint());

    // The two ends of the range still come back as themselves.
    var out: List = .empty;
    defer out.deinit(testing.allocator);
    const write = Encoder{ .out = &out, .a = testing.allocator };
    try write.varlong(std.math.minInt(i64));
    try write.varlong(std.math.maxInt(i64));
    var back = Decoder{ .bytes = out.items };
    try testing.expectEqual(std.math.minInt(i64), try back.varlong());
    try testing.expectEqual(std.math.maxInt(i64), try back.varlong());
}

test "the fixed width numbers are big endian, as the protocol says" {
    var out: List = .empty;
    defer out.deinit(testing.allocator);
    const write = Encoder{ .out = &out, .a = testing.allocator };
    try write.int16(1);
    try write.int32(-2);
    try write.int64(258);
    try testing.expectEqualSlices(u8, &[_]u8{
        0,    1,
        0xff, 0xff,
        0xff, 0xfe,
        0,    0,
        0,    0,
        0,    0,
        1,    2,
    }, out.items);

    var read = Decoder{ .bytes = out.items };
    try testing.expectEqual(@as(i16, 1), try read.int16());
    try testing.expectEqual(@as(i32, -2), try read.int32());
    try testing.expectEqual(@as(i64, 258), try read.int64());
}

test "a string and a byte array carry their own length, and absence is -1" {
    var out: List = .empty;
    defer out.deinit(testing.allocator);
    const write = Encoder{ .out = &out, .a = testing.allocator };
    try write.string("orders");
    try write.nullableString(null);
    try write.byteArray(null);
    try write.byteArray("ab");

    var read = Decoder{ .bytes = out.items };
    try testing.expectEqualStrings("orders", try read.string());
    try testing.expectEqualStrings("", try read.string());
    try testing.expect((try read.nullableBytes()) == null);
    try testing.expectEqualStrings("ab", (try read.nullableBytes()).?);
}

test "every API this driver speaks is one the broker still answers without flexible encoding" {
    // The point of these versions: none of them uses compact strings or tagged
    // fields, so there is one encoding in this file instead of two.
    try testing.expectEqual(@as(i16, 11), versionOf(.fetch));
    try testing.expectEqual(@as(i16, 7), versionOf(.metadata));
    try testing.expectEqual(@as(i16, 0), versionOf(.api_versions));
    inline for (std.meta.fields(Api)) |field| {
        const api: Api = @enumFromInt(field.value);
        try testing.expect(versionOf(api) >= 0);
    }
}

test "CRC-32C is the one a record batch carries" {
    // The check value every CRC-32C implementation is measured by.
    try testing.expectEqual(@as(u32, 0xe3069283), crc32c("123456789"));
    try testing.expectEqual(@as(u32, 0), crc32c(""));
}

test "murmur2 puts a key where kafka's own client would put it" {
    // Nine keys were written to a three-partition topic by kafka-console-producer,
    // which chooses the partition with murmur2 of the key. This is where its Java
    // implementation put them, so it is where this one has to put them too.
    const expected = [_]struct { key: []const u8, partition: i32 }{
        .{ .key = "key1", .partition = 2 },
        .{ .key = "key2", .partition = 2 },
        .{ .key = "key3", .partition = 1 },
        .{ .key = "key4", .partition = 0 },
        .{ .key = "key5", .partition = 1 },
        .{ .key = "key6", .partition = 0 },
        .{ .key = "key7", .partition = 0 },
        .{ .key = "key8", .partition = 1 },
        .{ .key = "key9", .partition = 2 },
    };
    for (expected) |one| {
        const hash = murmur2(one.key) & 0x7fffffff;
        try testing.expectEqual(one.partition, @mod(hash, 3));
    }
}

test "the codes that mean the cluster moved, and the ones that mean no" {
    // A leader election, a broker restarting, a partition being reassigned: ask for
    // metadata again and try once more.
    for ([_]i16{ 5, 6, 7, 9, 17, 41 }) |code| {
        try testing.expect(movedOn(code));
    }
    // And the ones where trying again would only ask the same wrong question.
    for ([_]i16{ 0, 1, 2, 3, 36, 37, 38, 58 }) |code| {
        try testing.expect(!movedOn(code));
    }
    // Every one of them still has words of its own; a code nobody named says so
    // rather than pretending.
    try testing.expectEqualStrings("this broker is not the leader for that partition", errorText(6));
    try testing.expectEqualStrings("the topic already exists", errorText(36));
    try testing.expectEqualStrings("an error the broker did not name", errorText(1234));
}
