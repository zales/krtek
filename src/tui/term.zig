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
};

pub const Scheme = enum { dark, light };

/// True colour for the entries the interface uses, in both schemes; anything
/// else keeps the palette index, so neither mapping has to be complete.
///
/// The drawing code names roles, not colours - `C.accent`, `C.bar` - and those
/// names are palette indexes, so a whole theme is one table here. Index 16 is
/// the odd one out: it is the text drawn *on* an accent background, so it has to
/// go the other way from everything else.
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
			240 => .{ .rgb = .{ 0x50, 0x50, 0x5a } }, // faint
			242 => .{ .rgb = .{ 0x62, 0x62, 0x6c } }, // null
			245 => .{ .rgb = .{ 0x8a, 0x8a, 0x94 } }, // dim
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
			240 => .{ .rgb = .{ 0x9a, 0x9a, 0xa4 } }, // faint
			242 => .{ .rgb = .{ 0x88, 0x88, 0x92 } }, // null
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

pub const Term = struct {
	allocator: std.mem.Allocator,
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

	pub fn init(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) !*Term {
		const self = try allocator.create(Term);
		errdefer allocator.destroy(self);
		const buffer = try allocator.alloc(u8, 64 * 1024);
		self.* = .{
			.allocator = allocator,
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

	// --- input ---

	/// Wait for something to happen, then take whatever else is already queued.
	pub fn keys(self: *Term, out: *std.ArrayListUnmanaged(Key)) !void {
		out.clearRetainingCapacity();
		var first = true;
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
