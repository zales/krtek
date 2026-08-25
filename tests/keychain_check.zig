//! Check that the macOS keychain answers on this machine, without the interface.
//!
//!     zig build kccheck
//!
//! Not a unit test on purpose. The keychain belongs to the person at the keyboard:
//! an item remembers which binary created it, so reading one back from a *different*
//! binary - which every rebuild is - makes macOS put up its own dialog. A test
//! suite that could hang on a dialog is worse than no test, so this is a thing to
//! run by hand when the keychain code changes.

const std = @import("std");
const keychain = @import("keychain");

const ACCOUNT = "krtek-selftest://demo";

pub fn main(init: std.process.Init) !void {
    _ = init;
    if (!keychain.available) {
        std.debug.print("no keychain on this platform\n", .{});
        return;
    }
    const a = std.heap.c_allocator;

    try keychain.store(ACCOUNT, "hunter2");
    std.debug.print("stored\n", .{});

    if (try keychain.fetch(a, ACCOUNT)) |got| {
        defer a.free(got);
        std.debug.print("read back: {s}\n", .{got});
        if (!std.mem.eql(u8, got, "hunter2")) {
            std.debug.print("  ...which is not what was stored\n", .{});
        }
    } else {
        std.debug.print("could not read it back - denied, or not there\n", .{});
    }

    // Storing again has to update rather than add a second item.
    try keychain.store(ACCOUNT, "changed");
    if (try keychain.fetch(a, ACCOUNT)) |got| {
        defer a.free(got);
        std.debug.print("after update: {s}\n", .{got});
    }

    keychain.remove(ACCOUNT);
    std.debug.print("after remove: {?s}\n", .{try keychain.fetch(a, ACCOUNT)});
}
