#!/usr/bin/env python3
"""Take a screenshot of krtek as an SVG.

The pty harness already reproduces what the app drew, colours included, so a
screenshot is that grid written out as text on coloured rectangles - no screen
capture, no photograph of a terminal, and small enough to keep in the repository
and regenerate whenever the interface changes.

usage: tests/shot.py <out.svg> <database> [keys ...]

The keys are the ones tests/screen.py takes. `{keep}` is implied: a screenshot is
of the last frame.
"""

import codecs
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time
import xml.sax.saxutils as escaping

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from screen import BINARY, Screen, Style, parse

# The default palette of the terminal the shot pretends to be: krtek asks for the
# background colour and draws its dark theme when it does not hear otherwise.
BACKGROUND = "#111114"
FOREGROUND = "#e0e0e6"

CELL_W = 8.4
CELL_H = 18.0
PADDING = 14.0
FONT = 13.0
FAMILY = "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"


def capture(target, keys, rows, cols):
	"""Run the app, feed it the keys, and hand back the screen it ended on."""
	pid, fd = pty.fork()
	if pid == 0:
		os.execv(BINARY, ["krtek", target])
	fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
	screen = Screen(rows, cols)
	decoder = codecs.getincrementaldecoder("utf-8")("replace")

	def drain(seconds):
		deadline = time.time() + seconds
		while time.time() < deadline:
			ready, _, _ = select.select([fd], [], [], 0.05)
			if not ready:
				continue
			try:
				chunk = os.read(fd, 65536)
			except OSError:
				return
			if not chunk:
				return
			if b"\x1b[5n" in chunk:
				os.write(fd, b"\x1b[0n")
			screen.feed(decoder.decode(chunk))

	drain(1.0)
	for key in keys:
		if key in ("{sleep}", "{keep}"):
			drain(0.8)
			continue
		os.write(fd, key.encode())
		drain(0.45)
	drain(0.4)
	os.kill(pid, 9)
	os.close(fd)
	os.waitpid(pid, 0)
	return screen


def colours(style):
	"""What this cell's ink and paper actually are, reverse video included."""
	fg = style.fg or FOREGROUND
	bg = style.bg or BACKGROUND
	if style.reverse:
		fg, bg = bg, fg
	if style.dim and not style.fg:
		fg = "#8a8a94"
	return fg, bg


def runs(row, styles):
	"""The row as pieces that share a look, so the SVG is spans and not cells."""
	out = []
	for column, char in enumerate(row):
		style = styles[column]
		fg, bg = colours(style)
		key = (fg, bg, style.bold, style.italic, style.underline, style.ul or fg)
		if out and out[-1][0] == key and out[-1][2] + len(out[-1][1]) == column:
			out[-1][1] += char
		else:
			out.append([key, char, column])
	return out


def svg(screen):
	rows, cols = screen.rows, screen.cols
	width = cols * CELL_W + 2 * PADDING
	height = rows * CELL_H + 2 * PADDING
	parts = [
		'<svg xmlns="http://www.w3.org/2000/svg" width="%.0f" height="%.0f" '
		'viewBox="0 0 %.0f %.0f" font-family="%s" font-size="%.1f">'
		% (width, height, width, height, FAMILY, FONT),
		'<rect width="100%%" height="100%%" rx="8" fill="%s"/>' % BACKGROUND,
	]
	# The paper first, all of it, then the ink: fewer, larger shapes.
	for r in range(rows):
		for (key, text, column) in runs(screen.grid[r], screen.styles[r]):
			bg = key[1]
			if bg == BACKGROUND:
				continue
			parts.append(
				'<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s"/>'
				% (PADDING + column * CELL_W, PADDING + r * CELL_H, len(text) * CELL_W + 0.5, CELL_H, bg)
			)
	for r in range(rows):
		baseline = PADDING + r * CELL_H + CELL_H * 0.74
		for (key, text, column) in runs(screen.grid[r], screen.styles[r]):
			fg, _, bold, italic, underline, ul = key
			# An underline drawn as a rule of its own, because a form field is a
			# line under the spaces where nothing has been typed yet - and a text
			# element with nothing but spaces in it draws no underline at all.
			if underline:
				parts.append(
					'<rect x="%.1f" y="%.1f" width="%.1f" height="1.1" fill="%s"/>'
					% (PADDING + column * CELL_W, baseline + 2.4, len(text) * CELL_W, ul)
				)
			if not text.strip():
				continue
			attributes = ['x="%.1f"' % (PADDING + column * CELL_W), 'y="%.1f"' % baseline, 'fill="%s"' % fg]
			if bold:
				attributes.append('font-weight="600"')
			if italic:
				attributes.append('font-style="italic"')
			# Every glyph on the grid, or a proportional fallback font would drift.
			attributes.append('xml:space="preserve"')
			attributes.append('textLength="%.1f"' % (len(text) * CELL_W))
			attributes.append('lengthAdjust="spacing"')
			parts.append("<text %s>%s</text>" % (" ".join(attributes), escaping.escape(text)))
	parts.append("</svg>")
	return "\n".join(parts)


def trim(screen):
	"""Drop the empty rows at the bottom, so a short screen is a short picture."""
	last = 0
	for r in range(screen.rows):
		if "".join(screen.grid[r]).strip():
			last = r
	screen.rows = last + 1
	screen.grid = screen.grid[: screen.rows]
	screen.styles = screen.styles[: screen.rows]
	return screen


if __name__ == "__main__":
	if len(sys.argv) < 3:
		print(__doc__)
		sys.exit(2)
	out, target = sys.argv[1], sys.argv[2]
	rows = int(os.environ.get("SHOT_ROWS", "26"))
	cols = int(os.environ.get("SHOT_COLS", "104"))
	shot = trim(capture(target, parse(sys.argv[3:]), rows, cols))
	with open(out, "w", encoding="utf-8") as file:
		file.write(svg(shot))
	print("%s  %d rows, %d columns" % (out, shot.rows, cols))
