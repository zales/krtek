//! MQTT 3.1.1, as bytes.
//!
//! What a packet is made of, and nothing about a connection: text and numbers
//! in, bytes out, and the other way round. So it can be read, tested and thrown
//! malformed input at without a broker anywhere near it.
//!
//! 3.1.1 and not 5, on purpose. Everything a broker can be asked through this
//! program - connect, subscribe, publish, the three kinds of acknowledgement -
//! is in the older protocol, every broker still speaks it, and what 5 adds is
//! properties this would only have to skip.
//!
//! A packet is one byte saying what it is, a length written seven bits at a
//! time, and that many bytes. Strings carry their length in two bytes in front,
//! and that is the whole of the encoding.

const std = @import("std");

pub const List = std.ArrayList(u8);

/// The most a packet's body can be: what four bytes of seven bits each count to.
pub const MAX_BODY = 268_435_455;

pub const Kind = enum(u4) {
    connect = 1,
    connack = 2,
    publish = 3,
    puback = 4,
    pubrec = 5,
    pubrel = 6,
    pubcomp = 7,
    subscribe = 8,
    suback = 9,
    unsubscribe = 10,
    unsuback = 11,
    pingreq = 12,
    pingresp = 13,
    disconnect = 14,
};

pub const DecodeError = error{Malformed};

/// One packet as it came off the wire: what it is, the four bits beside that,
/// and its body. The body is a slice of what was read.
pub const Packet = struct {
    kind: Kind,
    flags: u4,
    body: []const u8,
    /// How many bytes of the input it was, header included.
    size: usize,
};

/// The packet at the front of `bytes`, or null when not all of it has arrived.
pub fn take(bytes: []const u8) DecodeError!?Packet {
    if (bytes.len < 2) {
        return null;
    }
    const kind = std.enums.fromInt(Kind, bytes[0] >> 4) orelse return error.Malformed;
    var length: usize = 0;
    var at: usize = 1;
    var shift: u6 = 0;
    while (true) {
        if (at >= bytes.len) {
            return null;
        }
        const byte = bytes[at];
        at += 1;
        length |= @as(usize, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) {
            break;
        }
        shift += 7;
        // A fifth byte of length is not a longer packet, it is not MQTT.
        if (shift > 21) {
            return error.Malformed;
        }
    }
    if (bytes.len - at < length) {
        return null;
    }
    return .{
        .kind = kind,
        .flags = @truncate(bytes[0]),
        .body = bytes[at .. at + length],
        .size = at + length,
    };
}

/// How many bytes the packet at the front of `bytes` will be once all of it is
/// here, or null where even its length has not arrived. For telling a packet
/// that is on its way from one that is larger than anybody will hold.
pub fn sizeOf(bytes: []const u8) DecodeError!?usize {
    var length: usize = 0;
    var at: usize = 1;
    var shift: u6 = 0;
    while (true) {
        if (at >= bytes.len) {
            return null;
        }
        const byte = bytes[at];
        at += 1;
        length |= @as(usize, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) {
            return at + length;
        }
        shift += 7;
        if (shift > 21) {
            return error.Malformed;
        }
    }
}

// ------------------------------------------------------------------ writing

fn header(out: *List, a: std.mem.Allocator, kind: Kind, flags: u4, length: usize) !void {
    try out.append(a, (@as(u8, @backingInt(kind)) << 4) | flags);
    var left = length;
    while (true) {
        var byte: u8 = @intCast(left & 0x7f);
        left >>= 7;
        if (left != 0) {
            byte |= 0x80;
        }
        try out.append(a, byte);
        if (left == 0) {
            break;
        }
    }
}

fn int16(out: *List, a: std.mem.Allocator, value: u16) !void {
    try out.append(a, @intCast(value >> 8));
    try out.append(a, @truncate(value));
}

fn string(out: *List, a: std.mem.Allocator, text: []const u8) !void {
    try int16(out, a, @intCast(text.len));
    try out.appendSlice(a, text);
}

pub const Connect = struct {
    client: []const u8,
    user: []const u8 = "",
    password: []const u8 = "",
    /// Seconds of silence after which the broker takes the client for gone.
    keepalive: u16 = 60,
};

/// The first packet of a connection. Always a clean session: this program is
/// somebody looking, and what a broker would keep for it while it was away is
/// what it was not there to see.
pub fn connect(out: *List, a: std.mem.Allocator, options: Connect) !void {
    var flags: u8 = 0x02; // clean session
    var length: usize = 10 + 2 + options.client.len;
    if (options.user.len != 0) {
        flags |= 0x80;
        length += 2 + options.user.len;
        // A password without a user is not something 3.1.1 can say.
        if (options.password.len != 0) {
            flags |= 0x40;
            length += 2 + options.password.len;
        }
    }
    try header(out, a, .connect, 0, length);
    try string(out, a, "MQTT");
    try out.append(a, 4); // 3.1.1
    try out.append(a, flags);
    try int16(out, a, options.keepalive);
    try string(out, a, options.client);
    if (options.user.len != 0) {
        try string(out, a, options.user);
        if (options.password.len != 0) {
            try string(out, a, options.password);
        }
    }
}

pub fn subscribe(out: *List, a: std.mem.Allocator, id: u16, filter: []const u8, qos: u2) !void {
    try header(out, a, .subscribe, 2, 2 + 2 + filter.len + 1);
    try int16(out, a, id);
    try string(out, a, filter);
    try out.append(a, qos);
}

pub fn unsubscribe(out: *List, a: std.mem.Allocator, id: u16, filter: []const u8) !void {
    try header(out, a, .unsubscribe, 2, 2 + 2 + filter.len);
    try int16(out, a, id);
    try string(out, a, filter);
}

pub const Publish = struct {
    topic: []const u8,
    payload: []const u8,
    qos: u2 = 0,
    retain: bool = false,
    dup: bool = false,
    /// Only there with a quality of service above zero: what the acknowledgement
    /// will name.
    id: u16 = 0,
};

pub fn publish(out: *List, a: std.mem.Allocator, message: Publish) !void {
    var flags: u4 = @as(u4, message.qos) << 1;
    if (message.retain) {
        flags |= 1;
    }
    if (message.dup) {
        flags |= 8;
    }
    const with_id: usize = if (message.qos != 0) 2 else 0;
    try header(out, a, .publish, flags, 2 + message.topic.len + with_id + message.payload.len);
    try string(out, a, message.topic);
    if (message.qos != 0) {
        try int16(out, a, message.id);
    }
    try out.appendSlice(a, message.payload);
}

/// The four packets that are a number and nothing else: `puback`, `pubrec`,
/// `pubrel` and `pubcomp`.
pub fn acknowledge(out: *List, a: std.mem.Allocator, kind: Kind, id: u16) !void {
    // PUBREL is the one of them with its flags set, because the standard says so.
    try header(out, a, kind, if (kind == .pubrel) 2 else 0, 2);
    try int16(out, a, id);
}

/// The same four bytes without a list to put them in, for the thread that
/// answers every message as it arrives.
pub fn acknowledgement(kind: Kind, id: u16) [4]u8 {
    const flags: u8 = if (kind == .pubrel) 2 else 0;
    return .{ (@as(u8, @backingInt(kind)) << 4) | flags, 2, @intCast(id >> 8), @truncate(id) };
}

pub const PINGREQ = [_]u8{ 0xc0, 0 };
pub const DISCONNECT = [_]u8{ 0xe0, 0 };

// ------------------------------------------------------------------ reading

/// A PUBLISH taken apart. The topic and the payload are slices of the packet.
pub fn readPublish(packet: Packet) DecodeError!Publish {
    const body = packet.body;
    if (body.len < 2) {
        return error.Malformed;
    }
    const topic_len = (@as(usize, body[0]) << 8) | body[1];
    var at: usize = 2;
    if (body.len - at < topic_len) {
        return error.Malformed;
    }
    const topic = body[at .. at + topic_len];
    at += topic_len;
    const qos: u2 = @truncate(packet.flags >> 1);
    if (qos == 3) {
        return error.Malformed;
    }
    var id: u16 = 0;
    if (qos != 0) {
        if (body.len - at < 2) {
            return error.Malformed;
        }
        id = (@as(u16, body[at]) << 8) | body[at + 1];
        at += 2;
    }
    return .{
        .topic = topic,
        .payload = body[at..],
        .qos = qos,
        .retain = packet.flags & 1 != 0,
        .dup = packet.flags & 8 != 0,
        .id = id,
    };
}

/// The number an acknowledgement names. SUBACK and UNSUBACK start with it too.
pub fn readId(packet: Packet) DecodeError!u16 {
    if (packet.body.len < 2) {
        return error.Malformed;
    }
    return (@as(u16, packet.body[0]) << 8) | packet.body[1];
}

/// What a broker said to CONNECT: zero is yes.
pub fn readConnack(packet: Packet) DecodeError!u8 {
    if (packet.kind != .connack or packet.body.len < 2) {
        return error.Malformed;
    }
    return packet.body[1];
}

/// What a broker said to a SUBSCRIBE of one filter: the quality of service it
/// granted, or null where it refused.
pub fn readSuback(packet: Packet) DecodeError!?u2 {
    if (packet.body.len < 3) {
        return error.Malformed;
    }
    const code = packet.body[2];
    return if (code <= 2) @intCast(code) else null;
}

/// A refusal in words. The numbers are the standard's, and so is the fact that
/// 4 and 5 are the two a password changes.
pub fn refusal(code: u8) []const u8 {
    return switch (code) {
        1 => "the broker does not speak MQTT 3.1.1",
        2 => "the broker does not accept this client id",
        3 => "the broker is not taking connections",
        4 => "the broker wants a user and a password, and these were not right",
        5 => "the broker did not authorise this connection - it wants a user and a password",
        else => "the broker refused the connection",
    };
}

// ------------------------------------------------------------------- topics

/// Whether a topic is one a filter asks for. `+` is one level, whatever is in
/// it; `#` is every level from there on, the one above it included; and a
/// filter that starts with either does not reach the topics that start with
/// `$`, which are the broker's own.
pub fn matches(filter: []const u8, topic: []const u8) bool {
    if (topic.len != 0 and topic[0] == '$' and filter.len != 0 and (filter[0] == '#' or filter[0] == '+')) {
        return false;
    }
    var wanted = std.mem.splitScalar(u8, filter, '/');
    var levels = std.mem.splitScalar(u8, topic, '/');
    while (true) {
        const want = wanted.next() orelse return levels.next() == null;
        if (std.mem.eql(u8, want, "#")) {
            return true;
        }
        const level = levels.next() orelse return false;
        if (!std.mem.eql(u8, want, "+") and !std.mem.eql(u8, want, level)) {
            return false;
        }
    }
}

/// Why a topic cannot be published to, or null where it can.
pub fn topicFault(topic: []const u8) ?[]const u8 {
    if (topic.len == 0) {
        return "a message needs a topic";
    }
    if (topic.len > 65535) {
        return "a topic is at most 65535 bytes";
    }
    if (std.mem.findAny(u8, topic, "+#") != null) {
        return "+ and # are for subscribing: a message goes to one topic, by its name";
    }
    if (std.mem.findScalar(u8, topic, 0) != null) {
        return "a topic cannot hold a zero byte";
    }
    return null;
}

/// Why a filter cannot be subscribed to, or null where it can.
pub fn filterFault(filter: []const u8) ?[]const u8 {
    if (filter.len == 0) {
        return "a subscription needs a filter - # is all of them";
    }
    if (filter.len > 65535) {
        return "a filter is at most 65535 bytes";
    }
    var levels = std.mem.splitScalar(u8, filter, '/');
    while (levels.next()) |level| {
        if (std.mem.eql(u8, level, "#")) {
            if (levels.next() != null) {
                return "# is every level from there on, so nothing can follow it";
            }
            return null;
        }
        if (std.mem.eql(u8, level, "+")) {
            continue;
        }
        if (std.mem.findAny(u8, level, "+#") != null) {
            return "+ and # stand for whole levels: a/+/b and a/#, not a/b+ or a/b#";
        }
    }
    return null;
}

// -------------------------------------------------------------------- tests

const testing = std.testing;

test "a length is written seven bits at a time, and read back" {
    const a = testing.allocator;
    for ([_]usize{ 0, 1, 127, 128, 16_383, 16_384, 2_097_151, 2_097_152, MAX_BODY }) |length| {
        var out: List = .empty;
        defer out.deinit(a);
        try header(&out, a, .publish, 0, length);
        // The standard's own table: one byte to 127, two to 16 383, and so on.
        const expected: usize = if (length < 128) 2 else if (length < 16_384) 3 else if (length < 2_097_152) 4 else 5;
        try testing.expectEqual(expected, out.items.len);
        try testing.expectEqual(@as(?usize, expected + length), try sizeOf(out.items));
    }
    // 321 is 0xc1 0x02 in the standard's example.
    var out: List = .empty;
    defer out.deinit(a);
    try header(&out, a, .publish, 0, 321);
    try testing.expectEqualSlices(u8, &.{ 0x30, 0xc1, 0x02 }, out.items);
}

test "a packet is taken when all of it is there, and not before" {
    const a = testing.allocator;
    var out: List = .empty;
    defer out.deinit(a);
    try publish(&out, a, .{ .topic = "a/b", .payload = "hello" });
    for (0..out.items.len) |cut| {
        try testing.expectEqual(@as(?Packet, null), try take(out.items[0..cut]));
    }
    const packet = (try take(out.items)).?;
    try testing.expectEqual(Kind.publish, packet.kind);
    try testing.expectEqual(out.items.len, packet.size);
    // And one more behind it does not change what the first one is.
    try out.appendSlice(a, &PINGREQ);
    try testing.expectEqual(packet.size, (try take(out.items)).?.size);
    const ping = (try take(out.items[packet.size..])).?;
    try testing.expectEqual(Kind.pingreq, ping.kind);
    try testing.expectEqual(@as(usize, 0), ping.body.len);
}

test "what is not MQTT is said to be so rather than waited for" {
    // Type 0 and type 15 are nobody's.
    try testing.expectError(error.Malformed, take(&.{ 0x00, 0x00 }));
    try testing.expectError(error.Malformed, take(&.{ 0xf0, 0x00 }));
    // A length that goes on for a fifth byte.
    try testing.expectError(error.Malformed, take(&.{ 0x30, 0xff, 0xff, 0xff, 0xff, 0x01 }));
    try testing.expectError(error.Malformed, sizeOf(&.{ 0x30, 0xff, 0xff, 0xff, 0xff, 0x01 }));
    // A PUBLISH whose topic is longer than the packet, one with no room for its
    // id, and a quality of service there is none of.
    try testing.expectError(error.Malformed, readPublish(.{ .kind = .publish, .flags = 0, .body = &.{ 0, 9, 'a' }, .size = 5 }));
    try testing.expectError(error.Malformed, readPublish(.{ .kind = .publish, .flags = 2, .body = &.{ 0, 1, 'a', 0 }, .size = 6 }));
    try testing.expectError(error.Malformed, readPublish(.{ .kind = .publish, .flags = 6, .body = &.{ 0, 1, 'a', 0, 1 }, .size = 7 }));
    try testing.expectError(error.Malformed, readId(.{ .kind = .puback, .flags = 0, .body = &.{1}, .size = 3 }));
    try testing.expectError(error.Malformed, readConnack(.{ .kind = .connack, .flags = 0, .body = &.{0}, .size = 3 }));
    try testing.expectError(error.Malformed, readSuback(.{ .kind = .suback, .flags = 0, .body = &.{ 0, 1 }, .size = 4 }));
}

test "a message comes back as it went out" {
    const a = testing.allocator;
    var out: List = .empty;
    defer out.deinit(a);
    try publish(&out, a, .{ .topic = "dum/kuchyn/teplota", .payload = "21.5", .qos = 1, .retain = true, .id = 7 });
    const message = try readPublish((try take(out.items)).?);
    try testing.expectEqualStrings("dum/kuchyn/teplota", message.topic);
    try testing.expectEqualStrings("21.5", message.payload);
    try testing.expectEqual(@as(u2, 1), message.qos);
    try testing.expect(message.retain);
    try testing.expect(!message.dup);
    try testing.expectEqual(@as(u16, 7), message.id);

    // Without a quality of service there is no id, and nothing is taken for one:
    // the first two bytes of the payload are the payload's.
    out.clearRetainingCapacity();
    try publish(&out, a, .{ .topic = "t", .payload = "\x00\x01rest" });
    const plain = try readPublish((try take(out.items)).?);
    try testing.expectEqualStrings("\x00\x01rest", plain.payload);
    try testing.expectEqual(@as(u16, 0), plain.id);
    // And nothing at all is a payload too: it is how a retained message is cleared.
    out.clearRetainingCapacity();
    try publish(&out, a, .{ .topic = "t", .payload = "", .retain = true });
    try testing.expectEqualStrings("", (try readPublish((try take(out.items)).?)).payload);
}

test "the first packet says who is asking, the way the standard writes it" {
    const a = testing.allocator;
    var out: List = .empty;
    defer out.deinit(a);
    try connect(&out, a, .{ .client = "krtek", .keepalive = 60 });
    try testing.expectEqualSlices(u8, &[_]u8{
        0x10, 17, 0, 4, 'M', 'Q', 'T', 'T', 4, 0x02, 0, 60, 0, 5, 'k', 'r', 't', 'e', 'k',
    }, out.items);

    out.clearRetainingCapacity();
    try connect(&out, a, .{ .client = "c", .user = "u", .password = "p" });
    const packet = (try take(out.items)).?;
    try testing.expectEqual(Kind.connect, packet.kind);
    // User and password, both flagged, in that order after the client id.
    try testing.expectEqual(@as(u8, 0xc2), packet.body[7]);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 'c', 0, 1, 'u', 0, 1, 'p' }, packet.body[10..]);

    // A password with nobody to belong to is left out rather than sent as a lie.
    out.clearRetainingCapacity();
    try connect(&out, a, .{ .client = "c", .password = "p" });
    try testing.expectEqual(@as(u8, 0x02), (try take(out.items)).?.body[7]);
}

test "subscribing, and the four packets that are only a number" {
    const a = testing.allocator;
    var out: List = .empty;
    defer out.deinit(a);
    try subscribe(&out, a, 10, "a/#", 1);
    try testing.expectEqualSlices(u8, &.{ 0x82, 8, 0, 10, 0, 3, 'a', '/', '#', 1 }, out.items);
    out.clearRetainingCapacity();
    try unsubscribe(&out, a, 11, "a/#");
    try testing.expectEqualSlices(u8, &.{ 0xa2, 7, 0, 11, 0, 3, 'a', '/', '#' }, out.items);
    out.clearRetainingCapacity();
    try acknowledge(&out, a, .puback, 258);
    try acknowledge(&out, a, .pubrel, 3);
    try testing.expectEqualSlices(u8, &.{ 0x40, 2, 1, 2, 0x62, 2, 0, 3 }, out.items);
    try testing.expectEqualSlices(u8, out.items[0..4], &acknowledgement(.puback, 258));
    try testing.expectEqualSlices(u8, out.items[4..8], &acknowledgement(.pubrel, 3));
    try testing.expectEqual(@as(u16, 258), try readId((try take(out.items)).?));

    try testing.expectEqual(@as(?u2, 1), try readSuback(.{ .kind = .suback, .flags = 0, .body = &.{ 0, 10, 1 }, .size = 5 }));
    try testing.expectEqual(@as(?u2, null), try readSuback(.{ .kind = .suback, .flags = 0, .body = &.{ 0, 10, 0x80 }, .size = 5 }));
    try testing.expectEqual(@as(u8, 5), try readConnack(.{ .kind = .connack, .flags = 0, .body = &.{ 0, 5 }, .size = 4 }));
}

test "a filter matches by levels" {
    try testing.expect(matches("#", "a"));
    try testing.expect(matches("#", "a/b/c"));
    try testing.expect(matches("a/#", "a/b/c"));
    // The level above is included: `a/#` is `a` and everything under it.
    try testing.expect(matches("a/#", "a"));
    try testing.expect(matches("a/+/c", "a/b/c"));
    try testing.expect(matches("a/+/c", "a//c"));
    try testing.expect(matches("+/+", "/a"));
    try testing.expect(matches("a/b", "a/b"));
    try testing.expect(!matches("a/+", "a/b/c"));
    try testing.expect(!matches("a/+", "a"));
    try testing.expect(!matches("a/b", "a/b/c"));
    try testing.expect(!matches("a/b/c", "a/b"));
    try testing.expect(!matches("A/b", "a/b"));
    try testing.expect(!matches("+", "a/b"));
    // The broker's own topics are asked for by name.
    try testing.expect(!matches("#", "$SYS/broker/version"));
    try testing.expect(!matches("+/broker/version", "$SYS/broker/version"));
    try testing.expect(matches("$SYS/#", "$SYS/broker/version"));
    try testing.expect(matches("$SYS/+/version", "$SYS/broker/version"));
}

test "a topic and a filter that cannot be are refused with the reason" {
    try testing.expect(topicFault("a/b") == null);
    try testing.expect(topicFault("/") == null);
    try testing.expect(topicFault("") != null);
    try testing.expect(topicFault("a/+") != null);
    try testing.expect(topicFault("a/#") != null);
    try testing.expect(topicFault("a\x00b") != null);

    for ([_][]const u8{ "#", "+", "a/#", "a/+/b", "+/+/#", "/", "a//b", "$SYS/#" }) |filter| {
        try testing.expect(filterFault(filter) == null);
    }
    for ([_][]const u8{ "", "a/#/b", "a#", "a/b+", "#/a", "a/+b/c" }) |filter| {
        try testing.expect(filterFault(filter) != null);
    }
}

/// Malformed bytes at the decoder: whatever they are, the answer is a packet,
/// "not yet", or `Malformed` - never a read past the end.
pub fn fuzzPackets(input: []const u8) void {
    var rest = input;
    while (rest.len != 0) {
        _ = sizeOf(rest) catch {};
        const packet = (take(rest) catch return) orelse return;
        switch (packet.kind) {
            .publish => _ = readPublish(packet) catch {},
            .connack => _ = readConnack(packet) catch {},
            .suback => _ = readSuback(packet) catch {},
            else => _ = readId(packet) catch {},
        }
        rest = rest[packet.size..];
    }
}

test "any bytes at all are a packet, not yet one, or malformed" {
    var random = std.Random.DefaultPrng.init(0x6d717474);
    var bytes: [64]u8 = undefined;
    for (0..20_000) |_| {
        random.random().bytes(&bytes);
        const length = random.random().uintLessThan(usize, bytes.len + 1);
        fuzzPackets(bytes[0..length]);
    }
}
