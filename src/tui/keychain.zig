//! The macOS keychain, for connections that keep a password without putting it in
//! a file.
//!
//! A generic password item under the service `krtek`, with the connection's
//! target as the account - so `mysql://root@127.0.0.1:3307/demo` is one item and
//! renaming the connection does not lose it. The password never touches
//! `~/.config/krtek/connections`; that file only says `keychain`.
//!
//! Security.framework is called directly rather than through `/usr/bin/security`,
//! because the command line tool takes the password as an argument, and an
//! argument is visible to anyone running `ps` for as long as the process lives.
//!
//! **The keychain asks before it hands anything over.** An item remembers which
//! binary created it, and a binary rebuilt from changed source is a different one,
//! so macOS puts up its own dialog - "krtek wants to use your confidential
//! information" - and the answer is the user's, not this program's. Nothing here
//! tries to work around that; `fetch` simply returns null if it is refused, and
//! the app then asks for the password the way it always did.

const std = @import("std");
const builtin = @import("builtin");

/// Only macOS has this; everywhere else the option is not offered.
pub const available = builtin.os.tag == .macos;

const SERVICE = "krtek";

/// `errSecItemNotFound`, which is an answer rather than a refusal.
const ITEM_NOT_FOUND: i32 = -25300;

/// Who the keychain lets read an item.
pub const Guard = enum {
    /// The keychain decides, which means this binary and a dialog for the next
    /// one - an item remembers which binary made it, and a rebuilt binary is a
    /// different binary.
    keychain,
    /// Anything running as this user, with no dialog at all. Not carelessness:
    /// it is the trade the `touchid` option makes on purpose. A fingerprint that
    /// arrives only after a dialog asking for the login password is a fingerprint
    /// replacing nothing, and after a rebuild that is what it was. What is given
    /// up is the keychain's own answer to *which binary*; what is kept, and what
    /// that option is for, is an answer to *is the owner at the keyboard*.
    anyone,
};

/// Put `password` in the keychain for `account`, replacing what was there.
pub fn store(account: []const u8, password: []const u8, guard: Guard) !void {
    if (!available) {
        return error.Unsupported;
    }
    const service_key = try string(SERVICE);
    defer release(service_key);
    const account_key = try string(account);
    defer release(account_key);
    const secret = CFDataCreate(null, password.ptr, @intCast(password.len)) orelse return error.OutOfMemory;
    defer release(secret);

    // Update first: adding a second item for the same account would fail. Not
    // where the guard has to change, though - an update leaves the access alone,
    // so switching a connection between `keychain` and `touchid` would do
    // nothing at all.
    if (guard == .keychain) {
        const query = try dictionary(&.{
            .{ kSecClass, kSecClassGenericPassword },
            .{ kSecAttrService, service_key },
            .{ kSecAttrAccount, account_key },
        });
        defer release(query);
        const changes = try dictionary(&.{.{ kSecValueData, secret }});
        defer release(changes);
        if (SecItemUpdate(query, changes) == 0) {
            return;
        }
    } else {
        remove(account);
    }
    const access = if (guard == .anyone) openToAll() else null;
    defer if (access) |made| release(made);
    const item = if (access) |made| try dictionary(&.{
        .{ kSecClass, kSecClassGenericPassword },
        .{ kSecAttrService, service_key },
        .{ kSecAttrAccount, account_key },
        .{ kSecAttrAccess, made },
        .{ kSecValueData, secret },
    }) else try dictionary(&.{
        .{ kSecClass, kSecClassGenericPassword },
        .{ kSecAttrService, service_key },
        .{ kSecAttrAccount, account_key },
        .{ kSecValueData, secret },
    });
    defer release(item);
    if (SecItemAdd(item, null) != 0) {
        return error.Refused;
    }
}

/// The password for `account`: null where nothing is kept, `error.Refused`
/// where macOS put its own dialog up and was told no. Two answers rather than
/// one, because what follows either is a password prompt and somebody has to
/// know which of the two they are answering. The caller owns what comes back.
pub fn fetch(allocator: std.mem.Allocator, account: []const u8) !?[]u8 {
    if (!available) {
        return null;
    }
    const service_key = try string(SERVICE);
    defer release(service_key);
    const account_key = try string(account);
    defer release(account_key);
    const query = try dictionary(&.{
        .{ kSecClass, kSecClassGenericPassword },
        .{ kSecAttrService, service_key },
        .{ kSecAttrAccount, account_key },
        .{ kSecReturnData, kCFBooleanTrue },
        .{ kSecMatchLimit, kSecMatchLimitOne },
    });
    defer release(query);

    var found: ?*const anyopaque = null;
    const status = SecItemCopyMatching(query, &found);
    if (status == ITEM_NOT_FOUND) {
        return null;
    }
    if (status != 0) {
        return error.Refused;
    }
    const data = found orelse return null;
    defer release(data);
    const bytes = CFDataGetBytePtr(data) orelse return null;
    const length: usize = @intCast(CFDataGetLength(data));
    return try allocator.dupe(u8, bytes[0..length]);
}

/// An access that lets anything read the item without a dialog.
///
/// The keychain's own way of saying so is an ACL whose list of trusted
/// applications is empty - empty meaning *any*, which is the one part of this
/// that has to be read twice. It is the API `security -A` uses: deprecated since
/// the CSSM era and still the only way to say it about an item in the login
/// keychain. Null when any of it fails, and then the item is stored the ordinary
/// way rather than not at all.
fn openToAll() ?CFRef {
    const label = string(SERVICE) catch return null;
    defer release(label);
    var access: ?CFRef = null;
    if (SecAccessCreate(label, null, &access) != 0) {
        return null;
    }
    const made = access orelse return null;
    var acls: ?CFRef = null;
    if (SecAccessCopySelectedACLList(made, DECRYPT, &acls) != 0) {
        release(made);
        return null;
    }
    const list = acls orelse {
        release(made);
        return null;
    };
    defer release(list);
    var i: isize = 0;
    while (i < CFArrayGetCount(list)) : (i += 1) {
        const acl = CFArrayGetValueAtIndex(list, i) orelse continue;
        var apps: ?CFRef = null;
        var description: ?CFRef = null;
        var prompt: Prompt = .{ .version = 0, .flags = 0 };
        if (SecACLCopySimpleContents(acl, &apps, &description, &prompt) != 0) {
            continue;
        }
        if (apps) |had| {
            release(had);
        }
        _ = SecACLSetSimpleContents(acl, null, description orelse label, &prompt);
        if (description) |had| {
            release(had);
        }
    }
    return made;
}

/// Forget the password for `account`. A missing item is not an error.
pub fn remove(account: []const u8) void {
    if (!available) {
        return;
    }
    const service_key = string(SERVICE) catch return;
    defer release(service_key);
    const account_key = string(account) catch return;
    defer release(account_key);
    const query = dictionary(&.{
        .{ kSecClass, kSecClassGenericPassword },
        .{ kSecAttrService, service_key },
        .{ kSecAttrAccount, account_key },
    }) catch return;
    defer release(query);
    _ = SecItemDelete(query);
}

// ------------------------------------------------- Core Foundation, minimally

const CFRef = *const anyopaque;

fn string(text: []const u8) !CFRef {
    return CFStringCreateWithBytes(null, text.ptr, @intCast(text.len), kCFStringEncodingUTF8, 0) orelse
        error.OutOfMemory;
}

/// A CFDictionary out of key/value pairs, which is how every Security call takes
/// its arguments.
fn dictionary(pairs: []const [2]CFRef) !CFRef {
    var keys: [8]CFRef = undefined;
    var values: [8]CFRef = undefined;
    if (pairs.len > keys.len) {
        return error.TooMany;
    }
    for (pairs, 0..) |pair, i| {
        keys[i] = pair[0];
        values[i] = pair[1];
    }
    return CFDictionaryCreate(
        null,
        &keys,
        &values,
        @intCast(pairs.len),
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks,
    ) orelse error.OutOfMemory;
}

fn release(ref: CFRef) void {
    CFRelease(ref);
}

const kCFStringEncodingUTF8: u32 = 0x08000100;

extern "c" fn CFStringCreateWithBytes(
    allocator: ?CFRef,
    bytes: [*]const u8,
    length: isize,
    encoding: u32,
    external: u8,
) ?CFRef;
extern "c" fn CFDataCreate(allocator: ?CFRef, bytes: [*]const u8, length: isize) ?CFRef;
extern "c" fn CFDataGetBytePtr(data: CFRef) ?[*]const u8;
extern "c" fn CFDataGetLength(data: CFRef) isize;
extern "c" fn CFDictionaryCreate(
    allocator: ?CFRef,
    keys: [*]const CFRef,
    values: [*]const CFRef,
    count: isize,
    key_callbacks: ?*const anyopaque,
    value_callbacks: ?*const anyopaque,
) ?CFRef;
extern "c" fn CFRelease(ref: CFRef) void;

extern "c" const kCFTypeDictionaryKeyCallBacks: anyopaque;
extern "c" const kCFTypeDictionaryValueCallBacks: anyopaque;
extern "c" const kCFBooleanTrue: CFRef;

extern "c" fn SecItemAdd(attributes: CFRef, result: ?*?CFRef) i32;
extern "c" fn SecItemCopyMatching(query: CFRef, result: *?*const anyopaque) i32;

/// `CSSM_ACL_AUTHORIZATION_DECRYPT`: reading the secret is what the ACL is about.
const DECRYPT: u32 = 24;

/// `CSSM_ACL_KEYCHAIN_PROMPT_SELECTOR`, which is two sixteen-bit fields.
const Prompt = extern struct { version: u16, flags: u16 };

extern "c" fn SecAccessCreate(descriptor: CFRef, trusted: ?CFRef, access: *?CFRef) i32;
extern "c" fn SecAccessCopySelectedACLList(access: CFRef, action: u32, list: *?CFRef) i32;
extern "c" fn SecACLCopySimpleContents(acl: CFRef, applications: *?CFRef, description: *?CFRef, prompt: *Prompt) i32;
extern "c" fn SecACLSetSimpleContents(acl: CFRef, applications: ?CFRef, description: CFRef, prompt: *const Prompt) i32;
extern "c" fn CFArrayGetCount(array: CFRef) isize;
extern "c" fn CFArrayGetValueAtIndex(array: CFRef, at: isize) ?CFRef;
extern "c" fn SecItemUpdate(query: CFRef, changes: CFRef) i32;
extern "c" fn SecItemDelete(query: CFRef) i32;

extern "c" const kSecClass: CFRef;
extern "c" const kSecClassGenericPassword: CFRef;
extern "c" const kSecAttrService: CFRef;
extern "c" const kSecAttrAccount: CFRef;
extern "c" const kSecValueData: CFRef;
extern "c" const kSecAttrAccess: CFRef;
extern "c" const kSecReturnData: CFRef;
extern "c" const kSecMatchLimit: CFRef;
extern "c" const kSecMatchLimitOne: CFRef;

test "nothing kept is not the same as something refused" {
    if (!available) {
        return error.SkipZigTest;
    }
    // Two answers, not one. Nothing kept is the first time a connection is set to
    // use the keychain, and means "ask for the password". A refusal is macOS
    // putting its own dialog up and being told no, and means saying so - what
    // follows either is a password prompt, and somebody has to know which of the
    // two they are answering.
    try std.testing.expect((try fetch(std.testing.allocator, "krtek-nothing-was-ever-stored-here")) == null);
}
