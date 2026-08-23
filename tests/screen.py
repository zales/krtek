#!/usr/bin/env python3
"""Drive krtek in a pseudo terminal and render what it drew.

A terminal app is otherwise untestable without a human: this opens a pty of a
fixed size, feeds a key script, interprets the escape sequences the app emits
back into a character grid, and prints it. Useful both as a test and to see the
screen without a terminal.

usage: tests/screen.py <database> [keys ...]

Keys are given as literal text, or as names in braces:
{down} {up} {left} {right} {enter} {tab} {esc} {pgdn} {pgup} {home} {end}
{bs} {ctrl-x} {wait} {keep}
"""

import base64
import codecs
import os
import pty
import re
import select
import struct
import sys
import tempfile
import termios
import time
import fcntl

# The terminal this pretends to be. From the environment where a test needs a
# different shape - a list that scrolls needs a window shorter than the list.
ROWS = int(os.environ.get("SCREEN_ROWS", 32))
COLS = int(os.environ.get("SCREEN_COLS", 118))

NAMED = {
	"down": "\x1b[B",
	"up": "\x1b[A",
	"left": "\x1b[D",
	"right": "\x1b[C",
	"enter": "\r",
	"tab": "\t",
	"esc": "\x1b",
	"pgdn": "\x1b[6~",
	"pgup": "\x1b[5~",
	"home": "\x1b[H",
	"end": "\x1b[F",
	"bs": "\x7f",
}


class Style:
	"""What a cell looks like: colours as #rrggbb or None for the default."""

	__slots__ = ("fg", "bg", "ul", "bold", "dim", "italic", "underline", "reverse")

	def __init__(self, fg=None, bg=None, ul=None, bold=False, dim=False, italic=False, underline=False, reverse=False):
		self.fg, self.bg, self.ul = fg, bg, ul
		self.bold, self.dim, self.italic, self.underline, self.reverse = bold, dim, italic, underline, reverse

	def copy(self):
		return Style(self.fg, self.bg, self.ul, self.bold, self.dim, self.italic, self.underline, self.reverse)

	def after(self, params):
		"""This style with an SGR sequence applied. Truecolour arrives as
		38:2:r:g:b, which is why the parameters are not split on ';' alone."""
		out = self.copy()
		fields = [f for f in params.split(";")]
		i = 0
		while i < len(fields):
			field = fields[i]
			parts = field.split(":")
			code = parts[0]
			# 58 is the underline's own colour, which a form field uses to draw a
			# quiet line under text that stays bright.
			if code in ("38", "48", "58") and len(parts) >= 5 and parts[1] == "2":
				# 38:2:r:g:b, and also 58:2::r:g:b - the colour space the ITU form
				# puts between the 2 and the red is empty and has to be dropped.
				numbers = [p for p in parts[2:] if p != ""][:3]
				colour = "#%02x%02x%02x" % tuple(int(n) for n in numbers)
				setattr(out, {"38": "fg", "48": "bg", "58": "ul"}[code], colour)
				i += 1
				continue
			# The same, spelled with semicolons: 38;2;r;g;b
			if code in ("38", "48", "58") and i + 4 < len(fields) and fields[i + 1] == "2":
				colour = "#%02x%02x%02x" % tuple(int(fields[i + n] or 0) for n in (2, 3, 4))
				setattr(out, {"38": "fg", "48": "bg", "58": "ul"}[code], colour)
				i += 5
				continue
			if code in ("", "0"):
				out = Style()
			elif code == "1":
				out.bold = True
			elif code == "2":
				out.dim = True
			elif code == "3":
				out.italic = True
			elif code == "4":
				out.underline = True
			elif code == "7":
				out.reverse = True
			elif code == "22":
				out.bold = out.dim = False
			elif code == "23":
				out.italic = False
			elif code == "24":
				out.underline = False
			elif code == "27":
				out.reverse = False
			elif code == "39":
				out.fg = None
			elif code == "49":
				out.bg = None
			elif code == "59":
				out.ul = None
			i += 1
		return out


class Screen:
	"""Just enough of a terminal to reproduce what this app draws."""

	def __init__(self, rows, cols):
		self.rows, self.cols = rows, cols
		self.grid = [[" "] * cols for _ in range(rows)]
		# The colours and attributes of each cell, for tests/shot.py; the text
		# rendering below ignores them.
		self.styles = [[Style()] * cols for _ in range(rows)]
		self.style = Style()
		self.row = self.col = 0
		self.rest = ""
		self.clipboard = []   # whatever the app sent through OSC 52

	def feed(self, text):
		data = self.rest + text
		self.rest = ""
		i = 0
		while i < len(data):
			char = data[i]
			if char == "\x1b":
				# An OS command - a clipboard write, a colour query - is not drawn.
				osc = re.match(r"\x1b\](.*?)(?:\x07|\x1b\\)", data[i:], re.S)
				if osc:
					payload = osc.group(1)
					if payload.startswith("52;"):
						encoded = payload.split(";", 2)[-1]
						try:
							self.clipboard.append(base64.b64decode(encoded).decode("utf-8", "replace"))
						except Exception:
							pass
					i += osc.end()
					continue
				if re.match(r"\x1b\](?!.*(?:\x07|\x1b\\))", data[i:], re.S):
					self.rest = data[i:]   # an unfinished one, wait for the rest
					return
				# The optional group before the final byte is an intermediate, as in
				# the cursor shape sequence `CSI 0 SP q` - without it the shape
				# reset on exit would be drawn as the letter q.
				match = re.match(r"\x1b\[([0-9;:?<=>]*)[ !-/]*([A-Za-z@])", data[i:])
				if not match:
					if len(data) - i < 48:  # possibly a sequence split across reads
						self.rest = data[i:]
						return
					i += 1
					continue
				params, final = match.group(1), match.group(2)
				self.escape(params, final)
				i += match.end()
				continue
			if char == "\r":
				self.col = 0
			elif char == "\n":
				self.row = min(self.row + 1, self.rows - 1)
			elif char >= " ":
				if self.row < self.rows and self.col < self.cols:
					self.grid[self.row][self.col] = char
					self.styles[self.row][self.col] = self.style
				self.col += 1
			i += 1

	def escape(self, params, final):
		"""Only the sequences that move the cursor or erase matter here."""
		numbers = [int(p) for p in params.split(";") if p.isdigit()]
		# Truecolour SGR uses colons (38:2:r:g:b); nothing here needs its values.
		if final == "H":
			self.row = (numbers[0] - 1) if numbers else 0
			self.col = (numbers[1] - 1) if len(numbers) > 1 else 0
			self.row = max(0, min(self.row, self.rows - 1))
			self.col = max(0, min(self.col, self.cols - 1))
		elif final in "ABCD":
			# Relative moves; a damage-tracking renderer skips unchanged cells
			# with these instead of repositioning absolutely.
			step = numbers[0] if numbers else 1
			if final == "A":
				self.row = max(0, self.row - step)
			elif final == "B":
				self.row = min(self.rows - 1, self.row + step)
			elif final == "C":
				self.col = min(self.cols - 1, self.col + step)
			else:
				self.col = max(0, self.col - step)
		elif final == "G":
			self.col = max(0, min((numbers[0] - 1) if numbers else 0, self.cols - 1))
		elif final == "d":
			self.row = max(0, min((numbers[0] - 1) if numbers else 0, self.rows - 1))
		elif final == "K":
			if self.row < self.rows:
				for c in range(self.col, self.cols):
					self.grid[self.row][c] = " "
					self.styles[self.row][c] = self.style
		elif final == "J":
			self.grid = [[" "] * self.cols for _ in range(self.rows)]
			self.styles = [[Style()] * self.cols for _ in range(self.rows)]
		elif final == "m":
			self.style = self.style.after(params)
		# Cursor visibility and the alternate screen change nothing here.

	def text(self):
		return "\n".join("".join(row).rstrip() for row in self.grid)


BINARY = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "zig-out/bin/krtek")


def run(database, script):
	# A configuration of this test's own, unless whoever called set one up. The
	# app remembers every connection it opens, so a test that opened one wrote
	# into the list somebody actually uses - which is where `sftp://foo@…:2222`
	# and `%2F` came from in a real person's saved connections.
	if not os.environ.get("XDG_CONFIG_HOME"):
		os.environ["XDG_CONFIG_HOME"] = tempfile.mkdtemp(prefix="krtek-screen-")

	pid, fd = pty.fork()
	if pid == 0:
		os.execv(BINARY, ["krtek", database])
	fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

	screen = Screen(ROWS, COLS)
	# Set SCREEN_RAW=<path> to keep the escape sequences themselves, which is how
	# colours and other attributes get checked - the grid only holds characters.
	raw_path = os.environ.get("SCREEN_RAW")
	raw = open(raw_path, "wb") if raw_path else None
	# Incremental, because a chunk can end in the middle of a character - decoding
	# each chunk on its own would turn box drawing into replacement marks.
	decoder = codecs.getincrementaldecoder("utf-8")("replace")

	def drain(seconds=0.35):
		deadline = time.time() + seconds
		while time.time() < deadline:
			ready, _, _ = select.select([fd], [], [], 0.05)
			if not ready:
				continue
			try:
				chunk = os.read(fd, 65536)
			except OSError:
				return False
			if not chunk:
				return False
			if raw:
				raw.write(chunk)
			if b"\x1b[5n" in chunk:
				# A status report. Vaxis writes one to wake its reader thread when it
				# stops, so an unanswered DSR means the app never finishes exiting.
				os.write(fd, b"\x1b[0n")
			screen.feed(decoder.decode(chunk))
		return True

	drain(0.6)
	keep = False
	for key in script:
		if key == "{sleep}":
			drain(0.6)
			continue
		if key == "{keep}":
			keep = True  # leave the last state on screen instead of quitting
			continue
		os.write(fd, key.encode("utf-8"))
		drain()
	if keep:
		os.kill(pid, 9)
	else:
		# Escape first: inside a form or a prompt ctrl+c only cancels it.
		os.write(fd, b"\x1b")
		drain(0.1)
		os.write(fd, b"\x03")
		drain(0.2)
	try:
		os.close(fd)
	except OSError:
		pass
	os.waitpid(pid, 0)
	if raw:
		raw.close()
	out = screen.text()
	for copied in screen.clipboard:
		out += "\nCLIPBOARD: " + copied.replace("\n", "\\n").replace("\t", "\\t")
	return out


def parse(arguments):
	"""Turn the command line into a list of key strings."""
	out = []
	for argument in arguments:
		i = 0
		while i < len(argument):
			if argument[i] == "{":
				end = argument.index("}", i)
				name = argument[i + 1 : end]
				if name.startswith("ctrl-"):
					out.append(chr(ord(name[5]) & 0x1F))
				elif name in ("wait", "sleep"):
					out.append("{sleep}")
				elif name == "keep":
					out.append("{keep}")
				else:
					out.append(NAMED[name])
				i = end + 1
			else:
				out.append(argument[i])
				i += 1
	return out


if __name__ == "__main__":
	if len(sys.argv) < 2:
		print(__doc__)
		sys.exit(2)
	print(run(sys.argv[1], parse(sys.argv[2:])))
