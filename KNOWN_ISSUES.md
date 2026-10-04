# Known issues

Bugs that are known and not fixed yet. Each says how to see it, where it comes
from and what the fix would be. Delete an entry in the commit that fixes it.

Both below were found on 2026-10-04 by a review of the fix for text that is not
UTF-8 ("A value that is not UTF-8 is drawn a U+FFFD a byte, and stays in its
column"), by reading the code. Neither was reproduced in a pty: `tests/screen.py`
puts every character in one cell, so it cannot show either.

## An emoji is laid out at one width and drawn at another on some terminals

**What it looks like.** A row with an emoji built of more than one code point -
`❤️` (U+2764 U+FE0F), `👍🏽` with a skin tone, `👩‍🚀` joined with U+200D - pushes the
rest of its line sideways: the next column of the grid starts in the wrong
place, and the row form or `gv` loses its right border on that line. The
symptom the fix above removed for bytes that are not UTF-8, here with valid
text.

**How to see it.** In a terminal that does not answer the query for mode 2027
(Apple Terminal is one), open a table with `❤️ heart` in one row and `plain`
in the next, and look at whether the column after it lines up.

**Why.** `term.width` measures with `vaxis.gwidth.gwidth(text, .unicode)`: a
grapheme cluster is one width. `Term.put` draws through vaxis' `printSegment`,
which measures with `screen.width_method` - `.wcwidth` (`Screen.zig:25`) unless
the terminal says it does mode 2027 (`Vaxis.zig:210`, `:363-376`). Under
`.wcwidth` a cluster is the sum of its code points: `❤️` is 1 where the layout
counted 2, `👍🏽` is 4, a family joined with U+200D is 6.

**The fix.** Measure with the method vaxis draws with: keep the method
`term.width` passes in step with `vx.screen.width_method`, set after
`queryTerminal` and whenever the capabilities change. Or set the screen to
`.unicode` after `queryTerminal`, so the cell model and the layout agree and
the terminal is trusted to draw clusters. About an hour, most of it deciding
which, and a check in Apple Terminal and in one that does mode 2027.

## The cursor of a password prompt is not after its last dot

**What it looks like.** Typing a password with a character that is not one
column wide - `日` is two, `e` with U+0301 after it is one column of two code
points - leaves the cursor in the middle of the dots, or past them.

**How to see it.** Connect to a server that asks for a password and type `日本`:
four dots, with the cursor after the second.

**Why.** `promptLine` (`src/tui/draw.zig`) draws one dot per column of
`term.width(prompt.buffer.items)`, and `cursorAndFlush` puts the cursor at
`utf8CountCodepoints` of the same buffer - one per code point.

**The fix.** Count the same thing in both: one dot per code point, which also
says nothing about how wide the characters are. About 15 minutes with a test.
