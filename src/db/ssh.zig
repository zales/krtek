//! The little of libssh2 the SFTP driver needs, declared rather than included -
//! as with OpenSSL and SQLite elsewhere in this program.
//!
//! **This one is a library on purpose.** Every other protocol here is written
//! out: Redis, Kafka, the HTTP client, two request signatures. SSH is where that
//! stops. A mistake in Kafka's framing is a wrong row on a screen; a mistake in a
//! key exchange is a vulnerability, and nobody is well served by a hand-rolled
//! one. libssh2 is small, BSD licensed, and links against the OpenSSL that is
//! already in the binary.
//!
//! The session is left in **blocking** mode with a timeout on it. Non-blocking
//! would let `ctrl+c` interrupt a transfer, at the cost of every call in the
//! driver growing an EAGAIN retry loop - so instead nothing hangs forever and a
//! transfer cannot be given up on halfway. That is a limitation, and it is
//! written down rather than hidden.

const std = @import("std");
const db = @import("db.zig");
const net = @import("net.zig");

const List = db.List;

pub const Session = opaque {};
pub const Sftp = opaque {};
pub const Handle = opaque {};
pub const KnownHosts = opaque {};
pub const Agent = opaque {};

/// How long any one call may take before it is a failure rather than a wait.
pub const TIMEOUT_MS: c_long = 30_000;

pub const ERROR_NONE: c_int = 0;
pub const ERROR_EAGAIN: c_int = -37;
pub const ERROR_AUTHENTICATION_FAILED: c_int = -18;
pub const ERROR_FILE: c_int = -16;
pub const ERROR_SFTP_PROTOCOL: c_int = -31;

/// What `libssh2_sftp_last_error` says, for the handful worth a sentence.
pub const FX_OK: c_ulong = 0;
pub const FX_EOF: c_ulong = 1;
pub const FX_NO_SUCH_FILE: c_ulong = 2;
pub const FX_PERMISSION_DENIED: c_ulong = 3;
pub const FX_FAILURE: c_ulong = 4;
pub const FX_NO_SUCH_PATH: c_ulong = 8;
pub const FX_FILE_ALREADY_EXISTS: c_ulong = 11;
pub const FX_DIR_NOT_EMPTY: c_ulong = 18;

/// Flags for `libssh2_sftp_open_ex`.
pub const FXF_READ: c_ulong = 0x00000001;
pub const FXF_WRITE: c_ulong = 0x00000002;
pub const FXF_CREAT: c_ulong = 0x00000008;
pub const FXF_TRUNC: c_ulong = 0x00000010;

pub const OPENFILE: c_int = 0;
pub const OPENDIR: c_int = 1;

/// Which of `stat`, `lstat` and `setstat` a call to `libssh2_sftp_stat_ex` is.
pub const STAT: c_int = 0;
pub const LSTAT: c_int = 1;
pub const SETSTAT: c_int = 2;

/// What `libssh2_sftp_symlink_ex` is being asked for. Reading a link and
/// resolving a path are next to each other in the header and doing the wrong one
/// leaves `..` in every path, quietly.
pub const SYMLINK: c_int = 0;
pub const READLINK: c_int = 1;
pub const REALPATH: c_int = 2;

pub const ATTR_SIZE: c_ulong = 0x00000001;
pub const ATTR_UIDGID: c_ulong = 0x00000002;
pub const ATTR_PERMISSIONS: c_ulong = 0x00000004;
pub const ATTR_ACMODTIME: c_ulong = 0x00000008;

/// The file type, out of the permission bits - the same numbers stat(2) uses.
pub const S_IFMT: c_ulong = 0o170000;
pub const S_IFDIR: c_ulong = 0o040000;
pub const S_IFREG: c_ulong = 0o100000;
pub const S_IFLNK: c_ulong = 0o120000;

/// `LIBSSH2_SFTP_ATTRIBUTES`, whose fields are all `unsigned long` but for the
/// size. A layout that did not match would be silent, so the size is asserted.
pub const Attributes = extern struct {
    flags: c_ulong = 0,
    filesize: u64 = 0,
    uid: c_ulong = 0,
    gid: c_ulong = 0,
    permissions: c_ulong = 0,
    atime: c_ulong = 0,
    mtime: c_ulong = 0,

    pub fn isDir(self: Attributes) bool {
        return self.permissions & S_IFMT == S_IFDIR;
    }

    pub fn isLink(self: Attributes) bool {
        return self.permissions & S_IFMT == S_IFLNK;
    }
};

comptime {
    // Seven words on every machine this is built for. If that ever stops being
    // true the driver would read rubbish out of every listing, quietly.
    std.debug.assert(@sizeOf(Attributes) == 7 * 8);
}

pub const KnownHost = extern struct {
    magic: c_uint,
    node: ?*anyopaque,
    name: ?[*:0]u8,
    key: ?[*:0]u8,
    typemask: c_int,
};

pub const AgentKey = extern struct {
    magic: c_uint,
    node: ?*anyopaque,
    blob: ?[*]u8,
    blob_len: usize,
    comment: ?[*:0]u8,
};

/// What `libssh2_knownhost_checkp` answers.
pub const KNOWNHOST_MATCH: c_int = 0;
pub const KNOWNHOST_NOTFOUND: c_int = 1;
pub const KNOWNHOST_MISMATCH: c_int = 2;
pub const KNOWNHOST_FAILURE: c_int = 3;

/// What to tell it about the key it is being given.
pub const KNOWNHOST_TYPE_PLAIN: c_int = 1;
pub const KNOWNHOST_KEYENC_RAW: c_int = 1 << 16;
pub const KNOWNHOST_KEY_SHIFT: c_int = 18;
pub const KNOWNHOST_KEY_UNKNOWN: c_int = 15 << KNOWNHOST_KEY_SHIFT;

/// libssh2 numbers a host key one way when it hands it over and another way when
/// it is asked to look it up: RSA is 1 and then 2, ed25519 is 6 and then 7. The
/// two lists sit in the same header a few hundred lines apart, and using the
/// first where the second belongs makes every known host look like an impostor -
/// which is what it did.
pub fn knownHostKind(hostkey_type: c_int) c_int {
    return switch (hostkey_type) {
        1...6 => (hostkey_type + 1) << KNOWNHOST_KEY_SHIFT,
        else => KNOWNHOST_KEY_UNKNOWN,
    };
}

pub const HOSTKEY_HASH_SHA256: c_int = 3;

extern fn libssh2_init(flags: c_int) c_int;
extern fn libssh2_exit() void;
extern fn libssh2_session_init_ex(
    alloc: ?*anyopaque,
    free: ?*anyopaque,
    realloc: ?*anyopaque,
    abstract: ?*anyopaque,
) ?*Session;
extern fn libssh2_session_handshake(session: *Session, socket: std.c.fd_t) c_int;
extern fn libssh2_session_set_timeout(session: *Session, timeout: c_long) void;
extern fn libssh2_session_set_blocking(session: *Session, blocking: c_int) void;
extern fn libssh2_session_disconnect_ex(session: *Session, reason: c_int, description: [*:0]const u8, lang: [*:0]const u8) c_int;
extern fn libssh2_session_free(session: *Session) c_int;
extern fn libssh2_session_last_errno(session: *Session) c_int;
extern fn libssh2_session_last_error(session: *Session, message: *?[*:0]u8, length: ?*c_int, want_buffer: c_int) c_int;
extern fn libssh2_session_banner_get(session: *Session) ?[*:0]const u8;
extern fn libssh2_session_hostkey(session: *Session, length: *usize, kind: *c_int) ?[*]const u8;
extern fn libssh2_hostkey_hash(session: *Session, hash_type: c_int) ?[*]const u8;

extern fn libssh2_knownhost_init(session: *Session) ?*KnownHosts;
extern fn libssh2_knownhost_readfile(hosts: *KnownHosts, filename: [*:0]const u8, kind: c_int) c_int;
extern fn libssh2_knownhost_checkp(
    hosts: *KnownHosts,
    host: [*:0]const u8,
    port: c_int,
    key: [*]const u8,
    key_len: usize,
    typemask: c_int,
    found: ?*?*KnownHost,
) c_int;
extern fn libssh2_knownhost_free(hosts: *KnownHosts) void;

extern fn libssh2_userauth_list(session: *Session, username: [*]const u8, length: c_uint) ?[*:0]u8;
extern fn libssh2_userauth_authenticated(session: *Session) c_int;
extern fn libssh2_userauth_password_ex(
    session: *Session,
    username: [*]const u8,
    username_len: c_uint,
    password: [*]const u8,
    password_len: c_uint,
    changer: ?*anyopaque,
) c_int;
extern fn libssh2_userauth_publickey_fromfile_ex(
    session: *Session,
    username: [*]const u8,
    username_len: c_uint,
    public_key: ?[*:0]const u8,
    private_key: [*:0]const u8,
    passphrase: ?[*:0]const u8,
) c_int;

extern fn libssh2_agent_init(session: *Session) ?*Agent;
extern fn libssh2_agent_connect(agent: *Agent) c_int;
extern fn libssh2_agent_list_identities(agent: *Agent) c_int;
extern fn libssh2_agent_get_identity(agent: *Agent, store: *?*AgentKey, previous: ?*AgentKey) c_int;
extern fn libssh2_agent_userauth(agent: *Agent, username: [*:0]const u8, identity: *AgentKey) c_int;
extern fn libssh2_agent_disconnect(agent: *Agent) c_int;
extern fn libssh2_agent_free(agent: *Agent) void;

extern fn libssh2_sftp_init(session: *Session) ?*Sftp;
extern fn libssh2_sftp_shutdown(sftp: *Sftp) c_int;
extern fn libssh2_sftp_last_error(sftp: *Sftp) c_ulong;
extern fn libssh2_sftp_open_ex(
    sftp: *Sftp,
    filename: [*]const u8,
    filename_len: c_uint,
    flags: c_ulong,
    mode: c_long,
    open_type: c_int,
) ?*Handle;
extern fn libssh2_sftp_close_handle(handle: *Handle) c_int;
extern fn libssh2_sftp_read(handle: *Handle, buffer: [*]u8, length: usize) isize;
extern fn libssh2_sftp_write(handle: *Handle, buffer: [*]const u8, length: usize) isize;
extern fn libssh2_sftp_readdir_ex(
    handle: *Handle,
    buffer: [*]u8,
    buffer_len: usize,
    long_entry: ?[*]u8,
    long_entry_len: usize,
    attributes: *Attributes,
) c_int;
extern fn libssh2_sftp_stat_ex(
    sftp: *Sftp,
    path: [*]const u8,
    path_len: c_uint,
    stat_type: c_int,
    attributes: *Attributes,
) c_int;
extern fn libssh2_sftp_rename_ex(
    sftp: *Sftp,
    source: [*]const u8,
    source_len: c_uint,
    destination: [*]const u8,
    destination_len: c_uint,
    flags: c_long,
) c_int;
extern fn libssh2_sftp_unlink_ex(sftp: *Sftp, filename: [*]const u8, filename_len: c_uint) c_int;
extern fn libssh2_sftp_mkdir_ex(sftp: *Sftp, path: [*]const u8, path_len: c_uint, mode: c_long) c_int;
extern fn libssh2_sftp_rmdir_ex(sftp: *Sftp, path: [*]const u8, path_len: c_uint) c_int;
extern fn libssh2_sftp_symlink_ex(
    sftp: *Sftp,
    path: [*]const u8,
    path_len: c_uint,
    target: [*]u8,
    target_len: c_uint,
    link_type: c_int,
) c_int;

pub const version = struct {
    extern fn libssh2_version(required: c_int) ?[*:0]const u8;

    pub fn text() []const u8 {
        const value = libssh2_version(0) orelse return "?";
        return std.mem.sliceTo(value, 0);
    }
};

// -------------------------------------------------------------- the session

pub const Error = error{
    Refused,
    Handshake,
    HostKey,
    Auth,
    /// The server takes a password and none was given. Its own error, and not a
    /// sentence with the word in it, because "you gave me none" and "the one you
    /// gave me is wrong" read alike and mean opposite things to whoever is asked
    /// to type one.
    NeedPassword,
    Sftp,
    OutOfMemory,
};

/// Where the driver keeps everything libssh2 hands it. One connection, one
/// session, one SFTP channel: SFTP is a subsystem of SSH and there is no reason
/// to open a second of either.
pub const Connection = struct {
    stream: net.Stream,
    session: *Session,
    sftp: *Sftp,
    /// The last thing that went wrong, in words, from libssh2 or from here.
    trouble: List = .empty,
    allocator: std.mem.Allocator,

    pub fn close(self: *Connection) void {
        _ = libssh2_sftp_shutdown(self.sftp);
        _ = libssh2_session_disconnect_ex(self.session, 11, "krtek is done", "");
        _ = libssh2_session_free(self.session);
        self.stream.close();
        self.trouble.deinit(self.allocator);
    }

    pub fn message(self: *Connection) []const u8 {
        return self.trouble.items;
    }
};

pub fn hostKeyFingerprint(arena: std.mem.Allocator, session: *Session) ![]const u8 {
    const hash = libssh2_hostkey_hash(session, HOSTKEY_HASH_SHA256) orelse return "";
    const encoder = std.base64.standard_no_pad.Encoder;
    const room = try arena.alloc(u8, encoder.calcSize(32));
    return std.fmt.allocPrint(arena, "SHA256:{s}", .{encoder.encode(room, hash[0..32])});
}

/// What libssh2 last complained about, which is worth far more than the number.
pub fn lastError(session: *Session) []const u8 {
    var text: ?[*:0]u8 = null;
    _ = libssh2_session_last_error(session, &text, null, 0);
    const value = text orelse return "";
    return std.mem.sliceTo(value, 0);
}

// ------------------------------------------------------------- connecting

pub const Options = struct {
    host: []const u8,
    port: u16 = 22,
    user: []const u8,
    password: []const u8 = "",
    /// A private key file, or empty for the usual ones.
    key: []const u8 = "",
    passphrase: []const u8 = "",
    /// Whether the host key has to be in known_hosts.
    verify: bool = true,
};

/// The keys ssh itself tries, in the order it tries them.
const DEFAULT_KEYS = [_][]const u8{ "id_ed25519", "id_ecdsa", "id_rsa" };

pub fn connect(allocator: std.mem.Allocator, options: Options, why: *List) Error!*Connection {
    // Idempotent, and libssh2 wants it before anything else touches OpenSSL.
    if (libssh2_init(0) != 0) {
        try why.appendSlice(allocator, "libssh2 would not start");
        return error.Handshake;
    }
    var stream = net.connect(allocator, options.host, options.port) catch |err| {
        try why.print(allocator, "cannot reach {s}:{d}{s}", .{
            options.host,
            options.port,
            switch (err) {
                error.NoSuchHost => " - no such host",
                error.Refused => " - the connection was refused",
                else => "",
            },
        });
        return error.Refused;
    };
    errdefer stream.close();

    const session = libssh2_session_init_ex(null, null, null, null) orelse {
        try why.appendSlice(allocator, "out of memory");
        return error.Handshake;
    };
    errdefer _ = libssh2_session_free(session);
    libssh2_session_set_timeout(session, TIMEOUT_MS);

    if (libssh2_session_handshake(session, stream.fd) != 0) {
        const said = lastError(session);
        // "Failed getting banner" is the far end taking the connection and then
        // saying nothing at all, which reads as a broken program and is usually
        // one of two ordinary things. The second is worth naming: OpenSSH 9.8 and
        // later shut a source out for several seconds after a failed password, and
        // drop what comes next before the banner - so the attempt right after a
        // mistyped one fails in a way that has nothing to do with the password.
        if (std.mem.indexOf(u8, said, "banner") != null) {
            try why.print(allocator, "the server took the connection and said nothing: either it does not speak SSH, or it is shutting this address out for a moment after a refused password", .{});
        } else {
            try why.print(allocator, "the SSH handshake failed: {s}", .{said});
        }
        return error.Handshake;
    }
    try checkHost(allocator, session, options, why);
    try authenticate(allocator, session, options, why);

    const sftp = libssh2_sftp_init(session) orelse {
        // A server that takes an ssh login and refuses sftp is a server with the
        // subsystem turned off, which is worth saying in those words.
        try why.print(allocator, "the server would not open sftp: {s}", .{lastError(session)});
        return error.Sftp;
    };

    const self = allocator.create(Connection) catch return error.OutOfMemory;
    self.* = .{
        .stream = stream,
        .session = session,
        .sftp = sftp,
        .allocator = allocator,
    };
    return self;
}

/// The host key against `~/.ssh/known_hosts`, which is the whole of what stops
/// somebody else answering in the server's place. A host nobody has met is
/// refused with its fingerprint rather than trusted quietly.
fn checkHost(allocator: std.mem.Allocator, session: *Session, options: Options, why: *List) Error!void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    if (!options.verify) {
        return;
    }
    var length: usize = 0;
    var kind: c_int = 0;
    const key = libssh2_session_hostkey(session, &length, &kind) orelse {
        try why.appendSlice(allocator, "the server offered no host key");
        return error.HostKey;
    };
    const fingerprint = hostKeyFingerprint(arena, session) catch "";

    const home = std.c.getenv("HOME") orelse {
        try why.appendSlice(allocator, "no HOME, so no known_hosts to check the server against - insecure=1 skips the check");
        return error.HostKey;
    };
    const path = std.fmt.allocPrintSentinel(arena, "{s}/.ssh/known_hosts", .{std.mem.sliceTo(home, 0)}, 0) catch return error.OutOfMemory;

    const hosts = libssh2_knownhost_init(session) orelse return error.OutOfMemory;
    defer libssh2_knownhost_free(hosts);
    // A missing file is not an error here: it means nothing is known yet, and the
    // check below says so in better words than a read failure would.
    _ = libssh2_knownhost_readfile(hosts, path.ptr, 1);

    const zero_host = arena.dupeZ(u8, options.host) catch return error.OutOfMemory;
    const typemask = KNOWNHOST_TYPE_PLAIN | KNOWNHOST_KEYENC_RAW | knownHostKind(kind);
    switch (libssh2_knownhost_checkp(hosts, zero_host.ptr, @intCast(options.port), key, length, typemask, null)) {
        KNOWNHOST_MATCH => return,
        KNOWNHOST_MISMATCH => {
            try why.print(allocator, "the host key of {s} is not the one in ~/.ssh/known_hosts ({s}) - somebody else may be answering", .{
                options.host,
                fingerprint,
            });
            return error.HostKey;
        },
        else => {
            try why.print(allocator, "{s} is not in ~/.ssh/known_hosts ({s}) - add it with ssh-keyscan, or say insecure=1", .{
                options.host,
                fingerprint,
            });
            return error.HostKey;
        },
    }
}

fn authenticate(allocator: std.mem.Allocator, session: *Session, options: Options, why: *List) Error!void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    // Asking what the server takes is also what starts the authentication, so it
    // happens whether or not the answer is read.
    const offered = libssh2_userauth_list(session, options.user.ptr, @intCast(options.user.len));
    const methods = if (offered) |list| std.mem.sliceTo(list, 0) else "";
    // Some servers answer "none" by letting the login through there and then.
    if (libssh2_userauth_authenticated(session) != 0) {
        return;
    }

    if (options.password.len != 0) {
        if (libssh2_userauth_password_ex(
            session,
            options.user.ptr,
            @intCast(options.user.len),
            options.password.ptr,
            @intCast(options.password.len),
            null,
        ) == 0) {
            return;
        }
        try why.print(allocator, "the password for {s} was not accepted", .{options.user});
        return error.Auth;
    }

    if (byAgent(session, arena, options.user)) {
        return;
    }
    if (byKey(session, arena, options)) {
        return;
    }
    // Nothing worked and the server takes a password. Its own error rather than a
    // sentence to be recognised later: the interface offers one because this says
    // so, not because the words happened to contain "password".
    if (std.mem.indexOf(u8, methods, "password") != null or
        std.mem.indexOf(u8, methods, "keyboard-interactive") != null)
    {
        try why.print(allocator, "{s} needs a password, or a key the agent does not have", .{options.user});
        return error.NeedPassword;
    } else {
        try why.print(allocator, "no key was accepted for {s} - the server takes {s}", .{
            options.user,
            if (methods.len != 0) methods else "nothing this program can do",
        });
    }
    return error.Auth;
}

/// Whatever the agent is holding, which is what makes this work the way ssh does
/// for somebody who has already unlocked their key today.
fn byAgent(session: *Session, arena: std.mem.Allocator, user: []const u8) bool {
    const agent = libssh2_agent_init(session) orelse return false;
    defer libssh2_agent_free(agent);
    if (libssh2_agent_connect(agent) != 0) {
        return false;
    }
    defer _ = libssh2_agent_disconnect(agent);
    if (libssh2_agent_list_identities(agent) != 0) {
        return false;
    }
    const zero_user = arena.dupeZ(u8, user) catch return false;
    var identity: ?*AgentKey = null;
    while (true) {
        const previous = identity;
        if (libssh2_agent_get_identity(agent, &identity, previous) != 0) {
            return false;
        }
        const key = identity orelse return false;
        if (libssh2_agent_userauth(agent, zero_user.ptr, key) == 0) {
            return true;
        }
    }
}

fn byKey(session: *Session, arena: std.mem.Allocator, options: Options) bool {
    const zero_user = arena.dupeZ(u8, options.user) catch return false;
    const passphrase = if (options.passphrase.len != 0)
        (arena.dupeZ(u8, options.passphrase) catch return false).ptr
    else
        null;

    if (options.key.len != 0) {
        const private = arena.dupeZ(u8, options.key) catch return false;
        return libssh2_userauth_publickey_fromfile_ex(
            session,
            zero_user.ptr,
            @intCast(options.user.len),
            publicBeside(arena, options.key),
            private.ptr,
            passphrase,
        ) == 0;
    }

    const home = std.c.getenv("HOME") orelse return false;
    for (DEFAULT_KEYS) |name| {
        const private = std.fmt.allocPrintSentinel(arena, "{s}/.ssh/{s}", .{ std.mem.sliceTo(home, 0), name }, 0) catch continue;
        if (libssh2_userauth_publickey_fromfile_ex(
            session,
            zero_user.ptr,
            @intCast(options.user.len),
            publicBeside(arena, private),
            private.ptr,
            passphrase,
        ) == 0) {
            return true;
        }
    }
    return false;
}

/// The path of the public half, if it is on disk. A private key copied on its
/// own is the usual case, and libssh2 can derive the public half from it - but
/// only if it is handed nothing here. Handing it a path that does not exist is
/// simply an error, so the file has to be looked for first.
fn publicBeside(arena: std.mem.Allocator, private: []const u8) ?[*:0]const u8 {
    const public = std.fmt.allocPrintSentinel(arena, "{s}.pub", .{private}, 0) catch return null;
    const file = std.c.fopen(public.ptr, "rb") orelse return null;
    _ = std.c.fclose(file);
    return public.ptr;
}

// ----------------------------------------------------------------- the files

pub const Entry = struct {
    name: []const u8,
    attributes: Attributes,
};

/// Everything in a directory. A listing is read whole because SFTP has no
/// pagination and a directory is not a bucket: the sorting, the counting and the
/// paging are then this program's, and exact.
pub fn readDir(self: *Connection, arena: std.mem.Allocator, path: []const u8, limit: usize) Error![]Entry {
    const handle = libssh2_sftp_open_ex(self.sftp, path.ptr, @intCast(path.len), 0, 0, OPENDIR) orelse {
        try explain(self, "cannot open", path);
        return error.Sftp;
    };
    defer _ = libssh2_sftp_close_handle(handle);

    var out: std.ArrayListUnmanaged(Entry) = .empty;
    var name: [512]u8 = undefined;
    while (out.items.len < limit) {
        var attributes = Attributes{};
        const length = libssh2_sftp_readdir_ex(handle, &name, name.len, null, 0, &attributes);
        if (length == 0) {
            break;
        }
        if (length < 0) {
            try explain(self, "cannot read", path);
            return error.Sftp;
        }
        const found = name[0..@intCast(length)];
        // The two every directory has and nobody wants in a table.
        if (std.mem.eql(u8, found, ".") or std.mem.eql(u8, found, "..")) {
            continue;
        }
        out.append(arena, .{
            .name = arena.dupe(u8, found) catch return error.OutOfMemory,
            .attributes = attributes,
        }) catch return error.OutOfMemory;
    }
    return out.items;
}

pub fn readFile(self: *Connection, arena: std.mem.Allocator, path: []const u8, limit: usize) Error![]const u8 {
    const handle = libssh2_sftp_open_ex(self.sftp, path.ptr, @intCast(path.len), FXF_READ, 0, OPENFILE) orelse {
        try explain(self, "cannot open", path);
        return error.Sftp;
    };
    defer _ = libssh2_sftp_close_handle(handle);

    var out: List = .empty;
    var chunk: [32 * 1024]u8 = undefined;
    while (out.items.len < limit) {
        const got = libssh2_sftp_read(handle, &chunk, chunk.len);
        if (got == 0) {
            break;
        }
        if (got < 0) {
            try explain(self, "cannot read", path);
            return error.Sftp;
        }
        out.appendSlice(arena, chunk[0..@intCast(got)]) catch return error.OutOfMemory;
    }
    return out.items;
}

pub fn writeFile(self: *Connection, path: []const u8, bytes: []const u8) Error!void {
    var file = try openWrite(self, path);
    errdefer file.close();
    try file.write(bytes);
    file.close();
}

/// An open file, read or written a block at a time. `readFile` is the whole of
/// a file in memory, which is right for showing one and wrong for moving one:
/// a copy has to work whatever the file weighs.
pub const File = struct {
    conn: *Connection,
    handle: *Handle,

    pub fn read(self: *File, into: []u8) Error!usize {
        const got = libssh2_sftp_read(self.handle, into.ptr, into.len);
        if (got < 0) {
            try explain(self.conn, "cannot read", "the file");
            return error.Sftp;
        }
        return @intCast(got);
    }

    pub fn write(self: *File, bytes: []const u8) Error!void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const wrote = libssh2_sftp_write(self.handle, bytes[sent..].ptr, bytes.len - sent);
            if (wrote < 0) {
                try explain(self.conn, "cannot write", "the file");
                return error.Sftp;
            }
            sent += @intCast(wrote);
        }
    }

    pub fn close(self: *File) void {
        _ = libssh2_sftp_close_handle(self.handle);
    }

    /// Closing is the last chance the far end has to say that the bytes did not
    /// land - a full disk shows up here and nowhere earlier - so a copy asks.
    pub fn done(self: *File) Error!void {
        if (libssh2_sftp_close_handle(self.handle) != 0) {
            try explain(self.conn, "cannot finish writing", "the file");
            return error.Sftp;
        }
    }
};

pub fn openRead(self: *Connection, path: []const u8) Error!File {
    const handle = libssh2_sftp_open_ex(self.sftp, path.ptr, @intCast(path.len), FXF_READ, 0, OPENFILE) orelse {
        try explain(self, "cannot open", path);
        return error.Sftp;
    };
    return .{ .conn = self, .handle = handle };
}

pub fn openWrite(self: *Connection, path: []const u8) Error!File {
    const handle = libssh2_sftp_open_ex(
        self.sftp,
        path.ptr,
        @intCast(path.len),
        FXF_WRITE | FXF_CREAT | FXF_TRUNC,
        0o644,
        OPENFILE,
    ) orelse {
        try explain(self, "cannot write", path);
        return error.Sftp;
    };
    return .{ .conn = self, .handle = handle };
}

pub fn stat(self: *Connection, path: []const u8) Error!Attributes {
    var attributes = Attributes{};
    if (libssh2_sftp_stat_ex(self.sftp, path.ptr, @intCast(path.len), STAT, &attributes) != 0) {
        try explain(self, "cannot look at", path);
        return error.Sftp;
    }
    return attributes;
}

pub fn chmod(self: *Connection, path: []const u8, permissions: c_ulong) Error!void {
    var attributes = Attributes{ .flags = ATTR_PERMISSIONS, .permissions = permissions };
    if (libssh2_sftp_stat_ex(self.sftp, path.ptr, @intCast(path.len), SETSTAT, &attributes) != 0) {
        try explain(self, "cannot change the mode of", path);
        return error.Sftp;
    }
}

/// A real rename, which is the thing an object store cannot do.
pub fn rename(self: *Connection, from: []const u8, to: []const u8) Error!void {
    if (libssh2_sftp_rename_ex(self.sftp, from.ptr, @intCast(from.len), to.ptr, @intCast(to.len), 0) != 0) {
        try explain(self, "cannot rename", from);
        return error.Sftp;
    }
}

pub fn remove(self: *Connection, path: []const u8, directory: bool) Error!void {
    const failed = if (directory)
        libssh2_sftp_rmdir_ex(self.sftp, path.ptr, @intCast(path.len)) != 0
    else
        libssh2_sftp_unlink_ex(self.sftp, path.ptr, @intCast(path.len)) != 0;
    if (failed) {
        try explain(self, "cannot remove", path);
        return error.Sftp;
    }
}

pub fn makeDir(self: *Connection, path: []const u8, permissions: c_long) Error!void {
    if (libssh2_sftp_mkdir_ex(self.sftp, path.ptr, @intCast(path.len), permissions) != 0) {
        try explain(self, "cannot create", path);
        return error.Sftp;
    }
}

/// What the server calls this path, which is how a connection with no path in it
/// finds out where it starts.
pub fn realpath(self: *Connection, arena: std.mem.Allocator, path: []const u8) Error![]const u8 {
    var target: [1024]u8 = undefined;
    const length = libssh2_sftp_symlink_ex(
        self.sftp,
        path.ptr,
        @intCast(path.len),
        &target,
        target.len,
        REALPATH,
    );
    if (length <= 0) {
        return arena.dupe(u8, path) catch error.OutOfMemory;
    }
    return arena.dupe(u8, target[0..@intCast(length)]) catch error.OutOfMemory;
}

/// The reason in the server's own terms where SFTP gave one, and in libssh2's
/// where it did not. "No such file" beats "error -31" every time.
fn explain(self: *Connection, what: []const u8, path: []const u8) Error!void {
    self.trouble.clearRetainingCapacity();
    const reason = switch (libssh2_sftp_last_error(self.sftp)) {
        FX_NO_SUCH_FILE, FX_NO_SUCH_PATH => "there is nothing there",
        FX_PERMISSION_DENIED => "permission denied",
        FX_FILE_ALREADY_EXISTS => "it is already there",
        FX_DIR_NOT_EMPTY => "the directory is not empty",
        else => lastError(self.session),
    };
    self.trouble.print(self.allocator, "{s} {s}{s}{s}", .{
        what,
        path,
        if (reason.len != 0) ": " else "",
        reason,
    }) catch {};
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "the library is linked and says which one it is" {
    // Not a test of this program so much as of the build: if libssh2 is not
    // linked, nothing below it can be.
    const text = version.text();
    try testing.expect(text.len != 0);
    try testing.expect(!std.mem.eql(u8, text, "?"));
}

test "a host key is numbered one way and looked up another" {
    // The numbers are libssh2's own, from libssh2.h: HOSTKEY_TYPE_RSA is 1 and
    // KNOWNHOST_KEY_SSHRSA is 2<<18, and so on up. Off by one here means every
    // host in known_hosts is reported as the wrong one.
    try testing.expectEqual(@as(c_int, 2 << 18), knownHostKind(1)); // RSA
    try testing.expectEqual(@as(c_int, 3 << 18), knownHostKind(2)); // DSS
    try testing.expectEqual(@as(c_int, 4 << 18), knownHostKind(3)); // ECDSA 256
    try testing.expectEqual(@as(c_int, 5 << 18), knownHostKind(4)); // ECDSA 384
    try testing.expectEqual(@as(c_int, 6 << 18), knownHostKind(5)); // ECDSA 521
    try testing.expectEqual(@as(c_int, 7 << 18), knownHostKind(6)); // ed25519
    // Anything else is "unknown" rather than a type that happens to be next.
    try testing.expectEqual(KNOWNHOST_KEY_UNKNOWN, knownHostKind(0));
    try testing.expectEqual(KNOWNHOST_KEY_UNKNOWN, knownHostKind(99));
}

test "a file type is read out of the permission bits" {
    const dir = Attributes{ .permissions = S_IFDIR | 0o755 };
    const file = Attributes{ .permissions = S_IFREG | 0o644 };
    const link = Attributes{ .permissions = S_IFLNK | 0o777 };
    try testing.expect(dir.isDir());
    try testing.expect(!dir.isLink());
    try testing.expect(!file.isDir());
    try testing.expect(link.isLink());
    // Nothing said is nothing known, and a directory is not the default.
    try testing.expect(!(Attributes{}).isDir());
}
