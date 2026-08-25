//! Throw malformed bytes at the parsers that read from a socket and see whether
//! any of them does something other than return an error.
//!
//!     zig build fuzz                     # a few seconds, from a fixed seed
//!     zig build fuzz -- 1000000          # longer
//!     zig build fuzz -- 1000000 12345    # and from another seed
//!
//! This exists because `zig build test --fuzz` does not compile with Zig 0.16.0:
//! its own test runner passes a `*builtin.StackTrace` where a
//! `*const debug.StackTrace` is wanted. The fuzz targets in `src/db/kafka.zig` are
//! still there and still run over their corpus on every ordinary test run; this is
//! what actually generates input in the meantime.
//!
//! Deterministic on purpose: a crash prints the seed and the iteration, and the
//! same two numbers produce the same bytes again. The input itself is printed as
//! hex before it is parsed, so whatever the last line says is what broke it.
//!
//! What it is looking for is not wrong answers - a fuzzer cannot know a right one -
//! but the three things a parser of untrusted bytes must never do: read outside
//! what it was given, allocate whatever a length field claims, and panic on an
//! overflow.
//!
//! Every iteration is given a fixed budget of memory and nothing else, so a parser
//! that would allocate what its input asked for gets `OutOfMemory` and the machine
//! keeps running. The first version handed out the C allocator, and the snappy
//! unpacker - which reserved whatever length its input claimed - took seventeen
//! gigabytes before anybody noticed.

const std = @import("std");
const db = @import("db");

const Target = enum { snappy, lz4, gzip, zstd, records, resp, http, listing, blobs, management };

/// What one input may allocate: comfortably more than any parser needs for a real
/// batch, and far less than a machine has.
const BUDGET = 96 << 20;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // One input, once: `zig build fuzz -- replay gzip 1f8b08...`, which is how
    // whatever a long run found gets looked at under a debug build.
    if (args.len > 3 and std.mem.eql(u8, args[1], "replay")) {
        const target = std.meta.stringToEnum(Target, args[2]) orelse {
            std.debug.print("no target called {s}\n", .{args[2]});
            return;
        };
        const hex = args[3];
        const bytes = try init.arena.allocator().alloc(u8, hex.len / 2);
        _ = try std.fmt.hexToBytes(bytes, hex);
        std.debug.print("replaying {t} with {d} bytes\n", .{ target, bytes.len });
        run(std.heap.c_allocator, target, bytes) catch |err| {
            std.debug.print("came back with {t}\n", .{err});
            return;
        };
        std.debug.print("came back with a value\n", .{});
        return;
    }
    const iterations = if (args.len > 1) std.fmt.parseInt(usize, args[1], 10) catch 200_000 else 200_000;
    const seed = if (args.len > 2) std.fmt.parseInt(u64, args[2], 10) catch 0 else 0;

    // One block, reused: the budget for an iteration and the ceiling on the damage
    // one input can do.
    const block = try std.heap.page_allocator.alloc(u8, BUDGET);
    defer std.heap.page_allocator.free(block);
    var fixed = std.heap.FixedBufferAllocator.init(block);
    const gpa = fixed.allocator();

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var buffer: [16 * 1024]u8 = undefined;

    std.debug.print("fuzzing {d} iterations from seed {d}\n", .{ iterations, seed });
    var verbose = false;
    if (init.environ_map.get("FUZZ_VERBOSE")) |_| {
        verbose = true;
    }

    var counts = [_]usize{0} ** std.meta.fields(Target).len;
    var survived: usize = 0;
    for (0..iterations) |iteration| {
        const target = random.enumValue(Target);
        const input = shape(random, &buffer, target);
        counts[@intFromEnum(target)] += 1;
        if (verbose) {
            std.debug.print("{d} {t} {x}\n", .{ iteration, target, input });
        }
        // Nothing is asserted about the outcome: an error is a fine answer and so is
        // a value, OutOfMemory included - that is the budget doing its job. The test
        // is that the process is still here afterwards.
        fixed.reset();
        run(gpa, target, input) catch {};
        survived += 1;
    }

    std.debug.print("survived {d} inputs:", .{survived});
    inline for (std.meta.fields(Target), 0..) |field, i| {
        std.debug.print(" {s}={d}", .{ field.name, counts[i] });
    }
    std.debug.print("\n", .{});
}

fn run(gpa: std.mem.Allocator, target: Target, input: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    switch (target) {
        .snappy => _ = try db.kafka.decompress(a, .snappy, input),
        .lz4 => _ = try db.kafka.decompress(a, .lz4, input),
        .gzip => _ = try db.kafka.decompress(a, .gzip, input),
        .zstd => _ = try db.kafka.decompress(a, .zstd, input),
        .records => try db.kafka.fuzzBatches(gpa, input),
        .resp => _ = try db.redis.parseReply(gpa, a, input),
        // The HTTP reader believes a Content-Length and a chunk size, both of which
        // come off the wire; the ceiling is what stops it believing them too far.
        .http => {
            var source = db.http.Slice{ .text = input, .step = 7 };
            _ = try db.http.readResponse(a, source.source(), "GET", 1 << 20);
        },
        .listing => _ = try db.s3.parseListing(a, input),
        .blobs => _ = try db.azure.parseListing(a, input),
        // The JSON is Zig's to parse; what is ours is the walk over it, the base64
        // in a message body and the flattening of whatever shape came back.
        .management => {
            const answer = try db.rabbit.api.page(a, input);
            for (answer.items) |item| {
                _ = try db.rabbit.api.flatten(a, item);
                _ = try db.rabbit.api.payload(a, item);
                _ = db.rabbit.api.pick(item, "channel_details.name");
            }
        },
    }
}

/// One input: either something out of the corpus with a few bytes disturbed, or a
/// run of bytes with no shape at all. The corpus matters - a parser rejects random
/// noise in its first three bytes and never reaches the interesting part - and the
/// mutations are the ones that break length-driven formats: a length made huge, a
/// length made negative, a body cut short.
fn shape(random: std.Random, buffer: []u8, target: Target) []const u8 {
    const corpus = corpusFor(target);
    if (random.uintLessThan(u8, 10) == 0 or corpus.len == 0) {
        const length = random.uintLessThan(usize, @min(buffer.len, 512));
        random.bytes(buffer[0..length]);
        return buffer[0..length];
    }
    const seed_bytes = corpus[random.uintLessThan(usize, corpus.len)];
    const length = @min(seed_bytes.len, buffer.len);
    @memcpy(buffer[0..length], seed_bytes[0..length]);
    var input = buffer[0..length];

    const rounds = 1 + random.uintLessThan(usize, 6);
    for (0..rounds) |_| {
        if (input.len == 0) {
            break;
        }
        switch (random.uintLessThan(u8, 6)) {
            // A single bit, which is how a magic byte or a flag gets it.
            0 => input[random.uintLessThan(usize, input.len)] ^= @as(u8, 1) << random.int(u3),
            1 => input[random.uintLessThan(usize, input.len)] = random.int(u8),
            // A length field made as large as it goes, or negative.
            2 => {
                const at = random.uintLessThan(usize, input.len);
                const run_length = @min(4, input.len - at);
                @memset(input[at .. at + run_length], 0xff);
            },
            3 => {
                const at = random.uintLessThan(usize, input.len);
                const run_length = @min(4, input.len - at);
                @memset(input[at .. at + run_length], 0x7f);
            },
            // Cut it off part way, which is what a fetch that hit its byte limit
            // hands over.
            4 => input = input[0..random.uintLessThan(usize, input.len + 1)],
            // Or make it longer with noise, so a length that was right no longer is.
            5 => {
                const extra = random.uintLessThan(usize, 32);
                const room = @min(buffer.len - input.len, extra);
                random.bytes(buffer[input.len .. input.len + room]);
                input = buffer[0 .. input.len + room];
            },
            else => unreachable,
        }
    }
    return input;
}

fn corpusFor(target: Target) []const []const u8 {
    return switch (target) {
        .snappy => &.{
            &.{ 0x03, 0x08, 'a', 'b', 'c' },
            &.{ 0x09, 0x08, 'a', 'b', 'c', 0x09, 0x03 },
            &.{ 0x82, 'S', 'N', 'A', 'P', 'P', 'Y', 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 5, 0x03, 0x08, 'a', 'b', 'c' },
        },
        .lz4 => &.{
            &.{ 0x04, 0x22, 0x4d, 0x18, 0x40, 0x70, 0x00, 0x03, 0x00, 0x00, 0x80, 'a', 'b', 'c', 0, 0, 0, 0 },
            &.{ 0x04, 0x22, 0x4d, 0x18, 0x40, 0x70, 0x00, 0x06, 0x00, 0x00, 0x00, 0x32, 'a', 'b', 'c', 0x03, 0x00, 0, 0, 0, 0 },
        },
        .gzip => &.{
            &.{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03, 0x4b, 0x4c, 0x4a, 0x06, 0x00, 0xc2, 0x41, 0x24, 0x35, 0x03, 0x00, 0x00, 0x00 },
        },
        .zstd => &.{
            &.{ 0x28, 0xb5, 0x2f, 0xfd, 0x24, 0x03, 0x19, 0x00, 0x00, 'a', 'b', 'c', 0x1b, 0xbf, 0x1a, 0x0e },
        },
        .records => &.{&batch},
        .resp => &.{
            "+OK\r\n",
            "-ERR no\r\n",
            ":42\r\n",
            "$3\r\nabc\r\n",
            "$-1\r\n",
            "*2\r\n$1\r\na\r\n$1\r\nb\r\n",
            "*3\r\n:1\r\n:2\r\n*1\r\n$2\r\nhi\r\n",
            "%2\r\n$1\r\na\r\n:1\r\n$1\r\nb\r\n:2\r\n",
        },
        .http => &.{
            "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n",
            "HTTP/1.1 404 Not Found\r\nx-amz-bucket-region: eu-west-1\r\nContent-Length: 0\r\n\r\n",
            "HTTP/1.1 204 No Content\r\n\r\n",
            "HTTP/1.1 500 Oops\r\n\r\nno length at all",
        },
        .listing => &.{
            "<ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>t</NextContinuationToken>" ++
                "<Contents><Key>a%20b</Key><Size>12</Size><ETag>&quot;x&quot;</ETag><StorageClass>STANDARD</StorageClass></Contents>" ++
                "</ListBucketResult>",
            "<Error><Code>NoSuchBucket</Code><Message>nope</Message></Error>",
            "<ListAllMyBucketsResult><Buckets><Bucket><Name>photos</Name></Bucket></Buckets></ListAllMyBucketsResult>",
        },
        .blobs => &.{
            "<EnumerationResults ContainerName=\"photos\"><Blobs><Blob><Name>a b.txt</Name><Properties>" ++
                "<Last-Modified>Wed, 12 Aug 2026 17:16:36 GMT</Last-Modified><Etag>0x8D</Etag>" ++
                "<Content-Length>9</Content-Length><BlobType>BlockBlob</BlobType><AccessTier>Hot</AccessTier>" ++
                "</Properties></Blob></Blobs><NextMarker>2!76!MDAw</NextMarker></EnumerationResults>",
            "<EnumerationResults><Containers><Container><Name>photos</Name></Container></Containers></EnumerationResults>",
            "<Error><Code>BlobNotFound</Code><Message>nope</Message></Error>",
        },
        .management => &.{
            "{\"items\":[{\"name\":\"orders\",\"messages\":12,\"durable\":true,\"arguments\":{}}]," ++
                "\"filtered_count\":1,\"item_count\":1,\"total_count\":1,\"page\":1}",
            "[{\"payload\":\"AAECAw==\",\"payload_encoding\":\"base64\",\"routing_key\":\"a\",\"properties\":{}}]",
            "[{\"consumer_tag\":\"ctag\",\"queue\":{\"name\":\"q\"},\"channel_details\":{\"name\":\"c\"}}]",
            "{\"error\":\"not_found\",\"reason\":\"Object Not Found\"}",
        },
    };
}

/// One uncompressed record batch holding one record: the shape a fetch answers
/// with, and the thing worth disturbing.
const batch = [_]u8{
    0, 0, 0, 0, 0, 0, 0, 0, // base offset
    0, 0, 0, 59, // length from here on
    0, 0, 0, 0, // partition leader epoch
    2, // magic
    0, 0, 0, 0, // crc
    0, 0, // attributes
    0, 0, 0, 0, // last offset delta
    0, 0, 0, 0, 0, 0, 0, 0, // base timestamp
    0, 0, 0, 0, 0, 0, 0, 0, // max timestamp
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // producer id
    0xff, 0xff, // producer epoch
    0xff, 0xff, 0xff, 0xff, // base sequence
    0,   0,   0,   1, // one record
    14,  0,   0,   0,
    2,   'k', 'v', 4,
    'v', 'a', 'l', 'u',
    0,
};
