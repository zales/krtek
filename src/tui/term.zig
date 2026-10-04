//! The terminal, on top of [libvaxis](https://github.com/rockorager/libvaxis).
//!
//! Vaxis brings what a hand written escape sequence layer did not: true colour,
//! grapheme aware widths, the kitty keyboard protocol, bracketed paste, the
//! mouse and damage tracked rendering. This file keeps the small
//! cursor-and-style surface the drawing code was written against - `moveTo`,
//! `put`, `style`, `clearToEol` - so the views did not have to be rewritten,
//! and translates it into vaxis segments underneath.

const std = @import("std");
const vaxis = @import("vaxis");

pub const Size = struct {
    rows: u16 = 24,
    cols: u16 = 80,
};

pub const Style = struct {
    fg: ?u8 = null,
    bg: ?u8 = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    reverse: bool = false,
    underline: bool = false,
    /// The underline in a colour of its own, where the terminal can do it. A form
    /// field is a quiet line under text that has to stay bright, and the two
    /// cannot be the same colour; a terminal that does not know SGR 58 draws the
    /// line in the text colour, which is still a field somebody can see.
    underline_colour: ?u8 = null,
};

pub const Mouse = struct {
    row: u16,
    col: u16,
    button: enum { left, middle, right, wheel_up, wheel_down, other },
};

pub const Key = union(enum) {
    char: u21,
    ctrl: u8, // the letter, lower case
    alt: u8, // alt/option + key
    enter,
    tab,
    back_tab,
    escape,
    backspace,
    delete,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    mouse: Mouse,
    /// Not a key at all: the follow timer asking for the view to be looked at
    /// again. It arrives through the same queue, so the loop that handles keys
    /// handles this too and nothing else had to learn about time.
    tick,
    unknown,
};

/// The events this app acts on; vaxis reports more.
const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    paste_start,
    paste_end,
    focus_in,
    focus_out,
    /// The terminal switched between a light and a dark theme.
    color_scheme: vaxis.Color.Scheme,
    /// The answer to asking what the background colour is.
    color_report: vaxis.Color.Report,
    /// Posted by the follow timer, which is the only event here the terminal
    /// did not send.
    tick,
};

pub const Scheme = enum { dark, light };

/// True colour for the entries the interface uses, in both schemes; anything
/// else keeps the palette index, so neither mapping has to be complete.
///
/// The drawing code names roles, not colours - `C.accent`, `C.bar` - and those
/// names are palette indexes, so a whole theme is one table here. Index 16 is
/// the odd one out: it is the text drawn *on* an accent background, so it has to
/// go the other way from everything else.
///
/// **Every one of these is text somebody has to read**, so each carries at least
/// 4.5:1 against the background it is drawn on - the point at which grey stops
/// being decoration. `faint` used to be 2.4:1 against the page and 1.7:1 inside a
/// form, which is what the footer hints, the headings of the key map and the
/// explanation under the connection list were written in: the parts that teach
/// the app, in the one colour nobody could read. The ramp is text, dim, faint -
/// roughly 14:1, 7:1, 4.5:1 against the page - and it is a ramp of emphasis now
/// rather than a ramp towards invisible.
fn colour(index: u8, scheme: Scheme) vaxis.Color {
    return switch (scheme) {
        .dark => switch (index) {
            16 => .{ .rgb = .{ 0x11, 0x11, 0x14 } },
            74 => .{ .rgb = .{ 0x63, 0xa8, 0xd8 } }, // numbers
            111 => .{ .rgb = .{ 0x8a, 0xa7, 0xf0 } }, // accent
            114 => .{ .rgb = .{ 0x71, 0xc6, 0x8f } }, // ok
            176 => .{ .rgb = .{ 0xc6, 0x8f, 0xd8 } }, // blobs
            179 => .{ .rgb = .{ 0xd8, 0xa6, 0x63 } }, // warning
            203 => .{ .rgb = .{ 0xe8, 0x6b, 0x72 } }, // danger
            236 => .{ .rgb = .{ 0x26, 0x26, 0x2c } }, // bars
            // The band under the cursor. It stops here rather than going lighter
            // because the name on it is drawn in the accent, and a brighter band
            // makes the one thing it is pointing at harder to read than the rows
            // around it - which is the opposite of the job. What is quiet elsewhere
            // is drawn a step brighter on this, instead.
            238 => .{ .rgb = .{ 0x4c, 0x4c, 0x56 } }, // selection
            240 => .{ .rgb = .{ 0x7c, 0x7c, 0x88 } }, // faint
            242 => .{ .rgb = .{ 0x82, 0x82, 0x8e } }, // null
            245 => .{ .rgb = .{ 0x9a, 0x9a, 0xa6 } }, // dim
            252 => .{ .rgb = .{ 0xe0, 0xe0, 0xe6 } }, // text
            else => .{ .index = index },
        },
        // Darker accents, because they are read against white here.
        .light => switch (index) {
            16 => .{ .rgb = .{ 0xff, 0xff, 0xff } },
            74 => .{ .rgb = .{ 0x1a, 0x5f, 0x94 } }, // numbers
            111 => .{ .rgb = .{ 0x2f, 0x4c, 0xc4 } }, // accent
            114 => .{ .rgb = .{ 0x1b, 0x6e, 0x3c } }, // ok
            176 => .{ .rgb = .{ 0x7d, 0x33, 0x9c } }, // blobs
            179 => .{ .rgb = .{ 0x8a, 0x59, 0x0c } }, // warning
            203 => .{ .rgb = .{ 0xb4, 0x20, 0x28 } }, // danger
            236 => .{ .rgb = .{ 0xe8, 0xe8, 0xef } }, // bars
            238 => .{ .rgb = .{ 0xb0, 0xbc, 0xdc } }, // selection
            240 => .{ .rgb = .{ 0x72, 0x72, 0x80 } }, // faint
            242 => .{ .rgb = .{ 0x75, 0x75, 0x7f } }, // null
            245 => .{ .rgb = .{ 0x5c, 0x5c, 0x66 } }, // dim
            252 => .{ .rgb = .{ 0x1c, 0x1c, 0x24 } }, // text
            else => .{ .index = index },
        },
    };
}

/// Is a background colour dark enough to put light text on? Rec. 601 luma,
/// which is close enough for a yes-or-no answer.
fn isDark(rgb: [3]u8) bool {
    const luma = (@as(u32, rgb[0]) * 299 + @as(u32, rgb[1]) * 587 + @as(u32, rgb[2]) * 114) / 1000;
    return luma < 128;
}

extern "c" fn isatty(fd: std.c.fd_t) c_int;

pub const Term = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    loop: vaxis.Loop(Event),
    buffer: []u8,
    window: vaxis.Window = undefined,
    row: u16 = 0,
    col: u16 = 0,
    current: vaxis.Style = .{},
    /// Vaxis keeps a pointer to the text of every cell until the frame is
    /// rendered, so what is printed has to outlive the call. The drawing code
    /// prints from stack buffers, so the text is copied in here and thrown away
    /// once the frame is on screen.
    frame: std.heap.ArenaAllocator,
    /// Set between the paste markers, so a newline in pasted text stays text
    /// instead of being the Enter that would submit half a statement.
    pasting: bool = false,
    /// Set when the last pasted key was a carriage return, so the line feed that
    /// follows it in CRLF text does not become a second line break.
    paste_after_cr: bool = false,
    /// The start of a character the last read of the terminal ended in the
    /// middle of, until the next read brings the rest of it.
    unfinished: Unfinished = .{},
    /// Which way round the colours go. The terminal is asked, and says so again
    /// whenever the user switches theme; `KRTEK_THEME` overrides both.
    scheme: Scheme = .dark,
    forced_scheme: ?Scheme = null,
    /// The picture currently on screen, and a hash of the bytes it was made
    /// from, so a redraw places it again instead of sending it again.
    picture: ?vaxis.Image = null,
    picture_hash: u64 = 0,
    /// The follow timer, while the grid is watching a table: a task of its own
    /// that sleeps and posts a tick. Null the rest of the time, so an app that is
    /// only being read still blocks on the terminal and wakes for nothing.
    ticker: ?std.Io.Future(void) = null,
    /// How long that task sleeps between ticks. Written only while there is no
    /// task to read it - `follow` stops the old one before it sets this - so the
    /// two never touch it at once.
    tick_ms: u64 = 0,
    /// The terminal during a handover, and -1 the rest of the time: which
    /// descriptor to read what is typed from, which to write to, and which - if
    /// any - was opened here and has to be closed again. See `handle`.
    read_fd: std.c.fd_t = -1,
    write_fd: std.c.fd_t = -1,
    opened_fd: std.c.fd_t = -1,
    /// What arrived while a connection was being opened and all that was being
    /// listened for was esc: kept, in the order it came, and read by `keys`
    /// before anything newer. A connect used to block with the keys queuing up
    /// behind it, so somebody who chose a connection and went straight on typing
    /// had it all happen once the connection was there - and so did every test
    /// that sends its keys without waiting to see the first screen.
    held: std.ArrayList(Event) = .empty,
    held_at: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) !*Term {
        const self = try allocator.create(Term);
        errdefer allocator.destroy(self);
        const buffer = try allocator.alloc(u8, 64 * 1024);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .buffer = buffer,
            .tty = try vaxis.Tty.init(io, buffer),
            .vx = undefined,
            .loop = undefined,
            .frame = std.heap.ArenaAllocator.init(allocator),
        };
        self.vx = try vaxis.init(io, allocator, env, .{});
        self.loop = .init(io, &self.tty, &self.vx);
        try self.loop.start();
        try self.vx.enterAltScreen(self.tty.writer());
        // Ask what the terminal can do: kitty keyboard, true colour, unicode.
        try self.vx.queryTerminal(self.tty.writer(), .fromMilliseconds(250));
        try self.vx.setMouseMode(self.tty.writer(), true);
        // Light or dark: ask outright, and ask to be told when it changes. Both
        // answers arrive as events, so the first frame is drawn dark and repainted
        // if the terminal says otherwise.
        if (env.get("KRTEK_THEME")) |forced| {
            self.forced_scheme = if (std.ascii.eqlIgnoreCase(forced, "light")) .light else .dark;
            self.scheme = self.forced_scheme.?;
        } else {
            self.vx.subscribeToColorSchemeUpdates(self.tty.writer()) catch {};
            self.vx.queryColor(self.tty.writer(), .bg) catch {};
        }
        // The screen has no size until a resize arrives, and the first frame is
        // drawn before that; ask the terminal directly.
        try self.vx.resize(allocator, self.tty.writer(), try self.tty.getWinsize());
        self.window = self.vx.window();
        return self;
    }

    pub fn deinit(self: *Term) void {
        self.follow(0);
        self.forgetImage();
        self.held.deinit(self.allocator);
        self.frame.deinit();
        self.loop.stop();
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        self.allocator.free(self.buffer);
        self.allocator.destroy(self);
    }

    /// A terminal that reports nothing, or almost nothing, still has to be drawn
    /// into: the layout subtracts rows for the header and the status bar, so it is
    /// given a floor here instead of a guard at every subtraction. Whatever falls
    /// outside the real window is dropped when it is printed.
    pub fn size(self: *Term) Size {
        return .{
            .rows = @max(6, self.vx.screen.height),
            .cols = @max(24, self.vx.screen.width),
        };
    }

    // --- frame building ---

    pub fn begin(self: *Term) void {
        // The previous frame is on screen, so its text can go.
        _ = self.frame.reset(.retain_capacity);
        self.window = self.vx.window();
        self.window.clear();
        self.row = 0;
        self.col = 0;
        self.current = .{};
    }

    pub fn flush(self: *Term) !void {
        try self.vx.render(self.tty.writer());
    }

    /// Print at the cursor and advance it. Vaxis measures the text, so a wide or
    /// combining character moves the cursor by what it really occupies.
    ///
    /// Bytes that are not UTF-8 are drawn as U+FFFD, one a byte. Handed over as
    /// they are, vaxis counted a broken sequence one way, the terminal drew it
    /// another and `width` and `tail` counted a third, and whatever came after
    /// them on the line moved by the difference. It is the drawing that changes,
    /// not the value: the row form edits what it shows, and a value cleaned when
    /// it was read would go back into the table with U+FFFD in it.
    pub fn put(self: *Term, bytes: []const u8) void {
        if (std.unicode.utf8ValidateSlice(bytes)) {
            return self.putWhole(bytes);
        }
        var pieces: Pieces = .{ .rest = bytes };
        while (pieces.next()) |piece| {
            self.putWhole(piece.drawn);
        }
    }

    /// `put`, for text that is UTF-8.
    fn putWhole(self: *Term, bytes: []const u8) void {
        if (bytes.len == 0 or self.row >= self.window.height) {
            return;
        }
        // Copied, because the cell only borrows it until render time.
        const owned = self.frame.allocator().dupe(u8, bytes) catch return;
        const printed = self.window.printSegment(
            .{ .text = owned, .style = self.current },
            .{ .row_offset = self.row, .col_offset = self.col, .wrap = .none },
        );
        self.col = if (printed.overflow) self.window.width else printed.col;
    }

    pub fn print(self: *Term, comptime fmt: []const u8, args: anytype) void {
        var tmp: [512]u8 = undefined;
        self.put(std.mem.print(&tmp, fmt, args) catch return);
    }

    /// Move to a 0-based position.
    pub fn moveTo(self: *Term, row: usize, col: usize) void {
        self.row = @intCast(@min(row, @as(usize, self.window.height)));
        self.col = @intCast(@min(col, @as(usize, self.window.width)));
    }

    pub fn clearToEol(self: *Term) void {
        if (self.row >= self.window.height) {
            return;
        }
        var at = self.col;
        while (at < self.window.width) : (at += 1) {
            self.window.writeCell(at, self.row, .{ .style = self.current });
        }
    }

    pub fn style(self: *Term, s: Style) void {
        self.current = .{
            .fg = if (s.fg) |index| colour(index, self.scheme) else .default,
            .bg = if (s.bg) |index| colour(index, self.scheme) else .default,
            .bold = s.bold,
            .dim = s.dim,
            .italic = s.italic,
            .reverse = s.reverse,
            .ul_style = if (s.underline) .single else .off,
            .ul = if (s.underline_colour) |index| colour(index, self.scheme) else .default,
        };
    }

    /// Can the terminal draw a picture? Kitty, Ghostty and WezTerm say yes.
    pub fn canDrawImages(self: *Term) bool {
        return self.vx.caps.kitty_graphics;
    }

    /// Draw `bytes` - a PNG, a JPEG, whatever the decoder knows - scaled to fit
    /// the given cells. Fails if the terminal cannot do graphics or the bytes are
    /// not a picture, and the caller then shows them as bytes.
    pub fn image(self: *Term, bytes: []const u8, row: usize, col: usize, rows: u16, cols: u16) !void {
        if (!self.canDrawImages()) {
            return error.NoGraphics;
        }
        const hash = std.hash.Wyhash.hash(0, bytes);
        if (self.picture == null or self.picture_hash != hash) {
            self.forgetImage();
            self.picture = try self.vx.loadImage(self.allocator, self.tty.writer(), .{ .mem = bytes });
            self.picture_hash = hash;
        }
        const area = self.window.child(.{
            .x_off = @intCast(col),
            .y_off = @intCast(row),
            .width = cols,
            .height = rows,
        });
        try self.picture.?.draw(area, .{ .scale = .contain });
    }

    pub fn forgetImage(self: *Term) void {
        if (self.picture) |old| {
            self.vx.freeImage(self.tty.writer(), old.id);
        }
        self.picture = null;
        self.picture_hash = 0;
    }

    /// Put text in the system clipboard, through OSC 52, so it works over ssh and
    /// inside tmux as well - there is no local clipboard to talk to.
    pub fn copy(self: *Term, text: []const u8) !void {
        try self.vx.copyToSystemClipboard(self.tty.writer(), text, self.allocator);
    }

    pub fn reset(self: *Term) void {
        self.current = .{};
    }

    /// Where the terminal's own cursor sits, or nowhere while nothing is typed.
    /// A blinking bar, because it only ever appears where text is being typed.
    /// Show the cursor at a cell: a beam where something is being typed, which is
    /// between two characters, and a block where it is on one - the editor's
    /// normal mode, whose commands are about the character under it.
    pub fn cursorAt(self: *Term, row: usize, col: usize, on_a_character: bool) void {
        self.window.setCursorShape(if (on_a_character) .block else .beam_blink);
        self.window.showCursor(
            @intCast(@min(col, @as(usize, self.window.width -| 1))),
            @intCast(@min(row, @as(usize, self.window.height -| 1))),
        );
    }

    pub fn cursorOff(self: *Term) void {
        self.vx.screen.cursor_vis = false;
    }

    // --- handing the terminal over ---

    /// Give the terminal to something else. The key loop stops - its reader
    /// thread would otherwise eat every keystroke meant for the other program -
    /// the alternate screen is left so what was on it comes back afterwards, and
    /// the cursor is shown, because whatever takes over is going to want one.
    ///
    /// The terminal stays raw. That is what a shell on the far end wants: the pty
    /// there does the echoing and the line editing, and a local terminal that
    /// also did them would double every character.
    pub fn release(self: *Term) void {
        self.follow(0);
        self.loop.stop();
        self.vx.exitAltScreen(self.tty.writer()) catch {};
        const writer = self.tty.writer();
        writer.writeAll("\x1b[?25h") catch {};
        writer.flush() catch {};

        // The descriptors this program was started with, where they are the
        // terminal - and not one opened from `/dev/tty`.
        //
        // On macOS a descriptor for `/dev/tty` cannot be waited on: `poll` calls
        // it invalid and `select` never calls it ready, while `read` on the very
        // same descriptor returns what was typed. A shell built on one there sees
        // no keystroke ever. The descriptor the shell handed over works properly,
        // so it is the one to use, and `/dev/tty` is the fallback for the case
        // where standard input is not a terminal at all - where there is nothing
        // to wait on anyway.
        self.read_fd = if (isatty(0) == 1) 0 else self.openTerminal();
        self.write_fd = if (isatty(1) == 1) 1 else self.read_fd;
    }

    fn openTerminal(self: *Term) std.c.fd_t {
        self.opened_fd = std.c.open("/dev/tty", .{ .ACCMODE = .RDWR });
        return self.opened_fd;
    }

    /// Take it back, and forget everything that was on the screen: what ran in
    /// between drew whatever it liked, so nothing about the old frame is true.
    pub fn reclaim(self: *Term) void {
        if (self.opened_fd >= 0) {
            _ = std.c.close(self.opened_fd);
            self.opened_fd = -1;
        }
        self.read_fd = -1;
        self.write_fd = -1;
        self.vx.enterAltScreen(self.tty.writer()) catch {};
        self.vx.queueRefresh();
        self.current = .{};
        self.loop.start() catch {};
    }

    /// The terminal itself, for a caller that has to wait on it and on something
    /// else at the same time.
    ///
    /// Its own descriptor, opened for the handover and closed after it. The one
    /// libvaxis holds is not a descriptor anything here may `poll` - it belongs
    /// to a reader that has just been stopped and to an I/O layer with its own
    /// ideas - and asking about it gets POLLNVAL rather than an answer. The
    /// terminal is the terminal whichever descriptor names it, and the raw mode
    /// it is in is a property of the terminal.
    pub fn handle(self: *Term) std.c.fd_t {
        return self.read_fd;
    }

    /// Bytes straight from the terminal, or none. Only while it is released: the
    /// key loop owns this at every other moment.
    ///
    /// `read(2)`, not a reader that waits for a full buffer - what is wanted is
    /// whatever has been typed *by now*, and holding a keystroke until the next
    /// four thousand arrive is, for somebody at a shell, forever.
    pub fn readRaw(self: *Term, into: []u8) usize {
        if (self.read_fd < 0) {
            return 0;
        }
        const got = std.c.read(self.read_fd, into.ptr, into.len);
        return if (got > 0) @intCast(got) else 0;
    }

    /// Bytes straight to the terminal, through nothing at all.
    pub fn writeRaw(self: *Term, bytes: []const u8) void {
        if (self.write_fd < 0) {
            return;
        }
        var at: usize = 0;
        while (at < bytes.len) {
            const wrote = std.c.write(self.write_fd, bytes[at..].ptr, bytes.len - at);
            if (wrote <= 0) {
                return;
            }
            at += @intCast(wrote);
        }
    }

    // --- following ---

    /// Deliver a `tick` every `ms` milliseconds, or stop with 0. Nothing is
    /// polled and the wait for a key still blocks: the ticks come from a task of
    /// its own that sleeps and pushes an event into the same queue the terminal
    /// is read into, so one wait covers both.
    pub fn follow(self: *Term, ms: u64) void {
        if (self.ticker) |*running| {
            running.cancel(self.io);
            self.ticker = null;
        }
        self.tick_ms = ms;
        if (ms == 0) {
            return;
        }
        // A timer that cannot be started is not worth failing over: the view
        // simply does not follow, and the key that turns it on says so.
        self.ticker = self.io.concurrent(Term.tickRun, .{self}) catch null;
    }

    /// Whether ticks are being delivered.
    pub fn following(self: *Term) bool {
        return self.ticker != null;
    }

    fn tickRun(self: *Term) void {
        while (true) {
            // The sleep is the cancellation point: `follow(0)` ends the task here.
            self.io.sleep(.fromMilliseconds(@intCast(self.tick_ms)), .awake) catch return;
            // Dropped when the queue is full, because a tick is only ever a request
            // to look again and the app is plainly already behind on the last one.
            _ = self.loop.tryPostEvent(.tick) catch return;
        }
    }

    // --- input ---

    /// Wait for something to happen, then take whatever else is already queued.
    pub fn keys(self: *Term, out: *std.ArrayList(Key)) !void {
        out.clearRetainingCapacity();
        var first = true;
        // Ticks are coalesced: a reload that took longer than the interval leaves
        // several waiting, and doing them all in a row would only fall further
        // behind. One request to look again is the same as five.
        var ticked = false;
        while (true) {
            // What was held back comes first, being older than anything still in
            // the queue - and having it is a reason not to wait for more.
            const event = if (self.nextHeld()) |kept|
                kept
            else if (first)
                try self.loop.nextEvent()
            else
                (try self.loop.tryEvent()) orelse break;
            first = false;
            switch (event) {
                .key_press => |key| try self.pressed(out, key),
                .mouse => |mouse| {
                    // Only presses act; motion and release would fire twice.
                    if (mouse.type != .press) {
                        continue;
                    }
                    try out.append(self.allocator, .{ .mouse = .{
                        .row = @intCast(@max(0, mouse.row)),
                        .col = @intCast(@max(0, mouse.col)),
                        .button = switch (mouse.button) {
                            .left => .left,
                            .middle => .middle,
                            .right => .right,
                            .wheel_up => .wheel_up,
                            .wheel_down => .wheel_down,
                            else => .other,
                        },
                    } });
                },
                .winsize => |ws| try self.vx.resize(self.allocator, self.tty.writer(), ws),
                .color_scheme => |scheme| if (self.forced_scheme == null) {
                    self.scheme = switch (scheme) {
                        .light => .light,
                        .dark => .dark,
                    };
                },
                .color_report => |report| if (self.forced_scheme == null and report.kind == .bg) {
                    self.scheme = if (isDark(report.value)) .dark else .light;
                },
                .paste_start => {
                    self.pasting = true;
                    self.paste_after_cr = false;
                },
                .paste_end => {
                    // A paste that ends in the middle of a character is not
                    // finished by whatever is typed after it.
                    if (self.unfinished.drop()) |point| {
                        try out.append(self.allocator, .{ .char = point });
                    }
                    self.pasting = false;
                },
                .tick => if (!ticked) {
                    ticked = true;
                    try out.append(self.allocator, .tick);
                },
                else => {},
            }
        }
    }

    /// What one key press comes to: the text it typed, or the key it is.
    fn pressed(self: *Term, out: *std.ArrayList(Key), key: vaxis.Key) !void {
        // The text the key produced comes first. Under the kitty keyboard
        // protocol `codepoint` is the *unshifted* key - shift+a arrives as 'a'
        // with shift held, and on a layout where `:`, `/` or `@` need shift, the
        // same - so anything typed has to be read from `text`, which is what the
        // terminal says was produced.
        if (try typed(&self.unfinished, self.allocator, out, key)) {
            // Text after a pasted CR means the CR was a line break of its own, and
            // an LF that comes later is another one rather than the rest of a
            // CRLF. Only keys that go through `translate` cleared this, and text
            // does not, so `a` CR `b` LF `c` was pasted as two lines.
            self.paste_after_cr = false;
            return;
        }
        if (self.translate(key)) |mapped| {
            try out.append(self.allocator, mapped);
        }
    }

    /// Look at what has arrived without waiting, and say whether ctrl+c was in
    /// it. Other keys are dropped on purpose: this runs while a statement is
    /// being waited on, and acting on them in the middle of it would be worse
    /// than losing them.
    pub fn interrupted(self: *Term) bool {
        return self.asked(.statement);
    }

    /// The same look, for a connection that is being opened. Two things differ.
    /// Esc ends the wait as well: there is a panel on the screen, and esc is
    /// what closes a panel. And what else arrives is held rather than dropped,
    /// for `keys` to hand out afterwards - see `held`. Giving up lets go of what
    /// was held: keys typed at a connection are not meant for the list that
    /// comes back in its place.
    pub fn dismissed(self: *Term) bool {
        return self.asked(.connection);
    }

    /// The oldest event still held back, if any is.
    fn nextHeld(self: *Term) ?Event {
        if (self.held_at < self.held.items.len) {
            defer self.held_at += 1;
            return self.held.items[self.held_at];
        }
        self.held.clearRetainingCapacity();
        self.held_at = 0;
        return null;
    }

    /// Kept for later, up to a point: somebody leaning on a key for a minute is
    /// not typing ahead.
    fn hold(self: *Term, event: Event) void {
        if (self.held.items.len < 256) {
            self.held.append(self.allocator, event) catch {};
        }
    }

    fn asked(self: *Term, wait: enum { statement, connection }) bool {
        var found = false;
        while (self.loop.tryEvent() catch null) |event| {
            switch (event) {
                .key_press => |key| {
                    const ctrl_c = key.mods.ctrl and (key.codepoint == 'c' or key.codepoint == 'C');
                    if (ctrl_c or (wait == .connection and key.codepoint == vaxis.Key.escape)) {
                        found = true;
                        self.held.clearRetainingCapacity();
                        self.held_at = 0;
                    } else if (wait == .connection and !found) {
                        self.hold(event);
                    }
                },
                .winsize => |ws| self.vx.resize(self.allocator, self.tty.writer(), ws) catch {},
                // Not keys, and not to be dropped with them: the terminal says
                // what colour it is once, in answer to a question asked at the
                // start, and a connection named on the command line is being
                // waited for by the time the answer arrives.
                .color_scheme => |scheme| if (self.forced_scheme == null) {
                    self.scheme = switch (scheme) {
                        .light => .light,
                        .dark => .dark,
                    };
                },
                .color_report => |report| if (self.forced_scheme == null and report.kind == .bg) {
                    self.scheme = if (isDark(report.value)) .dark else .light;
                },
                else => if (wait == .connection and !found) {
                    self.hold(event);
                },
            }
        }
        return found;
    }

    /// What this key press produced, if it produced text at all.
    ///
    /// This is the field to read, not `codepoint`. Under the kitty keyboard
    /// protocol - Ghostty, Kitty, WezTerm - `codepoint` is the *unshifted* key:
    /// shift+a arrives as 'a' with shift held, and on any layout where `:`, `/` or
    /// `@` need shift, so do they. Vaxis asks the terminal to report the text of
    /// each key (`report_text`), and that is what was actually typed.
    ///
    /// A control key carries `text` too in the legacy encoding - a bare `\r` for
    /// enter - so anything below a space is left to `translate`, as is anything
    /// with ctrl or alt held, which is a command and not text. It is the first
    /// byte that says, not the first character: the text of a key is not always
    /// whole characters, and the rest of one cut in two is text as well.
    fn printableText(key: vaxis.Key) ?[]const u8 {
        if (key.mods.ctrl or key.mods.alt or key.mods.super) {
            return null;
        }
        const text = key.text orelse return null;
        if (text.len == 0 or text[0] < 0x20 or text[0] == 0x7f) {
            return null;
        }
        return text;
    }

    /// Type the text of `key`, if it is text at all, and say whether it was.
    ///
    /// Vaxis reads the terminal 1024 bytes at a time and does not hold back a
    /// character a read ends in the middle of. Its start comes as the end of the
    /// text of one key, and the rest at the start of the next read as keys of
    /// their own, a byte each. Read as they come, the pieces are two to four
    /// U+FFFD in the middle of a long paste - and in the statement that is run
    /// after it - so the start is held in `unfinished` until the rest arrives.
    fn typed(unfinished: *Unfinished, allocator: std.mem.Allocator, out: *std.ArrayList(Key), key: vaxis.Key) !bool {
        const text = printableText(key) orelse {
            // Whatever this key is, it is not the rest of that character.
            if (unfinished.drop()) |point| {
                try out.append(allocator, .{ .char = point });
            }
            return false;
        };
        const taken = unfinished.take(text);
        if (taken.finished) |point| {
            try out.append(allocator, .{ .char = point });
        }
        var points: Chars = .{ .rest = taken.rest };
        while (points.next()) |point| {
            // A control character inside the text of a key is one vaxis read
            // into the U+FFFD of a broken byte in front of it. It was never a key.
            if (point < 0x20 or point == 0x7f) {
                continue;
            }
            try out.append(allocator, .{ .char = point });
        }
        return true;
    }

    fn translate(self: *Term, key: vaxis.Key) ?Key {
        const K = vaxis.Key;
        // Pressing shift on its own is a key event too, and the kitty protocol
        // gives every key that is not text a codepoint in the private use area -
        // shift is 57441. Dropped here, or holding shift would type a character out
        // of that block. The named keys below are matched before that rule applies.
        if (key.isModifier()) {
            return null;
        }
        // A newline inside pasted text is text, not a submit. A pasted LF arrives
        // as ctrl+j in the legacy encoding, because that is the same byte, and a
        // CR as enter - inside a paste both are a line break, and CRLF is one.
        if (self.pasting) {
            const is_cr = key.codepoint == K.enter or (key.mods.ctrl and key.codepoint == 'm');
            const is_lf = key.codepoint == '\n' or (key.mods.ctrl and key.codepoint == 'j');
            if (is_cr) {
                self.paste_after_cr = true;
                return .{ .char = '\n' };
            }
            if (is_lf) {
                const second_half_of_crlf = self.paste_after_cr;
                self.paste_after_cr = false;
                return if (second_half_of_crlf) null else Key{ .char = '\n' };
            }
            self.paste_after_cr = false;
        }
        if (key.mods.ctrl and key.codepoint >= 'a' and key.codepoint <= 'z') {
            return .{ .ctrl = @intCast(key.codepoint) };
        }
        if (key.mods.alt) {
            // A digit by where the key is rather than by what the layout puts on
            // it. A Czech keyboard has `+` and `ě` where 1 and 2 are and the
            // digits themselves only with shift, so alt and the key marked 1 is
            // alt and `+` there - unless the terminal says which key it was, and
            // one that speaks the kitty protocol does.
            const placed = key.base_layout_codepoint orelse key.codepoint;
            if (placed >= '0' and placed <= '9') {
                return .{ .alt = @intCast(placed) };
            }
            if (key.codepoint >= 'a' and key.codepoint <= 'z') {
                return .{ .alt = @intCast(key.codepoint) };
            }
        }
        return switch (key.codepoint) {
            K.enter, K.kp_enter => .enter,
            K.tab => if (key.mods.shift) .back_tab else .tab,
            K.escape => .escape,
            K.backspace => .backspace,
            K.delete, K.kp_delete => .delete,
            K.up, K.kp_up => .up,
            K.down, K.kp_down => .down,
            K.left, K.kp_left => .left,
            K.right, K.kp_right => .right,
            K.home, K.kp_home => .home,
            K.end, K.kp_end => .end,
            K.page_up, K.kp_page_up => .page_up,
            K.page_down, K.kp_page_down => .page_down,
            // Anything left in the private use area is a key this app has no use
            // for - a media key, a function key, the rest of the keypad - and must
            // not turn into the character that lives at that codepoint.
            else => if (key.codepoint < 0x20 or key.codepoint > 0x10ffff or
                (key.codepoint >= 0xe000 and key.codepoint <= 0xf8ff)) null else Key{ .char = key.codepoint },
        };
    }
};

// --- display width, still needed for laying out columns ---

/// Columns a piece of text occupies, as vaxis measures it: grapheme clusters
/// rather than codepoints, so an emoji built out of several of them counts once.
/// Text that is not UTF-8 is measured the way `Term.put` draws it - see `Pieces`.
pub fn width(text: []const u8) usize {
    if (std.unicode.utf8ValidateSlice(text)) {
        return measure(text);
    }
    var total: usize = 0;
    var pieces: Pieces = .{ .rest = text };
    while (pieces.next()) |piece| {
        total += measure(piece.drawn);
    }
    return total;
}

/// What vaxis says `text` is wide, without letting it add up past what it adds
/// up in. That is a u16, so a value of 65536 columns overflows it - one cell of
/// 35 kB of hex is enough, and a safe build panicked opening its table. Long text
/// goes to it a slice at a time instead, each cut where a grapheme ends and none
/// longer than half of 65535 bytes: no grapheme is more than two columns wide or
/// less than a byte long, so no slice can come to more than vaxis can count.
fn measure(text: []const u8) usize {
    const most = std.math.maxInt(u16) / 2;
    if (text.len <= most) {
        return vaxis.gwidth.gwidth(text, .unicode);
    }
    var total: usize = 0;
    var start: usize = 0;
    var it = vaxis.unicode.GraphemeIterator.init(text);
    while (it.next()) |cluster| {
        // The slice so far ends where this grapheme starts, and would be too
        // long with it. One grapheme on its own is never more than two columns,
        // however long it is.
        if (cluster.start + cluster.len - start > most and cluster.start > start) {
            total += vaxis.gwidth.gwidth(text[start..cluster.start], .unicode);
            start = cluster.start;
        }
    }
    return total + vaxis.gwidth.gwidth(text[start..], .unicode);
}

pub fn charWidth(point: u21) u8 {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(point, &buf) catch return 1;
    return @intCast(@min(2, width(buf[0..len])));
}

/// A prefix of some text and the columns it takes.
pub const Fit = struct { text: []const u8, cols: usize };

/// The longest prefix of `text` that fits in `max` columns, plus its width.
pub fn fit(text: []const u8, max: usize) Fit {
    var total: usize = 0;
    var end: usize = 0;
    // A grapheme cluster at a time, so a cell is never cut in the middle of one -
    // and only as far as it fits, so a long value is not read to its end. A byte
    // that is not UTF-8 is a column of its own, the U+FFFD `put` draws for it,
    // rather than whatever vaxis would read it as. See `Pieces`.
    while (end < text.len) {
        const rest = text[end..];
        var taken: usize = 1;
        var w = width("\u{fffd}");
        if (decode(rest) != null) {
            var it = vaxis.unicode.GraphemeIterator.init(rest);
            const cluster = it.next().?.bytes(rest);
            // Vaxis reads a broken byte into the cluster in front of it; the
            // cluster ends where the text stops being whole characters.
            taken = 0;
            while (taken < cluster.len) {
                taken += (decode(rest[taken..]) orelse break).len;
            }
            w = width(rest[0..taken]);
        }
        if (total + w > max) {
            break;
        }
        total += w;
        end += taken;
    }
    return .{ .text = text[0..end], .cols = total };
}

// --- characters out of bytes that are not always UTF-8 ---
//
// Text comes in from two places that promise nothing: the terminal, cut wherever
// a read of it ends, and a database column, which holds whatever was put in it.
// `std.unicode.utf8Decode` wants a slice that is already one whole character and
// is `unreachable` on anything else, and a `Utf8View` made without checking
// reads past the end of the text it was made of.

/// One character, and how many bytes of the text it took.
pub const Char = struct {
    point: u21,
    len: u3,
};

/// What a byte that is not part of a whole character reads as: U+FFFD, one byte
/// at a time, so text that is not UTF-8 can still be walked to its end.
const replacement: Char = .{ .point = 0xfffd, .len = 1 };

/// The character `bytes` starts with, or null when they do not start with a
/// whole one: nothing at all, a byte no character starts with, a sequence cut
/// short, an overlong one, a surrogate, anything past U+10FFFF.
fn decode(bytes: []const u8) ?Char {
    if (bytes.len == 0) {
        return null;
    }
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return null;
    if (len > bytes.len) {
        return null;
    }
    const point: u21 = switch (len) {
        1 => bytes[0],
        2 => std.unicode.utf8Decode2(bytes[0..2].*) catch return null,
        3 => std.unicode.utf8Decode3(bytes[0..3].*) catch return null,
        4 => std.unicode.utf8Decode4(bytes[0..4].*) catch return null,
        else => unreachable,
    };
    return .{ .point = point, .len = len };
}

/// The character `bytes` ends with; `bytes` must not be empty. No more than
/// three continuation bytes are walked back over, because no character has
/// more, and a last byte that is not the end of a whole character is a U+FFFD
/// of its own.
pub fn decodeLast(bytes: []const u8) Char {
    var at = bytes.len - 1;
    while (at > 0 and bytes.len - at < 4 and bytes[at] & 0xc0 == 0x80) {
        at -= 1;
    }
    const char = decode(bytes[at..]) orelse return replacement;
    return if (char.len == bytes.len - at) char else replacement;
}

/// The characters of a piece of text one at a time, with whatever is not UTF-8
/// read as U+FFFD a byte at a time rather than read past.
const Chars = struct {
    rest: []const u8,

    pub fn next(self: *Chars) ?u21 {
        if (self.rest.len == 0) {
            return null;
        }
        const char = decode(self.rest) orelse replacement;
        self.rest = self.rest[char.len..];
        return char.point;
    }
};

/// Text cut where it stops being UTF-8, as it is drawn and measured: each run of
/// whole characters as it is, and a U+FFFD for every byte that is not part of
/// one, a byte at a time as `Chars` reads them. `Term.put`, `width` and `fit` all
/// go through this, so the width a column is laid out with is the width drawn.
const Pieces = struct {
    rest: []const u8,

    const Piece = struct {
        /// What is drawn.
        drawn: []const u8,
        /// How many bytes of the text it stands for.
        len: usize,
    };

    pub fn next(self: *Pieces) ?Piece {
        if (self.rest.len == 0) {
            return null;
        }
        var end: usize = 0;
        while (end < self.rest.len) {
            const char = decode(self.rest[end..]) orelse break;
            end += char.len;
        }
        if (end == 0) {
            self.rest = self.rest[1..];
            return .{ .drawn = "\u{fffd}", .len = 1 };
        }
        const run = self.rest[0..end];
        self.rest = self.rest[end..];
        return .{ .drawn = run, .len = run.len };
    }
};

/// The start of a character, as much of it as has come. See `Term.typed`.
const Unfinished = struct {
    bytes: [4]u8 = undefined,
    len: u3 = 0,
    /// How many bytes the character has, by the first of them.
    need: u3 = 0,

    /// What there is to type now that `text` has come: the character that was
    /// held, if it is done with - finished by the continuation bytes `text`
    /// starts with, or a U+FFFD when `text` goes on with something else - and
    /// the rest of `text`. A character `text` ends in the middle of is held in
    /// its turn, and is not part of the rest.
    fn take(self: *Unfinished, text: []const u8) struct { finished: ?u21, rest: []const u8 } {
        var rest = text;
        var finished: ?u21 = null;
        if (self.len != 0) {
            while (self.len < self.need and rest.len != 0 and rest[0] & 0xc0 == 0x80) {
                self.bytes[self.len] = rest[0];
                self.len += 1;
                rest = rest[1..];
            }
            if (self.len < self.need and rest.len == 0) {
                // All of it went into the character, which is still not whole:
                // the rest of an emoji comes a byte a key.
                return .{ .finished = null, .rest = rest };
            }
            finished = if (self.len < self.need)
                replacement.point
            else if (decode(self.bytes[0..self.need])) |char|
                char.point
            else
                replacement.point;
            self.len = 0;
        }
        // The start of a character with fewer continuation bytes after it than
        // it has, at the very end, is where the read ended.
        var at = rest.len;
        while (at > 0 and rest.len - at < 3 and rest[at - 1] & 0xc0 == 0x80) {
            at -= 1;
        }
        if (at > 0) {
            const need = std.unicode.utf8ByteSequenceLength(rest[at - 1]) catch 0;
            const have = rest.len - (at - 1);
            if (need > have) {
                @memcpy(self.bytes[0..have], rest[at - 1 ..]);
                self.len = @intCast(have);
                self.need = need;
                rest = rest[0 .. at - 1];
            }
        }
        return .{ .finished = finished, .rest = rest };
    }

    /// What was held, as the U+FFFD it is once nothing is going to finish it.
    fn drop(self: *Unfinished) ?u21 {
        if (self.len == 0) {
            return null;
        }
        self.len = 0;
        return replacement.point;
    }
};

const testing = std.testing;

test "a character a read of the terminal cut in two is typed as one" {
    // Each read is parsed on its own, as vaxis does. A key that is not text
    // stands for itself by its code point, where `keys` would `translate` it.
    const cases = [_]struct { reads: []const []const u8, typed: []const u21 }{
        .{ .reads = &.{ "\xc4", "\x8daj" }, .typed = &.{ 'č', 'a', 'j' } },
        .{ .reads = &.{ "\xe2", "\x82\xac" }, .typed = &.{'€'} },
        .{ .reads = &.{ "\xe2\x82", "\xac" }, .typed = &.{'€'} },
        .{ .reads = &.{ "\xf0", "\x9f", "\x98", "\x80" }, .typed = &.{0x1f600} },
        // Behind an Arabic number sign, which joins whatever follows it into one
        // grapheme, the start of a character is the end of a key whose first
        // character is whole.
        .{ .reads = &.{ "\u{600}\xc4", "\x8d" }, .typed = &.{ 0x600, 'č' } },
        // Held until something comes after it, and a U+FFFD when that is not the
        // rest of it - more text or a key that is not text.
        .{ .reads = &.{"ab\xc4"}, .typed = &.{ 'a', 'b' } },
        .{ .reads = &.{ "ab\xc4", "x" }, .typed = &.{ 'a', 'b', 0xfffd, 'x' } },
        .{ .reads = &.{ "\xe2\x82", "\r" }, .typed = &.{ 0xfffd, vaxis.Key.enter } },
        // Not the rest of anything: one U+FFFD a byte, as before.
        .{ .reads = &.{"\x8d\x8d"}, .typed = &.{ 0xfffd, 0xfffd } },
        // A byte that cannot start a character swallows the carriage return
        // after it into its U+FFFD in vaxis, and the return is not typed.
        .{ .reads = &.{"\xc4\r"}, .typed = &.{0xfffd} },
    };
    // And that one is a single key indeed, not one that happens to stop where
    // the character it joins does.
    var parser: vaxis.Parser = .{};
    try testing.expectEqualStrings("\u{600}\xc4", (try parser.parse("\u{600}\xc4", null)).event.?.key_press.text.?);
    for (cases) |case| {
        const got = try typeReads(testing.allocator, case.reads);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u21, case.typed, got);
    }

    // Whatever vaxis does with a grapheme, text cut into three reads anywhere at
    // all comes out as the characters it went in as.
    const text = "Příliš žluťoučký kůň € 日本 😀 👩\u{200d}🚀 e\u{301} \u{600}č";
    var want: std.ArrayList(u21) = .empty;
    defer want.deinit(testing.allocator);
    var points: Chars = .{ .rest = text };
    while (points.next()) |point| {
        try want.append(testing.allocator, point);
    }
    for (0..text.len + 1) |i| {
        for (i..text.len + 1) |j| {
            const got = try typeReads(testing.allocator, &.{ text[0..i], text[i..j], text[j..] });
            defer testing.allocator.free(got);
            try testing.expectEqualSlices(u21, want.items, got);
        }
    }
}

/// What `keys` types from these reads of the terminal, with the code point of a
/// key that is not text standing in for whatever `translate` makes of it.
fn typeReads(allocator: std.mem.Allocator, reads: []const []const u8) ![]u21 {
    var parser: vaxis.Parser = .{};
    var unfinished: Unfinished = .{};
    var keys: std.ArrayList(Key) = .empty;
    defer keys.deinit(allocator);
    var points: std.ArrayList(u21) = .empty;
    errdefer points.deinit(allocator);
    for (reads) |read| {
        var at: usize = 0;
        while (at < read.len) {
            const result = try parser.parse(read[at..], null);
            at += result.n;
            const key = result.event.?.key_press;
            keys.clearRetainingCapacity();
            if (!try Term.typed(&unfinished, allocator, &keys, key)) {
                try keys.append(allocator, .{ .char = key.codepoint });
            }
            for (keys.items) |one| {
                try points.append(allocator, one.char);
            }
        }
    }
    return points.toOwnedSlice(allocator);
}

test "a pasted line ends at a CR, an LF or a CRLF, whatever was typed between" {
    const cases = [_]struct { paste: []const u8, typed: []const u8 }{
        // Text between a CR and an LF: the LF is a line of its own, not the
        // rest of a CRLF. It used to be swallowed, and `a` CR `b` LF `c` was
        // pasted as `a` and `bc`.
        .{ .paste = "a\rb\nc", .typed = "a\nb\nc" },
        .{ .paste = "a\rb\r\nc", .typed = "a\nb\nc" },
        .{ .paste = "a\r\nb", .typed = "a\nb" },
        .{ .paste = "a\nb", .typed = "a\nb" },
        .{ .paste = "a\r\rb", .typed = "a\n\nb" },
        .{ .paste = "a\r\r\nb", .typed = "a\n\nb" },
        .{ .paste = "č\r\xc5\xbe\nx", .typed = "č\nž\nx" },
    };
    for (cases) |case| {
        // Only what `pressed` touches; the terminal itself is not needed.
        var term: Term = undefined;
        term.allocator = testing.allocator;
        term.unfinished = .{};
        term.pasting = true;
        term.paste_after_cr = false;
        var keys: std.ArrayList(Key) = .empty;
        defer keys.deinit(testing.allocator);
        var parser: vaxis.Parser = .{};
        var at: usize = 0;
        while (at < case.paste.len) {
            const result = try parser.parse(case.paste[at..], null);
            at += result.n;
            try term.pressed(&keys, result.event.?.key_press);
        }
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(testing.allocator);
        for (keys.items) |key| {
            var buffer: [4]u8 = undefined;
            try got.appendSlice(testing.allocator, buffer[0..try std.unicode.utf8Encode(key.char, &buffer)]);
        }
        try testing.expectEqualStrings(case.typed, got.items);
    }
}

test "text that is not UTF-8 is as wide as it is drawn, a U+FFFD a byte" {
    // The two values KNOWN_ISSUES.md showed the line moving with, a broken start
    // in front of a combining accent, which vaxis reads into one, and a
    // character cut short at the end.
    const values = [_][]const u8{
        "\xc5\xbe\xc5\xbe\xc5\xbe\xbe\xbe\xbe\xbe\xbe\xff\xfe\xc0\xaf\xed\xa0\x80\xf4\x90\x80\x80",
        "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\xc5\xbe\xc5\xbe\xbe\xbe\xbe\xbe\xff\xfe\xc0\xaf\xed\xa0\x80\xf4\x90\x80\x80\xf0\x9f\x98\xe2\x82",
        "a\xe2e\xcc\x81b",
        "日本\xe2\x82",
    };
    // Three ž, then sixteen bytes that are no character's: nineteen columns.
    try testing.expectEqual(@as(usize, 19), width(values[0]));
    for (values) |text| {
        // What is drawn: the pieces, which together stand for every byte.
        var drawn: std.ArrayList(u8) = .empty;
        defer drawn.deinit(testing.allocator);
        var pieces: Pieces = .{ .rest = text };
        var stood_for: usize = 0;
        while (pieces.next()) |piece| {
            try drawn.appendSlice(testing.allocator, piece.drawn);
            stood_for += piece.len;
        }
        try testing.expectEqual(text.len, stood_for);
        try testing.expect(std.unicode.utf8ValidateSlice(drawn.items));
        // As many U+FFFD as `Chars` reads the text with.
        var wanted: usize = 0;
        var points: Chars = .{ .rest = text };
        while (points.next()) |point| {
            wanted += @intFromBool(point == 0xfffd);
        }
        try testing.expectEqual(wanted, std.mem.count(u8, drawn.items, "\u{fffd}"));
        // The width the layout counts is the width of what is drawn.
        try testing.expectEqual(width(drawn.items), width(text));
        // And cut to any width, the part that fits is as wide as it says, and
        // ends where a character does.
        for (0..width(text) + 2) |max| {
            const part = fit(text, max);
            try testing.expect(part.cols <= max);
            try testing.expectEqual(width(part.text), part.cols);
            try testing.expect(std.mem.startsWith(u8, text, part.text));
        }
        try testing.expectEqualStrings(text, fit(text, width(text)).text);
    }
    // Text that is UTF-8 is cut the way it always was.
    try testing.expectEqualStrings("žlu", fit("žluťoučký", 3).text);
    try testing.expectEqualStrings("日", fit("日本", 3).text);
    try testing.expectEqualStrings("e\u{301}", fit("e\u{301}x", 1).text);
}

test "a value wider than vaxis can count is measured all the same" {
    // A u16 of columns is 65535; one cell of 35 kB of hex is more, and its table
    // would not open. Wide characters, which take two columns for three bytes,
    // and a grapheme of an accent on an accent past every slice boundary.
    const allocator = testing.allocator;
    const hex = try allocator.alloc(u8, 70_000);
    defer allocator.free(hex);
    @memset(hex, '0');
    try testing.expectEqual(@as(usize, 70_000), width(hex));
    const wide = try allocator.alloc(u8, 3 * 40_000);
    defer allocator.free(wide);
    for (0..40_000) |i| {
        @memcpy(wide[3 * i ..][0..3], "日");
    }
    try testing.expectEqual(@as(usize, 80_000), width(wide));
    var accents: std.ArrayList(u8) = .empty;
    defer accents.deinit(allocator);
    for (0..20_000) |_| {
        try accents.appendSlice(allocator, "e\u{301}\u{301}");
    }
    try testing.expectEqual(@as(usize, 20_000), width(accents.items));
    // And not UTF-8 at the same length: each broken byte a column.
    hex[1000] = 0xff;
    try testing.expectEqual(@as(usize, 70_000), width(hex));
}

test "only a whole character decodes, from either end" {
    try testing.expectEqual(@as(?Char, .{ .point = 'ž', .len = 2 }), decode("žluť"));
    try testing.expectEqual(@as(?Char, .{ .point = 0x1f600, .len = 4 }), decode("😀!"));
    // Nothing, a continuation byte, a character cut short twice, an overlong
    // slash, a surrogate, one past U+10FFFF, a byte UTF-8 never uses.
    for ([_][]const u8{ "", "\x80", "\xc5", "\xe2\x82", "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xff" }) |bytes| {
        try testing.expectEqual(@as(?Char, null), decode(bytes));
    }
    try testing.expectEqual(Char{ .point = 'ť', .len = 2 }, decodeLast("žluť"));
    try testing.expectEqual(Char{ .point = 0x1f600, .len = 4 }, decodeLast("!😀"));
    try testing.expectEqual(replacement, decodeLast("\x80\x80\x80\x80\x80"));
    try testing.expectEqual(replacement, decodeLast("ž\xbe"));
    try testing.expectEqual(replacement, decodeLast("a\xe2\x82"));
}
