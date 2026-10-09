# Known issues

Bugs that are known and not fixed yet. Each says how to see it, where it comes
from and what the fix would be. Delete an entry in the commit that fixes it.

The one below was found on 2026-10-04 by a review of the fix for text that is not
UTF-8 ("A value that is not UTF-8 is drawn a U+FFFD a byte, and stays in its
column"), by reading the code. It was not reproduced in a pty: `tests/screen.py`
puts every character in one cell, so it cannot show it.

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
