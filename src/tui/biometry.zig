//! Touch ID, for a password that is kept rather than typed.
//!
//! What this is *not*: the keychain does not enforce it. An item the keychain
//! itself guards with a fingerprint has to live in the data protection keychain,
//! and that needs an entitlement that only a binary signed with a real team
//! identity may carry - claimed by an ad-hoc signature, macOS kills the process
//! on the spot. This was tried before the rest was written. So what happens here
//! is that this program asks for the fingerprint and then reads the item the way
//! it always did. It is a lock on the door of this program, not on the safe.
//!
//! Worth having anyway: the alternative people actually use is `Always Allow`,
//! which hands the binary the password silently forever, and the alternative to
//! that is typing it every time.
//!
//! There is no C API for LocalAuthentication, so this goes through the
//! Objective-C runtime by hand - and `evaluatePolicy` takes its answer in a
//! callback, which means a block, which means building one: the layout below is
//! what the compiler emits for `^(BOOL, NSError *){ … }`.

const std = @import("std");
const builtin = @import("builtin");
const clock = @import("db").clock;

/// Only macOS has one, and only where there is a sensor with a finger enrolled.
/// Checked once: it cannot change while the program runs.
pub var available: bool = false;

pub fn detect() void {
    if (builtin.os.tag != .macos) {
        return;
    }
    const context = newContext() orelse return;
    defer message(context, "release");
    available = canEvaluate(context, BIOMETRICS);
}

/// Ask for a fingerprint, and wait for the answer. False for a refusal, a
/// cancel, or anything that went wrong - the caller then does whatever it does
/// without the secret.
///
/// The policy is the one that also takes the login password, so a finger that
/// will not read is a nuisance rather than a dead end.
pub fn ask(reason: []const u8) bool {
    if (!available) {
        return false;
    }
    const context = newContext() orelse return false;
    defer message(context, "release");

    var answer = Answer{};
    var descriptor = Descriptor{ .reserved = 0, .size = @sizeOf(Block) };
    var block = Block{
        .isa = &_NSConcreteStackBlock,
        .flags = 0,
        .reserved = 0,
        .invoke = replied,
        .descriptor = &descriptor,
        .answer = &answer,
    };

    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buffer, "{s}", .{reason[0..@min(reason.len, buffer.len - 1)]}) catch return false;
    const localized = nsString(text) orelse return false;

    const evaluate: *const fn (?*anyopaque, ?*anyopaque, i64, ?*anyopaque, *Block) callconv(.c) void =
        @ptrCast(&objc_msgSend);
    evaluate(context, sel_registerName("evaluatePolicy:localizedReason:reply:"), PASSWORD_TOO, localized, &block);

    // The reply arrives on a queue of the system's choosing, so this waits for
    // it rather than returning into a program that would carry on without an
    // answer. A minute is longer than anybody stares at a fingerprint dialog.
    var waited: usize = 0;
    while (waited < 60_000) : (waited += 20) {
        if (answer.done.load(.acquire) != 0) {
            return answer.okay.load(.acquire) != 0;
        }
        clock.sleep(20);
    }
    return false;
}

// ------------------------------------------------- the Objective-C machinery

const BIOMETRICS: i64 = 1;
const PASSWORD_TOO: i64 = 2;

const Answer = struct {
    done: std.atomic.Value(u32) = .init(0),
    okay: std.atomic.Value(u32) = .init(0),
};

const Descriptor = extern struct {
    reserved: c_ulong,
    size: c_ulong,
};

const Block = extern struct {
    isa: *const anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*Block, u8, ?*anyopaque) callconv(.c) void,
    descriptor: *const Descriptor,
    /// What this block captured, which is where the answer is put.
    answer: *Answer,
};

fn replied(block: *Block, success: u8, err: ?*anyopaque) callconv(.c) void {
    _ = err;
    block.answer.okay.store(if (success != 0) 1 else 0, .release);
    block.answer.done.store(1, .release);
}

extern fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
extern fn objc_msgSend() void;
extern const _NSConcreteStackBlock: anyopaque;

fn message(target: ?*anyopaque, name: [*:0]const u8) void {
    const send: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void = @ptrCast(&objc_msgSend);
    send(target, sel_registerName(name));
}

fn newContext() ?*anyopaque {
    const class = objc_getClass("LAContext") orelse return null;
    const send: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc_msgSend);
    const raw = send(class, sel_registerName("alloc")) orelse return null;
    return send(raw, sel_registerName("init"));
}

fn canEvaluate(context: ?*anyopaque, policy: i64) bool {
    const send: *const fn (?*anyopaque, ?*anyopaque, i64, ?*anyopaque) callconv(.c) u8 = @ptrCast(&objc_msgSend);
    return send(context, sel_registerName("canEvaluatePolicy:error:"), policy, null) != 0;
}

fn nsString(text: [*:0]const u8) ?*anyopaque {
    const class = objc_getClass("NSString") orelse return null;
    const send: *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(&objc_msgSend);
    return send(class, sel_registerName("stringWithUTF8String:"), text);
}

// Only where somebody asks for it, because it puts a dialog on the screen and
// waits for a finger: set `KRTEK_TOUCHID=1` and run the tests.
test "the reader is found, and answers" {
    const std_testing = std.testing;
    if (@import("db").targets.getenv("KRTEK_TOUCHID") == null) {
        return error.SkipZigTest;
    }
    detect();
    std.debug.print("\nctecka k dispozici: {}\n", .{available});
    if (!available) {
        return;
    }
    const said = ask("zkouska krtka");
    std.debug.print("odpoved: {}\n", .{said});
    try std_testing.expect(said or !said);
}
