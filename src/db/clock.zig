//! What time it is, in the two senses a program needs it.
//!
//! Two, because they answer different questions and neither can stand in for the
//! other. A signature and a filename want the wall clock, which is the time
//! everybody else agrees on and which can jump backwards when somebody corrects
//! it. A timeout, and "how long did that query take", want a clock that only ever
//! goes forwards and whose zero means nothing in particular.
//!
//! This is a file because it had become eight near-copies of the same six lines,
//! each carrying the same note that `std.time.Timer` is gone in this Zig.

const std = @import("std");

/// Nanoseconds on a clock that does not go backwards, counted from a zero that
/// means nothing. Only the difference between two readings means anything.
pub fn steadyNanos() i64 {
    var moment: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &moment) != 0) return 0;
    return @as(i64, @intCast(moment.sec)) * 1_000_000_000 + @as(i64, @intCast(moment.nsec));
}

/// The same clock in milliseconds, which is what nearly every caller wants. A
/// float because a query that took a third of a millisecond took a third of a
/// millisecond, and reporting that as zero would be a lie about a fast server.
pub fn steadyMs() f64 {
    return @as(f64, @floatFromInt(steadyNanos())) / 1_000_000.0;
}

/// Milliseconds on the wall clock, the time everybody else agrees on. In
/// milliseconds because a Kafka record carries its timestamp that way, and two
/// records produced in the same second were not produced at the same time.
pub fn wallMs() i64 {
    var moment: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &moment) != 0) return 0;
    return @as(i64, @intCast(moment.sec)) * 1000 + @divFloor(@as(i64, @intCast(moment.nsec)), 1_000_000);
}

/// The same, in whole seconds: what a signature and a filename are stamped with.
pub fn wallSeconds() i64 {
    return @divFloor(wallMs(), 1000);
}

/// Wait, without a thread to wait on. A cluster that has just been told to make
/// a topic needs a moment to elect a leader for it, and asking again at once
/// only gets the same answer.
pub fn sleep(ms: i64) void {
    if (ms <= 0) return;
    const request = std.c.timespec{
        .sec = @intCast(@divFloor(ms, 1000)),
        .nsec = @intCast(@mod(ms, 1000) * 1_000_000),
    };
    var left: std.c.timespec = undefined;
    _ = std.c.nanosleep(&request, &left);
}

// ------------------------------------------------------------------- tests

test "the steady clock goes forwards and the wall clock knows the century" {
    const first = steadyNanos();
    const second = steadyNanos();
    try std.testing.expect(second >= first);

    // Somewhere after 2020 and before 2100. Enough to catch a clock read in the
    // wrong unit, which is the mistake a file of conversions can make.
    const seconds = wallSeconds();
    try std.testing.expect(seconds > 1_577_836_800);
    try std.testing.expect(seconds < 4_102_444_800);
    // And the two agree about which second it is.
    try std.testing.expectEqual(seconds, @divFloor(wallMs(), 1000));

    // A wait waits, and a wait for no time at all comes straight back.
    const before = steadyNanos();
    sleep(20);
    try std.testing.expect(steadyNanos() - before >= 10_000_000);
    sleep(0);
}
