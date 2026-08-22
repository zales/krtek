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
			238 => .{ .rgb = .{ 0x2e, 0x2e, 0x36 } }, // selection
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
			238 => .{ .rgb = .{ 0xd6, 0xdb, 0xec } }, // selection
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
	pub fn put(self: *Term, bytes: []const u8) void {
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
		self.put(std.fmt.bufPrint(&tmp, fmt, args) catch return);
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
	pub fn cursorAt(self: *Term, row: usize, col: usize) void {
		self.window.setCursorShape(.beam_blink);
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
	pub fn keys(self: *Term, out: *std.ArrayListUnmanaged(Key)) !void {
		out.clearRetainingCapacity();
		var first = true;
		// Ticks are coalesced: a reload that took longer than the interval leaves
		// several waiting, and doing them all in a row would only fall further
		// behind. One request to look again is the same as five.
		var ticked = false;
		while (true) {
			const event = if (first) try self.loop.nextEvent() else (try self.loop.tryEvent()) orelse break;
			first = false;
			switch (event) {
				.key_press => |key| {
					// The text the key produced comes first. Under the kitty
					// keyboard protocol `codepoint` is the *unshifted* key - shift+a
					// arrives as 'a' with shift held, and on a layout where `:`, `/`
					// or `@` need shift, the same - so anything typed has to be read
					// from `text`, which is what the terminal says was produced.
					if (printableText(key)) |text| {
						var points = std.unicode.Utf8View.initUnchecked(text).iterator();
						while (points.nextCodepoint()) |point| {
							try out.append(self.allocator, .{ .char = point });
						}
						continue;
					}
					if (self.translate(key)) |mapped| {
						try out.append(self.allocator, mapped);
					}
				},
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
				.paste_end => self.pasting = false,
				.tick => if (!ticked) {
					ticked = true;
					try out.append(self.allocator, .tick);
				},
				else => {},
			}
		}
	}

	/// Look at what has arrived without waiting, and say whether ctrl+c was in
	/// it. Other keys are dropped on purpose: this runs while a statement is
	/// being waited on, and acting on them in the middle of it would be worse
	/// than losing them.
	pub fn interrupted(self: *Term) bool {
		var found = false;
		while (self.loop.tryEvent() catch null) |event| {
			switch (event) {
				.key_press => |key| {
					if (key.mods.ctrl and (key.codepoint == 'c' or key.codepoint == 'C')) {
						found = true;
					}
				},
				.winsize => |ws| self.vx.resize(self.allocator, self.tty.writer(), ws) catch {},
				else => {},
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
	/// with ctrl or alt held, which is a command and not text.
	fn printableText(key: vaxis.Key) ?[]const u8 {
		if (key.mods.ctrl or key.mods.alt or key.mods.super) {
			return null;
		}
		const text = key.text orelse return null;
		if (text.len == 0) {
			return null;
		}
		const first_len = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
		const first = std.unicode.utf8Decode(text[0..first_len]) catch return null;
		if (first < 0x20 or first == 0x7f) {
			return null;
		}
		return text;
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
pub fn width(text: []const u8) usize {
	return vaxis.gwidth.gwidth(text, .unicode);
}

pub fn charWidth(point: u21) u8 {
	var buf: [4]u8 = undefined;
	const len = std.unicode.utf8Encode(point, &buf) catch return 1;
	return @intCast(@min(2, width(buf[0..len])));
}

/// The longest prefix of `text` that fits in `max` columns, plus its width.
pub fn fit(text: []const u8, max: usize) struct { text: []const u8, cols: usize } {
	var total: usize = 0;
	var end: usize = 0;
	// Grapheme clusters, so a cell is never cut in the middle of one.
	var it = vaxis.unicode.GraphemeIterator.init(text);
	while (it.next()) |cluster| {
		const slice = cluster.bytes(text);
		const w = width(slice);
		if (total + w > max) {
			break;
		}
		total += w;
		end += slice.len;
	}
	return .{ .text = text[0..end], .cols = total };
}
