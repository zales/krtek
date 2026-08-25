//! The four compression codecs a record batch can be packed with.
//!
//! Kafka compresses a whole batch, and which codec is in the batch's attributes.
//! gzip and zstd come out of the standard library; snappy and lz4 are written out
//! here, because they are small formats and a driver that cannot read half the
//! topics in the world is not much of a driver.
//!
//! Nothing in this file knows about a connection: it takes bytes and gives bytes
//! back, which is what makes it worth fuzzing on its own - see tests/fuzz.zig.

const std = @import("std");
const db = @import("../db.zig");

const List = db.List;

pub const Codec = enum(u3) {
    none = 0,
    gzip = 1,
    snappy = 2,
    lz4 = 3,
    zstd = 4,
    _,
};

/// What to call a codec in a message. Not `@tagName`: the attributes of a batch
/// carry three bits, so five of the eight values have names and three do not, and
/// `@tagName` of one that does not is a panic rather than a string. A broker only
/// has to set those bits - by corruption, or by being newer than this program - to
/// bring krtek down, which is what the fuzzer found within seconds of existing.
pub fn codecName(codec: Codec) []const u8 {
    return switch (codec) {
        .none => "none",
        .gzip => "gzip",
        .snappy => "snappy",
        .lz4 => "lz4",
        .zstd => "zstd",
        // The number is what a person needs in order to look it up.
        _ => "an unknown codec",
    };
}

/// How much readable slack to leave after a compressed payload. A bit reader that
/// runs off the end lands here rather than past the buffer.
const SLACK = 64;

/// The most a batch may unpack to. A fetch brings back at most PARTITION_BYTES per
/// partition, so even very compressible records cannot honestly exceed this - and
/// the length that says otherwise is a number out of the bytes being parsed. Before
/// this, snappy reserved whatever its input claimed: a corrupt batch asking for
/// four gigabytes got four gigabytes, which the fuzzer demonstrated by taking the
/// machine down to its last page of memory.
pub const MAX_UNPACKED: usize = 64 << 20;

pub const CompressError = error{ Malformed, Unsupported, OutOfMemory };

pub fn decompress(arena: std.mem.Allocator, codec: Codec, bytes: []const u8) CompressError![]const u8 {
    return switch (codec) {
        .none => bytes,
        .gzip => unzip(arena, bytes),
        .snappy => unsnap(arena, bytes),
        .lz4 => unlz4(arena, bytes),
        .zstd => unzstd(arena, bytes),
        _ => error.Unsupported,
    };
}

/// Read a decompressing stream to its end, into memory.
///
/// Through a writer that owns a growing buffer rather than through
/// `allocRemaining`: the inflater asks its writer to keep the last 32 KB of output
/// available - that is where a back reference points - and a writer that cannot
/// hits `unreachable` inside the standard library on input that is merely corrupt.
/// The fuzzer found that with a mangled gzip member.
fn drain(arena: std.mem.Allocator, reader: *std.Io.Reader) CompressError![]const u8 {
    var out = std.Io.Writer.Allocating.initCapacity(arena, 64 * 1024) catch return error.OutOfMemory;
    var written: usize = 0;
    // The same shape as streamRemaining, with a running total: a stream that keeps
    // producing is stopped at the ceiling rather than followed to the end of memory.
    while (true) {
        written += reader.stream(&out.writer, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            error.WriteFailed => return error.OutOfMemory,
            else => return error.Malformed,
        };
        if (written > MAX_UNPACKED) {
            return error.Malformed;
        }
    }
    const list = out.toArrayList();
    return list.items;
}

fn unzip(arena: std.mem.Allocator, bytes: []const u8) CompressError![]const u8 {
    // Room after the input, and this is not tidiness: Zig 0.16.0's inflater, given a
    // corrupt stream, tosses more bits than it has read and trips
    // `assert(seek <= end)` inside the reader it is tossing from. The slack is where
    // that over-toss lands, so it reaches its own error instead of an unreachable.
    // A deflate stream ends where its own bits say it ends, so trailing zeroes change
    // nothing about a sound one. Found by the fuzzer, held by it across millions of
    // inputs, and to be taken out when the standard library stops needing it.
    const padded = try arena.alloc(u8, bytes.len + SLACK);
    @memcpy(padded[0..bytes.len], bytes);
    @memset(padded[bytes.len..], 0);
    var input = std.Io.Reader.fixed(padded);
    // And no window of its own: with one, the inflater keeps the history itself and
    // streams through a writer that cannot make room. With none it writes straight
    // into the caller's, which grows - see `drain`.
    var stream = std.compress.flate.Decompress.init(&input, .gzip, &.{});
    return drain(arena, &stream.reader);
}

fn unzstd(arena: std.mem.Allocator, bytes: []const u8) CompressError![]const u8 {
    var input = std.Io.Reader.fixed(bytes);
    // Buffer-less for the same reason as gzip above.
    var stream = std.compress.zstd.Decompress.init(&input, &.{}, .{});
    return drain(arena, &stream.reader);
}

/// Snappy, as Kafka writes it: the raw format, not the framed one. A varint
/// length, then a run of elements which either copy literal bytes or repeat what
/// has already been written.
pub fn unsnap(arena: std.mem.Allocator, bytes: []const u8) CompressError![]const u8 {
    // Kafka's own producers write "xerial" framing when the java client is used:
    // a magic header, then length-prefixed snappy blocks. Both shapes appear in
    // the wild, so the header decides.
    const xerial = [_]u8{ 0x82, 'S', 'N', 'A', 'P', 'P', 'Y', 0 };
    if (bytes.len > 16 and std.mem.eql(u8, bytes[0..8], &xerial)) {
        var out: List = .empty;
        var at: usize = 16; // magic, version, minimum compatible version
        while (at + 4 <= bytes.len) {
            const size = std.mem.readInt(u32, bytes[at..][0..4], .big);
            at += 4;
            if (at + size > bytes.len) {
                return error.Malformed;
            }
            const piece = try snappyBlock(arena, bytes[at .. at + size]);
            if (out.items.len + piece.len > MAX_UNPACKED) {
                return error.Malformed;
            }
            try out.appendSlice(arena, piece);
            at += size;
        }
        return out.items;
    }
    return snappyBlock(arena, bytes);
}

fn snappyBlock(arena: std.mem.Allocator, bytes: []const u8) CompressError![]const u8 {
    var at: usize = 0;
    // The uncompressed length, as a plain varint - not zig-zagged.
    var length: usize = 0;
    var shift: u6 = 0;
    while (true) {
        if (at >= bytes.len) {
            return error.Malformed;
        }
        const byte = bytes[at];
        at += 1;
        length |= @as(usize, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) {
            break;
        }
        if (shift >= 28) {
            return error.Malformed;
        }
        shift += 7;
    }
    if (length > MAX_UNPACKED) {
        return error.Malformed;
    }
    var out = try std.ArrayListUnmanaged(u8).initCapacity(arena, length);
    while (at < bytes.len) {
        const tag = bytes[at];
        at += 1;
        switch (tag & 0x3) {
            0 => {
                // A literal: its length is in the tag, or in the bytes after it.
                var count: usize = (tag >> 2) + 1;
                if (tag >> 2 >= 60) {
                    const extra: usize = (tag >> 2) - 59;
                    if (at + extra > bytes.len) {
                        return error.Malformed;
                    }
                    count = 0;
                    for (0..extra) |i| {
                        count |= @as(usize, bytes[at + i]) << @intCast(8 * i);
                    }
                    count += 1;
                    at += extra;
                }
                if (at + count > bytes.len) {
                    return error.Malformed;
                }
                if (out.items.len + count > MAX_UNPACKED) {
                    return error.Malformed;
                }
                try out.appendSlice(arena, bytes[at .. at + count]);
                at += count;
            },
            1, 2, 3 => {
                var count: usize = 0;
                var distance: usize = 0;
                switch (tag & 0x3) {
                    1 => {
                        if (at + 1 > bytes.len) {
                            return error.Malformed;
                        }
                        count = 4 + ((tag >> 2) & 0x7);
                        distance = (@as(usize, (tag >> 5) & 0x7) << 8) | bytes[at];
                        at += 1;
                    },
                    2 => {
                        if (at + 2 > bytes.len) {
                            return error.Malformed;
                        }
                        count = (tag >> 2) + 1;
                        distance = std.mem.readInt(u16, bytes[at..][0..2], .little);
                        at += 2;
                    },
                    else => {
                        if (at + 4 > bytes.len) {
                            return error.Malformed;
                        }
                        count = (tag >> 2) + 1;
                        distance = std.mem.readInt(u32, bytes[at..][0..4], .little);
                        at += 4;
                    },
                }
                if (distance == 0 or distance > out.items.len) {
                    return error.Malformed;
                }
                if (out.items.len + count > MAX_UNPACKED) {
                    return error.Malformed;
                }
                // Byte by byte on purpose: a copy may overlap itself, which is how a
                // run of the same bytes is encoded.
                var left = count;
                while (left > 0) : (left -= 1) {
                    try out.append(arena, out.items[out.items.len - distance]);
                }
            },
            else => unreachable,
        }
    }
    return out.items;
}

/// LZ4, in the frame format Kafka uses. Only the parts a broker's payload can
/// contain: no dictionaries, no legacy frames.
pub fn unlz4(arena: std.mem.Allocator, bytes: []const u8) CompressError![]const u8 {
    if (bytes.len < 7 or std.mem.readInt(u32, bytes[0..4], .little) != 0x184D2204) {
        return error.Malformed;
    }
    const flags = bytes[4];
    // Block independence is not read: dependent blocks may copy from the block
    // before them, and since every block is appended to one buffer here and a copy
    // looks that far back regardless, both kinds come out the same.
    const has_content_size = (flags & 0x08) != 0;
    const has_dictionary = (flags & 0x01) != 0;
    if (has_dictionary) {
        return error.Unsupported;
    }
    // magic(4) FLG(1) BD(1) [content size(8)] HC(1), and no dictionary id because
    // a dictionary was refused above.
    var at: usize = 4 + 1 + 1;
    if (has_content_size) {
        at += 8;
    }
    at += 1; // the header checksum, which the broker has already honoured
    var out: List = .empty;
    while (at + 4 <= bytes.len) {
        const word = std.mem.readInt(u32, bytes[at..][0..4], .little);
        at += 4;
        if (word == 0) {
            break; // the end mark
        }
        const stored = (word & 0x80000000) != 0;
        const size: usize = word & 0x7fffffff;
        if (at + size > bytes.len) {
            return error.Malformed;
        }
        const block = bytes[at .. at + size];
        at += size;
        if (out.items.len + size > MAX_UNPACKED) {
            return error.Malformed;
        }
        if (stored) {
            try out.appendSlice(arena, block);
        } else {
            try lz4Block(arena, block, &out);
        }
        if ((flags & 0x10) != 0) {
            at += 4; // a checksum per block
        }
    }
    return out.items;
}

fn lz4Block(arena: std.mem.Allocator, block: []const u8, out: *List) CompressError!void {
    var at: usize = 0;
    while (at < block.len) {
        const token = block[at];
        at += 1;
        var literals: usize = token >> 4;
        if (literals == 15) {
            while (at < block.len) {
                const byte = block[at];
                at += 1;
                literals += byte;
                if (byte != 255) {
                    break;
                }
            }
        }
        if (at + literals > block.len) {
            return error.Malformed;
        }
        if (out.items.len + literals > MAX_UNPACKED) {
            return error.Malformed;
        }
        try out.appendSlice(arena, block[at .. at + literals]);
        at += literals;
        if (at >= block.len) {
            return; // the last sequence has no match
        }
        if (at + 2 > block.len) {
            return error.Malformed;
        }
        const distance: usize = std.mem.readInt(u16, block[at..][0..2], .little);
        at += 2;
        var length: usize = token & 0xf;
        if (length == 15) {
            while (at < block.len) {
                const byte = block[at];
                at += 1;
                length += byte;
                if (byte != 255) {
                    break;
                }
            }
        }
        length += 4; // the minimum match
        if (distance == 0 or distance > out.items.len or out.items.len + length > MAX_UNPACKED) {
            return error.Malformed;
        }
        var left = length;
        while (left > 0) : (left -= 1) {
            try out.append(arena, out.items[out.items.len - distance]);
        }
    }
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "snappy: a literal, and a copy that overlaps itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Length 3, then one literal element of three bytes.
    try testing.expectEqualStrings("abc", try unsnap(a, &[_]u8{ 0x03, 0x08, 'a', 'b', 'c' }));
    // Length 9: the same literal, then six bytes copied from three back - which
    // runs into what it is writing, and that is how a repeat is spelled.
    try testing.expectEqualStrings("abcabcabc", try unsnap(a, &[_]u8{
        0x09, 0x08, 'a', 'b', 'c', 0x09, 0x03,
    }));
}

test "lz4: a stored block and a compressed one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stored = [_]u8{
        0x04, 0x22, 0x4d, 0x18, // magic
        0x40, 0x70, 0x00, // flags, block descriptor, header checksum
        0x03, 0x00, 0x00, 0x80, // one stored block of three bytes
        'a',  'b',  'c',
        0x00, 0x00, 0x00, 0x00, // the end mark
    };
    try testing.expectEqualStrings("abc", try unlz4(a, &stored));

    const packed_block = [_]u8{ 0x32, 'a', 'b', 'c', 0x03, 0x00 };
    var frame: List = .empty;
    try frame.appendSlice(a, &[_]u8{ 0x04, 0x22, 0x4d, 0x18, 0x40, 0x70, 0x00 });
    try frame.appendSlice(a, &[_]u8{ @intCast(packed_block.len), 0x00, 0x00, 0x00 });
    try frame.appendSlice(a, &packed_block);
    try frame.appendSlice(a, &[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    try testing.expectEqualStrings("abcabcabc", try unlz4(a, frame.items));
}

test "gzip comes out of the standard library, and is checked here anyway" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // "abc" as gzip, from gzip -9n, so this is a real member and not a fixture of
    // this program's own making.
    const packed_bytes = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03,
        0x4b, 0x4c, 0x4a, 0x06, 0x00, 0xc2, 0x41, 0x24, 0x35, 0x03,
        0x00, 0x00, 0x00,
    };
    try testing.expectEqualStrings("abc", try decompress(arena.allocator(), .gzip, &packed_bytes));
}

test "a codec krtek does not know says so rather than returning rubbish" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const made_up: Codec = @enumFromInt(6);
    try testing.expectError(error.Unsupported, decompress(arena.allocator(), made_up, "anything"));
    // And no compression is the bytes themselves.
    try testing.expectEqualStrings("plain", try decompress(arena.allocator(), .none, "plain"));
}
