# krtek

[![build](https://github.com/zales/krtek/actions/workflows/ci.yml/badge.svg)](https://github.com/zales/krtek/actions/workflows/ci.yml)

A database manager for the terminal, written in Zig, with the feature set of
[Adminer](https://www.adminer.org) mapped onto what a text screen can do.
**SQLite, PostgreSQL, MySQL/MariaDB and Redis**, behind one interface.

*Krtek* is Czech for a mole: a small thing that digs through what is underneath
and comes back up with what it found.

Written for the terminals people actually use: under the kitty keyboard protocol
(Ghostty, Kitty, WezTerm) a key press reports the *unshifted* key plus a
modifier, so what a key produced is read from the text the terminal reports, not
from the key code - otherwise every capital letter and every shifted symbol
arrives wrong.

A [release](https://github.com/zales/krtek/releases/latest) has a binary for
macOS and Linux, on both architectures, and it **needs nothing installed**:
SQLite, libpq, the MariaDB connector and OpenSSL are linked into it, and Redis is
spoken directly, so only the operating system's own libraries are left dynamic.

Building it yourself needs those libraries present - see below - and
`-Dstatic` is what puts them inside the binary.

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/krtek              # the list of saved connections
./zig-out/bin/krtek database.db
./zig-out/bin/krtek postgres://user@host:5432/database
./zig-out/bin/krtek mysql://user@host:3306/database
./zig-out/bin/krtek redis://host:6379/0
```

A SQLite file is opened through SQLite's own VFS: edits go straight to disk and
there is nothing to save.

**Connections are saved**, and started with no argument the app opens the list of
them: `enter` connects, `a` adds, `e` edits, `d` removes. The file is
`~/.config/krtek/connections`, one `name<TAB>target` line per connection, readable
and editable by hand.

**Where a password is kept is chosen per connection**, in the connection form:

| | what happens | where it lives |
| --- | --- | --- |
| `ask` | the default: asked when the server asks, used once, forgotten | nowhere |
| `file` | the connection stops asking | `password=…` on its line, **plain text**, file mode 0600 |
| `keychain` | the connection stops asking; macOS guards it | the login keychain, service `krtek`, account = the target |

The list says which is which, so it is never a surprise. Leave the field empty and
the place set, and the password is asked for once and then kept there.

`keychain` is the better of the two on a Mac: nothing is on disk in the clear, and
macOS decides whether to hand it over. **It will ask you the first time each build
of `krtek` reads an item**, because a keychain item remembers which binary created
it and a rebuilt binary is a different one; "Always Allow" settles it for that
binary. If you refuse, the app falls back to asking for the password itself.

Where an engine has its own password store - `~/.pgpass` for libpq, `~/.my.cnf`
for MySQL, `PGPASSWORD` in the environment - that is better still, and it keeps
working either way.

**Nothing is only discoverable by reading the key map.** `ctrl+k` opens a command
palette: type a few words of what you want - `dro tab`, `expo`, `vacuum` - and it
lists what matches with the letters that matched underlined, each with the key
that does it, so using it teaches the keys. The same fuzzy match filters the
object list, so `ordit` finds `order_items`. The line at the bottom of the screen
shows what is worth pressing in the pane you are actually in, and an empty table
says how to put something in it.

**It fits the terminal it is in.** It asks whether the background is light or
dark and colours itself accordingly, and follows a theme switch while
running; `KRTEK_THEME=light` or `=dark` settles it by hand. Copying goes through
OSC 52, so `C` then `c`, `r`, `p` or `s` puts the value, the row, the page as CSV
or the last statement in the system clipboard - over ssh and inside tmux too,
because there is no local clipboard involved. Where the terminal can draw images
(Kitty, Ghostty, WezTerm), an image BLOB is shown as the image; everywhere else,
and for any other BLOB, as hex with its printable characters beside it.

**A statement can be given up on.** Anything that takes more than a moment puts a
spinner and a running time at the bottom, and `ctrl+c` stops it: SQLite's virtual
machine is halted through its progress handler, PostgreSQL gets a cancel request
on its own socket, MySQL a `KILL QUERY` down a second connection while the first
waits through the connector's non-blocking calls. The connection stays usable, and
a batch stops at the statement that was interrupted.

## Redis

Redis is not relational and the driver does not pretend otherwise. It maps onto
the interface the way Adminer's own Redis plugin does: one table called `data`
whose columns are `key`, `type`, `ttl` and `value`, rows found with `SCAN`, and
the numbered databases as schemas, so `#` moves between them. A value is shown as
its type allows - a string as it is, a list or set as its elements, a hash as
`field=value` - and editing a cell writes `SET`, editing the ttl writes `EXPIRE`
or `PERSIST`, deleting a row writes `DEL`. Filtering the key with `W` becomes the
`MATCH` pattern of the scan, `%` and `_` translated to `*` and `?`.

There is no DDL: `c`, `a`, `I`, `K`, `V` and `T` answer with the reason instead of
writing SQL that could not work, and `D` is `FLUSHDB`. Searching every table is
refused, because there is only one. **The SQL editor is a Redis console** - `KEYS
user:*`, `HGETALL cart:7`, `INFO memory`, `TTL greeting` - and that is where
anything this mapping does not cover belongs.

The protocol is spoken directly: RESP is a handful of prefixes, so there is no
client library, no dependency and no licence to think about.

## Adding an engine

`src/db/db.zig` is the interface. It is a tagged union dispatched with `inline
else`, so a new engine is one union member and a struct with the same method
names - anything missing is a compile error that names itself. No vtables.

```zig
pub const Db = union(enum) {
	sqlite: *sqlite.Db,
	postgres: *postgres.Db,

	pub fn columns(self: Db, arena: std.mem.Allocator, table: Table) Error![]Column {
		switch (self) {
			inline else => |driver| return driver.columns(arena, table),
		}
	}
};
```

The rule the drivers keep: everything engine specific stays behind `src/db/`.
The interface knows about objects, columns, indexes, keys and row identity; it
does not know what a `PRAGMA` or a `pg_catalog` is. What differs is declared as
capabilities - PostgreSQL has schemas and alters in place, SQLite has a `rowid`
and has to rebuild a table - and the interface asks for those instead of
guessing.

## Build

Zig fetches libvaxis itself, from `build.zig.zon`.

```sh
./fetch-sqlite.sh   # download the SQLite amalgamation into vendor/
zig build           # zig-out/bin/krtek (needs Zig 0.16 and libpq)
zig build run -- x.db
zig build test      # unit tests
tests/screen.py x.db '{down}{enter}' 'oo'   # drive it headlessly, see below
zig build dbcheck -- mysql://…            # talk to a server, without the interface
zig build kccheck                        # check the macOS keychain, by hand
```

Both client libraries are keg-only on Homebrew; `-Dlibpq=/prefix` and
`-Dmariadb=/prefix` point the build at them if they live somewhere other than
`/opt/homebrew/opt/libpq` and `/opt/homebrew/opt/mariadb-connector-c`, and
`-Dopenssl=` does the same for OpenSSL. The MariaDB connector speaks to MySQL as
well, and its licence lets a program that is not GPL link it - Oracle's own client
library does not.

`-Dstatic` links libpq, the connector and OpenSSL into the binary, leaving only
the operating system's libraries dynamic - Kerberos, LDAP, curl and zlib on macOS,
libc and the same few on Linux. That is what a release is built with. It is not
one `-l` per library: a static libpq also wants `libpq-oauth.a` and the *`_shlib`*
variants of `libpgcommon` and `libpgport`, because the plain ones are built
differently from the libpq that references them.

## What it does

Everything is reachable from the key map, which `?` prints in full.

**Getting in.** A list of saved connections with the engine and target of each,
added and edited in a form; a password prompt that echoes nothing when the server
wants one.

**Browsing.** Object list with row counts and a filter (PostgreSQL's estimate is
replaced with an exact count), a data grid with paging,
sorting, horizontal scrolling, a detail box for the whole value, and a structure
view with columns, indexes, foreign keys and the `CREATE` statement. Column
visibility and a filter of up to three conditions plus a raw `WHERE`. Database
info - pragmas and an integrity check on SQLite, server settings and size on
PostgreSQL - and a list of every relation.

**Rows.** A form to insert, edit or clone a row - typing a value clears its NULL
box - plus quick in-place editing of a single cell, row marking, and deletion of
everything marked.

**Schema.** Create a table, alter one, add an index or a foreign key, create a
view or a trigger, rename, copy, empty or drop. `#` switches schema on PostgreSQL
and database on MySQL, which is the same thing there. The type list in a form is
the engine's own: `varchar(255)` on MySQL, `timestamptz` on PostgreSQL.

How an alter happens is the engine's business. PostgreSQL alters in place, one
`ALTER TABLE` per difference; MySQL does too, with `CHANGE COLUMN`, which renames
and retypes in one go. SQLite can only add, rename and drop a column, so
anything else - a type, a default, a primary key, a foreign key - is done by
[rebuilding the table](https://sqlite.org/lang_altertable.html): a new table, the
rows copied over, the old name put back, the foreign keys carried across and the
indexes regenerated from their metadata with the column renames applied, so
renaming a column does not break them.

**Data.** A SQL editor - several lines, keywords, strings, numbers and comments in
colour, `tab` completing table and column names from a list under the cursor,
`ctrl+p` walking the history - that runs several statements and reports each
one on its own, search across every text column of every table, export as an SQL
dump (whole database or one table, structure and/or data) or CSV/TSV, and import
of an SQL script or a CSV file. Commands: `:export`, `:dump`, `:limit`, `:text`,
`:open`, `:check`, `:analyze`, `:vacuum`, `:q`.

A batch behaves like Adminer's: each statement is reported separately, and a
batch that leaves a transaction open is rolled back. A generated schema change
stops at the first error, so its own `COMMIT` can never make half a rebuild
permanent.

## How it is put together

| File | Role |
| --- | --- |
| `src/db/db.zig` | the interface, the shared quoting and the statement splitter |
| `src/db/sqlite.zig` | the SQLite driver: pragmas and the table rebuild |
| `src/db/postgres.zig` | the PostgreSQL driver over libpq, single-row mode |
| `src/db/mysql.zig` | the MySQL and MariaDB driver over the MariaDB connector |
| `src/db/redis.zig` | the Redis driver: RESP straight over a socket, no library |
| `src/sqlite.zig` | the SQLite C declarations |
| `src/tui/term.zig` | the terminal: a thin adapter over libvaxis |
| `src/tui/app.zig` | state, the loaded page, and everything that runs SQL |
| `src/tui/editor.zig` | the SQL editor and the tokenizer that colours it |
| `src/tui/fuzzy.zig` | the fuzzy match shared by the palette and the filter |
| `src/tui/form.zig` | the form widget every dialog is built from |
| `src/tui/csv.zig` | reading and writing delimited files |
| `src/tui/draw.zig` | rendering |
| `src/tui/input.zig` | the key map and the command palette |
| `src/tui/connections.zig` | the saved connections and where each keeps its password |
| `src/tui/keychain.zig` | the macOS keychain, through Security.framework |
| `vendor/sqlite3.c` | the unmodified SQLite amalgamation, compiled by Zig's clang |

The libraries are SQLite (compiled in), libpq (linked) and
[libvaxis](https://github.com/rockorager/libvaxis) for the terminal, which brings
true colour, grapheme aware widths, the kitty keyboard protocol, bracketed paste
and the mouse. Every frame is drawn in full and vaxis writes out only the cells
that changed; a resize arrives as an event, so there is no polling and no signal
handler.

## Testing it

A terminal app cannot be checked by a human on every change, so
[tests/screen.py](tests/screen.py) runs the binary in a pseudo terminal, feeds it
keys and renders the escape sequences it emits back into a character grid:

```sh
tests/screen.py x.db '{down}{enter}' 'oo' 'n'            # open a table, sort, page
tests/screen.py x.db 'c' 'notes' '{ctrl-s}'              # create a table
tests/screen.py x.db 'i' '{down}{down}hello' '{ctrl-s}'  # insert a row
tests/screen.py x.db '?' '{keep}'                        # leave the screen as it is
tests/screen.py '' '{keep}'                              # the connection list
tests/screen.py x.db '{ctrl-k}' 'dro tab' '{keep}'       # the command palette
tests/screen.py x.db 's' 'select 1' '{ctrl-s}'           # write SQL and run it
tests/kitty.py  x.db 'S' 'Cr'                            # keys as Ghostty sends them
tests/kitty.py  x.db '{shift}{f13}{kpdown}'               # keys that are not text
tests/screen.py x.db '{tab}' 'Cc' | grep CLIPBOARD       # what a copy key sent
SCREEN_RAW=/tmp/raw.bin tests/screen.py x.db '{keep}'    # keep the escapes too
```

[tests/kitty.py](tests/kitty.py) drives the same binary but sends keys the way a
terminal with the kitty keyboard protocol does - `shift+s` as `CSI 115:83;2;83u`
rather than as the byte `S`, and `{shift}`, `{f13}` or `{kpdown}` as the private
use codepoints that protocol gives to keys which are not text. A plain pty cannot
express either difference, and both are where keyboard bugs live.

That is how everything described here was verified: against a real SQLite file
with `sqlite3` reading the result back, and against a PostgreSQL 17 container
with `psql` doing the same.

## Deliberate limitations

* **No undo.** The file is edited in place, like any other database client, so
  `:dump` before a risky change.
* **A rebuild cannot recover what the pragmas do not report:** `CHECK`
  constraints, generated columns and collations are lost when a table is altered.
  The form says so. Adminer has the same limitation on SQLite.
* **A trigger is replayed as its own text**, so renaming a column a trigger
  mentions makes the alter fail - safely, with a rollback and the failing
  statement in the report. Drop the trigger, alter, recreate it.
* **Editing a row needs a way to identify it:** SQLite's `rowid`, or a primary
  key or unique index over NOT NULL columns. A view, a PostgreSQL table without a
  key, and anything joined are read-only. PostgreSQL's `ctid` is deliberately not
  used as a key, because it moves on UPDATE.
* **The editor has no undo and no selection.** It is meant for writing a
  statement, not for editing prose: `ctrl+w` takes back a word, `ctrl+u` the lot.
* **Completion offers names, not structure.** Table names, the columns of the
  table on screen, and SQL's own words - it does not know which table a column
  belongs to, so it cannot narrow `t.` down to that table's columns.
* **A long statement blocks the interface** while it runs, apart from the spinner
  and `ctrl+c`: the engine is called synchronously, and keys that arrive while it
  is running are dropped rather than queued.
* **MySQL runs in `ANSI_QUOTES,NO_BACKSLASH_ESCAPES`**, so that one shared
  quoting is right for all three engines. A statement you write yourself is
  affected: `"a"` is an identifier, not a string.
* **Users and privileges, and the process list** are not there on either engine.
* **A dump does not include triggers**, because it is written from the interface,
  which reports tables, views and indexes.
* **Redis is mapped, not modelled.** The interface asks for rows in SQL, so the
  driver recognises the four shapes this app itself writes - SELECT, UPDATE,
  INSERT, DELETE over `data` - and passes everything else to Redis as a command.
  It is not a SQL parser and does not try to be. If another engine like this
  appears, the interface should grow a non-SQL path instead of each such driver
  growing a recogniser.
* **PostgreSQL specifics not covered:** `COPY`, `EXPLAIN ANALYZE`, sequences as
  objects of their own, materialized view refresh, and switching database
  without reconnecting (`:open` takes a whole target).

## Licence

`vendor/sqlite3.c` is public domain.
