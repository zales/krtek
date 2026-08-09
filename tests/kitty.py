#!/usr/bin/env python3
"""Drive krtek the way a terminal with the kitty keyboard protocol does.

Ghostty, Kitty and WezTerm report keys as the *unshifted* key plus a modifier:
shift+s arrives as `CSI 115:83 ; 2 u`, not as the byte `S`. A plain pty sends the
finished byte instead, so screen.py cannot see anything that depends on shift -
which is exactly where a keyboard bug hides. This sends the CSI u form.

usage: tests/kitty.py <database> [keys ...]

A key is a literal character - upper case and the shifted symbols below are sent
as shift plus the unshifted key - or a name in braces, the same ones screen.py
takes.
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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from screen import ROWS, COLS, Screen, parse

# What the US layout produces with shift held, so the unshifted key can be found.
# The keys a terminal reports out of the private use area: a modifier pressed on
# its own, and the functional keys. `{shift}` is the one that used to type a
# character out of that block.
FUNCTIONAL = {
	"shift": 57441,
	"control": 57442,
	"alt": 57443,
	"super": 57444,
	"caps": 57358,
	"f13": 57376,
	"kp0": 57399,
	"kpenter": 57414,
	"kpright": 57418,
	"kpdown": 57420,
	"play": 57428,
}

SHIFTED = {
	"!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
	"*": "8", "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]",
	"|": "\\", ":": ";", '"': "'", "<": ",", ">": ".", "?": "/", "~": "`",
}


def csi_u(char):
	"""One key press, in the kitty encoding.

	The third field is the text the key produced, which is what a terminal sends
	when the application asks for text reporting - krtek does, through vaxis.
	"""
	if char.isupper():
		return "\x1b[%d:%d;2;%du" % (ord(char.lower()), ord(char), ord(char))
	if char in SHIFTED:
		return "\x1b[%d:%d;2;%du" % (ord(SHIFTED[char]), ord(char), ord(char))
	return "\x1b[%d;;%du" % (ord(char), ord(char))


def steps_from(arguments):
	"""The command line, as kitty sequences.

	`{...}` is a named key: the ones in FUNCTIONAL are sent as their private-use
	codepoint, the rest are whatever screen.py already sends for them. Everything
	else is one key press each, shift included where the character needs it.
	"""
	out = []
	for argument in arguments:
		i = 0
		while i < len(argument):
			if argument[i] == "{":
				stop = argument.index("}", i)
				name = argument[i + 1 : stop]
				if name in FUNCTIONAL:
					out.append("\x1b[%d;1u" % FUNCTIONAL[name])
				else:
					out.extend(parse(["{" + name + "}"]))
				i = stop + 1
			else:
				out.append(csi_u(argument[i]) if argument[i].isprintable() else argument[i])
				i += 1
	return out


def run(target, steps):
	pid, fd = pty.fork()
	if pid == 0:
		os.execv(
			os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "zig-out/bin/krtek"),
			["krtek", target],
		)
	fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
	screen = Screen(ROWS, COLS)
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
				return
			if not chunk:
				return
			if b"\x1b[5n" in chunk:
				os.write(fd, b"\x1b[0n")
			screen.feed(decoder.decode(chunk))

	drain(0.8)
	for step in steps:
		if step == "{sleep}":
			drain(0.6)
			continue
		if step == "{keep}":
			continue  # the screen is always kept here
		os.write(fd, step.encode())
		drain()
	os.kill(pid, 9)
	os.close(fd)
	os.waitpid(pid, 0)
	out = screen.text()
	for copied in screen.clipboard:
		out += "\nCLIPBOARD: " + copied.replace("\n", "\\n").replace("\t", "\\t")
	return out


if __name__ == "__main__":
	if len(sys.argv) < 2:
		print(__doc__)
		sys.exit(2)
	print(run(sys.argv[1], steps_from(sys.argv[2:])))
