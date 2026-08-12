# krtek

[![build](https://github.com/zales/krtek/actions/workflows/ci.yml/badge.svg)](https://github.com/zales/krtek/actions/workflows/ci.yml)

A database manager for the terminal, written in Zig: what a graphical client
does - browse, edit, alter, dump, import - on a text screen, and quicker, because
everything is a key press. **SQLite, PostgreSQL, MySQL/MariaDB, Redis, Kafka, S3
and RabbitMQ**, behind one interface.

*Krtek* is Czech for a mole: a small thing that digs through what is underneath
and comes back up with what it found.

![browsing a table](docs/grid.svg)

Written for the terminals people actually use: under the kitty keyboard protocol
(Ghostty, Kitty, WezTerm) a key press reports the *unshifted* key plus a
modifier, so what a key produced is read from the text the terminal reports, not
from the key code - otherwise every capital letter and every shifted symbol
arrives wrong.

## Installing it

```sh
brew install zales/krtek/krtek                    # macOS and Linux
sudo apt install krtek                            # Debian, Ubuntu - after the two lines below
tar xzf krtek-*.tar.gz && ./krtek-*/krtek         # anything else
```

Debian and Ubuntu have an APT repository, so `apt upgrade` keeps krtek up to date
like anything else:

```sh
sudo install -d /etc/apt/keyrings
sudo curl -fsSLo /etc/apt/keyrings/krtek.gpg https://zales.github.io/krtek/krtek-archive-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/krtek.gpg] https://zales.github.io/krtek ./" | sudo tee /etc/apt/sources.list.d/krtek.list
sudo apt update && sudo apt install krtek
```

The metadata is signed, so apt checks it the way it checks any other repository -
no `trusted=yes` anywhere. [.github/workflows/apt.yml](.github/workflows/apt.yml)
signs `Release`, publishes the public key beside it, and verifies its own signature
before it goes out, because a repository whose signature does not check out breaks
`apt update` for everyone who already trusts the key.

That repository is [GitHub Pages](https://zales.github.io/krtek), built from the
`.deb` files attached to the releases rather than from a build, so it can be
regenerated at any time and it keeps the older versions: `apt install krtek=0.4.0-1`
works. Every [release](https://github.com/zales/krtek/releases/latest) also has the
`.tar.gz`, the `.deb` and the Homebrew formula for macOS and Linux on both
architectures. The `.deb` installs the binary, the man page and the copyright, and
**Depends on nothing at all**, so it goes on any Debian or Ubuntu of any age.

**It needs nothing installed.** SQLite, libpq, the MariaDB connector and OpenSSL
are linked into the binary, and Redis, Kafka, S3 and RabbitMQ are spoken
directly. The Linux
builds are static against musl and run on any distribution - checked on Debian with nothing
installed at all; the macOS builds leave only Apple's own libraries dynamic. That
is `-Dstatic`.

Or from source, which needs nothing but Zig 0.16:

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/krtek              # the list of saved connections
./zig-out/bin/krtek database.db
./zig-out/bin/krtek postgres://user@host:5432/database
./zig-out/bin/krtek mysql://user@host:3306/database
./zig-out/bin/krtek redis://host:6379/0
./zig-out/bin/krtek kafka://host:9092
./zig-out/bin/krtek s3://bucket
./zig-out/bin/krtek s3+http://key:secret@localhost:9000/bucket
./zig-out/bin/krtek rabbit://guest@host:15672/vhost
```

A SQLite file is opened through SQLite's own VFS: edits go straight to disk and
there is nothing to save.

**Connections are saved**, and started with no argument the app opens the list of
them: `enter` connects, `a` adds, `e` edits, `d` removes. The file is
`~/.config/krtek/connections`, one `name<TAB>target` line per connection, readable
and editable by hand.

**Adding one asks which engine first**, and the fields under it are that engine's:
a host and a database for PostgreSQL, a bucket and a region for S3, a vhost for
RabbitMQ, a file for SQLite. Nobody has to remember that a MinIO bucket is
`s3+http://key@host:9000/bucket` - the form writes the target out of what was
typed.

![adding a connection](docs/connection.svg)

Editing takes a target apart again, and **only when putting it back together
gives exactly the same string**. Anything this does not model - a libpq keyword
string, an `amqp://` url, a query with `sslmode` in it - stays the single field it
always was, under an engine called `target`, so editing a connection can never
quietly rewrite it.

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

## What it looks like

The picture above is a table: the objects in the database down the left, the rows
beside them, the cell under the cursor picked out and shown whole at the bottom.

The SQL editor: keywords, strings, numbers and comments in colour, `tab` completing
a table or column name, `ctrl+s` running it.

![the SQL editor](docs/editor.svg)

`ctrl+k` is the command palette. Type a few letters of what you want; the letters
that matched are underlined, and the key that does it is on the right, so using it
teaches the key map.

![the command palette](docs/palette.svg)

With no argument it opens the saved connections - here one of each engine, with
`keychain` marking the one whose password macOS keeps.

![the saved connections](docs/connections.svg)

The structure of a table: columns, indexes, foreign keys and the `CREATE`
statement the engine reports.

![the structure of a table](docs/structure.svg)

Those are not photographs of a terminal. The pty harness reproduces what the app
drew, colours and all, and [tests/shot.py](tests/shot.py) writes that grid out as
an SVG - so `./tests/shots.sh` regenerates every one of them, and they cannot
quietly drift away from what the program does.

## Redis

Redis is not relational and the driver does not pretend otherwise. It is fitted
to the interface rather than the other way round: one table called `data` whose
columns are `key`, `type`, `ttl` and `value`, rows found with `SCAN`, and the
numbered databases as schemas, so `#` moves between them. A value is shown as
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

## Kafka

A topic is a table whose columns are `partition`, `offset`, `timestamp`, `key`,
`value` and `headers`, and the mapping earns its keep: an offset is a page number,
so `1-50 of 12043` is exact and costs one `ListOffsets`, and `(partition, offset)`
addresses a record precisely. Filtering on the partition or the offset is pushed
into the fetch itself; a filter on the key or the value is applied as records
arrive, because a log has no index to do it with. Sorting descending reads the tail
of the log, which is the thing you usually want.

What it will not do is pretend a record can be changed. The log is append-only, so
an edit is refused and says why, and deleting one row is refused too - Kafka throws
away a *prefix* of a partition, which is `TRUNCATE`, not a row. Inserting works:
that is a `Produce`, and the partition is chosen with the same murmur2 hash Kafka's
own clients use, so a key written from here lands where it would have landed from
anywhere else.

The structure view shows the partitions with their leader, replicas, in-sync
replicas and offset range, and the definition is what `DescribeConfigs` says, with
the values inherited from the broker commented out so the ones actually set on the
topic stand out.

The editor is a Kafka console:

```
TOPICS                          every topic, with its partitions and records
BROKERS                         the cluster
GROUPS                          the consumer groups
OFFSETS orders                  the earliest and latest offset of each partition
DESCRIBE orders                 the configuration
CREATE orders 3 1               a topic, with partitions and replication factor
DROP orders
TRUNCATE orders                 throw away every record, keep the topic
PRODUCE orders key some value
```

**No client library.** The protocol is spoken directly, and every API version it
uses is the last one before that API became *flexible* - so there are no compact
strings and no tagged fields anywhere, one encoding instead of two, and brokers
from 2.1 to 4.x all answer it. Records are read from the leader of their partition,
which metadata names, so a real cluster works and not only one broker on a laptop.

Compressed batches are unpacked: gzip and zstd come out of Zig's standard library,
and **snappy and lz4 are written out** in the driver, because a great many topics
are one of those and a reader that cannot open them is not much of a reader. A
codec it does not know says so rather than handing back rubbish.

**TLS and SASL** are there for a cluster that is not on a private network:

```sh
krtek "kafka+ssl://alice@broker:9093"                              # asks for the password
krtek "kafka+ssl://bob@broker:9093?mechanism=SCRAM-SHA-256"
krtek "kafka://alice@broker:9092?password=secret"                  # SASL, no encryption
krtek "kafka+ssl://alice@broker:9093?insecure=1"                   # a certificate of its own making
```

TLS goes through the OpenSSL that is already linked in, and the broker's
certificate is verified against the machine's own trust store unless `insecure=1`
says not to bother. SASL is `PLAIN`, `SCRAM-SHA-256` and `SCRAM-SHA-512`, and SCRAM
is computed here rather than by a library - including the server's own signature,
which is the half of SCRAM that proves the *broker* knew the password too. A user
with no password makes krtek ask for one, and it can be kept wherever the other
connections keep theirs, keychain included.

## S3

A bucket is a table and an object is a row, with `key`, `size`, `modified`,
`etag` and `storage` for columns. The mapping is closer than Kafka's: keys come
back sorted, a key addresses a row exactly, and filtering with `W` on
`key LIKE 'a/b%'` becomes the `prefix` of the listing - which is the only filter
S3 has, so anything else is refused with the reason rather than answered by
downloading the bucket and pretending. Renaming a key is a copy and then a
delete, in that order, because S3 has no rename and a failure has to leave the
original where it was.

**Paging is by continuation token, which only goes forwards.** S3 has no OFFSET:
page five is reached by asking for the four before it and keeping the token each
one ends with. Those tokens are kept, so paging forward costs one request a page
and going back costs nothing. Counting is a walk, so it is done for a bucket
small enough to walk and reported as unknown for one that is not - an unknown
number of rows beats a wrong one.

The body of an object is not in the grid: a listing that fetched every object to
draw a screen would download the bucket. **The editor is an S3 console** instead,
and `GET` brings one object back as a value - so an image is shown as an image and
anything else as hex, by the same code that does it for a BLOB.

```
BUCKETS                         every bucket this key can see
LS [bucket] [prefix]            one page of keys
GET key                         the object itself, shown as a value
HEAD key                        what the server says about it
PUT key "some text"
DEL key
URL key 3600                    a signed link anybody can open, for an hour
```

**It is not only Amazon.** MinIO, Ceph, Garage and R2 speak the same protocol and
differ in how a bucket is addressed; a target that names a host gets path-style
addressing, Amazon gets the bucket in the hostname, and `?path=1` settles it by
hand. A bucket in another region answers with the region it is in, and that is
followed once rather than shown as a 301 nobody can read.

```sh
krtek s3://photos                                            # AWS, keys from the environment or ~/.aws
krtek "s3://photos?region=eu-central-1&profile=work"
krtek "s3+http://minioadmin:minioadmin@localhost:9000/photos"  # MinIO
krtek "s3://key:secret@ceph.example:8443/data?insecure=1"      # a certificate of its own making
```

**Credentials are looked for where the AWS tools look**, in the order they look:
the target, then `AWS_ACCESS_KEY_ID` and friends, then `~/.aws/credentials` and
`~/.aws/config` for the profile in use. So a machine already set up for the `aws`
command needs nothing said here, and a key that would otherwise sit in the
connections file in the clear stays where it was. The info view says which of the
four answered.

A target that names an access key and no secret - `s3://AKIA…@photos` - is asked
for the secret the way every other engine is asked for a password, and it can be
kept wherever the other connections keep theirs, keychain included. A target that
names a key is never quietly completed from the environment: somebody who wrote a
key down means that key.

**No SDK, and the signature is written out.** SigV4 is a hash of a canonical form
of the request signed with a key derived from the secret, the date, the region and
the service - about a hundred lines, and almost every bug in it is a
canonicalisation bug rather than a cryptographic one. So the canonical request and
the string to sign are functions of their own, checked against Amazon's own worked
examples byte for byte, including a presigned URL: see
[src/db/s3/sigv4.zig](src/db/s3/sigv4.zig).

## RabbitMQ

**Reading a queue is destructive, so this driver does not read queues.** AMQP has
no peek: `basic.get` takes the message off, and putting it back with
`nack requeue=true` changes the order and marks it redelivered. A queue is not a
table - it is a line of people waiting, and looking at somebody in a queue means
pulling them out of it. A client that browsed messages the way it browses rows
would quietly reorder a production queue every time the screen was drawn, and no
amount of care in the client can fix that, because the protocol has no other
move.

So what is a table here is the **topology**, which can be read as often as
anybody likes: `queues`, `exchanges`, `bindings`, `consumers`, `connections`,
`channels` and `nodes`, each of them a list endpoint of the management API on
port 15672. A vhost is a schema, so `#` moves between them. Those endpoints page,
count and sort on the server, which is why `1-50 of 812` is exact and costs one
request, and why sorting by the number of messages is the broker's work rather
than this program's - filtering is the broker's too, so `W` on the name becomes
its own `name=` filter.

Messages are still reachable, in the editor, which is a **RabbitMQ console** -
and what each of the two ways does is on the screen rather than in a footnote:

```
QUEUES [name]                    the queues, filtered by what a name contains
EXCHANGES, BINDINGS, CONSUMERS   the rest of the topology
CONNECTIONS, CHANNELS, NODES     what the broker is doing
VHOSTS, OVERVIEW, DEFINITIONS    the broker itself, and the whole vhost as it exports it
PEEK orders 10                   messages, put back afterwards - the order changes and
                                 they come back marked redelivered
DRAIN orders 10                  messages, kept off the queue for good
PUBLISH events order.new "hello" send one; - as the exchange is the default one
PURGE orders                     throw away everything in it
DECLARE QUEUE orders quorum      and DECLARE EXCHANGE events topic
BIND events orders order.#       and UNBIND events orders order.%23
DELETE QUEUE orders              and CLOSE, which hangs up on a client
```

Nothing in that list happens while browsing. Declaring, binding and deleting also
work from the grid - `i` on `queues` declares one, `d` removes it - and an *edit*
is refused, because a queue is declared and not altered. A dump of a vhost is
those commands, so what comes out goes back in: that is the topology, not the
messages, which is the only honest thing a dump of a broker can be.

```sh
krtek rabbit://guest@localhost:15672/               # asks for the password
krtek "rabbit://admin:secret@broker:15672/production"
krtek rabbits://admin@broker/production             # HTTPS, port 15671
krtek amqp://guest@broker:5672/%2F                  # the url you have to hand
```

That last one is taken and its port is not: 5672 speaks AMQP, and connecting to
it with HTTP would hang rather than say anything useful, so the management port
is used instead and the info view says so. The default vhost is `/`, which has to
travel as `%2F` in every path the driver builds - the single most common way to
get a 404 out of the management API, and the reason there is a test for a queue
with a space in its name.

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

`-Dstatic` links libpq, the connector and OpenSSL into the binary. On macOS that
leaves the system's own libraries dynamic - Kerberos, LDAP, curl, zlib - and on
Linux nothing at all, because musl has a static libc.

A static Linux build cannot be done with a distribution's packages:
Debian ships a `libpq.a` without the `pgcommon` and `pgport` archives it needs,
and Alpine, which has those, ships no archive for the MariaDB connector. So
[tests/linux-static.sh](tests/linux-static.sh) builds the connector from source
and is meant to run in an Alpine container - `docker run --rm -v "$PWD:/src" -w
/src alpine:3.22 …`, which is what CI does.

What a static link takes is not one `-l` per library, and not the same list twice,
so `pkg-config --static` is asked and its answer translated: both libraries in one
call, because they share zlib and OpenSSL and asking separately puts zlib in
twice, which dyld refuses to load. Where brew's `libpq.pc` names `libpgcommon`, the
`_shlib` variant beside it is used instead - the plain archive is built differently
from the libpq that references it, and linking it leaves `pg_encoding_to_char`
undefined. Each archive is then handed to the linker as a *file* rather than as
`-lname`: that keeps it out of its own search, which is where an archive quietly
becomes a shared library and takes the whole binary with it.

**Packaging** is two short scripts, both of which a release runs and CI rehearses.
[packaging/deb.sh](packaging/deb.sh) wraps the built binary as a `.deb` - binary,
man page, copyright, changelog, `Depends` on nothing - and needs `dpkg-deb`, which
is why it runs on the machine that has it rather than in the Alpine container that
built the binary. [packaging/formula.sh](packaging/formula.sh) writes the Homebrew
formula from the checksums the archives were actually packaged with, so it cannot
name a checksum that does not exist; the release attaches it and, given a
`TAP_TOKEN` secret that may push to `zales/homebrew-krtek`, commits it there as
`Formula/krtek.rb`, and the release attaches it. The tap fetches it from there with
a workflow of its own rather than being pushed to from here: that way it writes to
itself with the token it already has, and no personal access token has to live in
either repository as a secret. It is what `brew install zales/krtek/krtek` reads.
homebrew-core is a different matter: it wants a formula that builds from source and
would have to be worth its while.

The APT repository is [.github/workflows/apt.yml](.github/workflows/apt.yml), which
takes the `.deb` files off the releases - all of them, so nothing is lost - runs
`dpkg-scanpackages` over the lot, writes the `Release` file, signs it if there is a
key - the `APT_GPG_PRIVATE_KEY` secret - and pushes the result to the `gh-pages`
branch together with the landing page
in [docs/index.html](docs/index.html). It runs when a release is published, and by
hand from the Actions tab whenever the repository needs rebuilding.

The copyright file spells out what is linked in, because a static binary carries
other people's code: libpq under the PostgreSQL licence, the MariaDB connector
under the LGPL, OpenSSL under Apache 2.0, SQLite in the public domain. The LGPL
asks that its object code can be replaced, and it can - `zig build -Dstatic
-Dmariadb=<prefix>` from this source is the whole procedure, which is what the
copyright file says.

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

A batch reports each statement separately, and one that leaves a transaction
open is rolled back. A generated schema change
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
| `src/db/kafka.zig` | Kafka: the protocol, the compression codecs, TLS and SASL |
| `src/db/ask.zig` | what the interface asks for, and the SQL it renders to |
| `src/tui/keychain.zig` | the macOS keychain, through Security.framework |
| `vendor/sqlite3.c` | the unmodified SQLite amalgamation, compiled by Zig's clang |
| `src/db/kafka/` | the Kafka protocol, the codecs, the target and SCRAM - the parts with no connection in them |
| `src/db/net.zig` | a socket with TLS on it, shared by the drivers that speak their own protocol |
| `src/db/http.zig` | HTTP/1.1 over that socket: keep-alive, chunked, and a ceiling |
| `src/db/s3.zig` | S3: buckets as tables, listing by continuation token |
| `src/db/s3/` | the signature, the XML and the target - again, no connection in any of them |
| `src/db/rabbit.zig` | RabbitMQ: the topology as tables, over the management API |
| `src/db/rabbit/` | which endpoint each table is, where its columns live in the JSON, and the target |
| `packaging/` | the `.deb` and the Homebrew formula |
| `docs/index.html` | the landing page, which is also the APT repository |
| `docs/krtek.1` | the man page, installed by both of them |

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

**The parsers that read from a socket are fuzzed**, because several of them - the
snappy and lz4 unpackers, the walker over record batches, the HTTP reader and the
listing S3 answers with - are written out in this repository by hand, and they
read lengths off the wire and then believe them:

```sh
zig build fuzz                      # a few seconds, from a fixed seed
zig build fuzz -- 1000000 7         # a million inputs, from another
zig build fuzz -- replay gzip 1f8b… # one input, once, for a debug build to look at
```

Every iteration gets a fixed budget of memory and nothing else, so a parser that
would allocate whatever its input asked for reports `OutOfMemory` instead of taking
the machine with it. That is not hypothetical: it is what the first run did, and
five of the six things it has found were real -
[the details are in the driver](src/db/kafka.zig). CI runs 150 000 inputs from a
fixed seed on every push, so whatever it found once it finds again.

`zig build test --fuzz` is what this would otherwise be; it does not compile with
Zig 0.16.0, whose test runner passes a `*builtin.StackTrace` where a
`*const debug.StackTrace` is wanted.

The same harness records the colours, so the screenshots in this file are written
out of it: [tests/shot.py](tests/shot.py) turns a captured screen into an SVG and
[tests/shots.sh](tests/shots.sh) builds a small demo database and takes all of
them, in a configuration of its own so no screenshot shows anybody's real
connections:

```sh
zig build && ./tests/shots.sh
```

A server is needed for the drivers that talk to one, and
[tests/kafka.sh](tests/kafka.sh) brings its own: it starts a Kafka in KRaft mode
with four listeners - plain, SASL, SASL over TLS, and an internal one for Kafka's
own tools - writes a topic in every compression codec *with those tools*, creates a
PLAIN user and a SCRAM user, and then checks the driver against all of it, refusals
included. The records it reads are ones the Java client wrote, which is the point.

```sh
zig build && ./tests/kafka.sh
```

[tests/s3.sh](tests/s3.sh) does the same for S3, against MinIO rather than
Amazon on purpose: MinIO wants path-style addressing and a region it was never
told about, which is where a driver written only against AWS falls over. The
signature is the same either way - if MinIO accepts it Amazon does, and the unit
tests already check it against Amazon's own worked examples. Thirteen objects
over four-object pages, so the continuation tokens have to cover everything
exactly once, and every failure - wrong secret, missing bucket, no credentials at
all - has to say what is wrong rather than a number.

```sh
zig build && ./tests/s3.sh
```

[tests/rabbit.sh](tests/rabbit.sh) brings up a broker with its management plugin,
declares a topology with a queue whose name has a space in it - which is where an
unescaped vhost or name shows up as a 404 - and checks the listings, the counts
and every way in that can fail: a wrong password, a vhost that is not there, and
the AMQP port, which is the mistake everybody makes once. It browses no messages,
because browsing messages is what this driver refuses to do.

```sh
zig build && ./tests/rabbit.sh
```

That is how everything described here was verified: against a real SQLite file
with `sqlite3` reading the result back, and against a PostgreSQL 17 container
with `psql` doing the same.

## Deliberate limitations

* **No undo.** The file is edited in place, like any other database client, so
  `:dump` before a risky change.
* **A rebuild cannot recover what the pragmas do not report:** `CHECK`
  constraints, generated columns and collations are lost when a table is altered.
  The form says so.
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
* **S3 has no upload and no delete of many at once.** `PUT key text` writes what
  is typed, which is meant for a small object; there is no multipart upload, so a
  large one belongs in a tool that streams, and an object larger than 64 MB is
  refused rather than held in memory. Making and dropping a bucket is not there
  either: both are decisions about where data lives and what it costs, and a key
  press is the wrong way to make them. Nor is there versioning, tagging, or an
  ACL - a listing shows what a listing gives.

* **RabbitMQ's messages are not rows.** Reading a queue takes messages off it, so
  the grid never touches them: `PEEK` and `DRAIN` in the console do, and say which
  of the two happened. There is no AMQP in this program at all - no consuming, no
  acking somebody else's delivery, no shovel or federation management - and a
  broker without the management plugin cannot be opened, because that plugin is
  the whole protocol here.

## Licence

MIT - see [LICENSE](LICENSE).

What is linked into the binary keeps its own: SQLite (`vendor/sqlite3.c`) is
public domain, libpq is under the PostgreSQL licence, the MariaDB Connector/C
under the LGPL 2.1 and OpenSSL under Apache 2.0. The LGPL asks that its object
code can be replaced, and it can: `zig build -Dstatic -Dmariadb=<prefix>` from
this source is the whole procedure. The `copyright` file in the `.deb` says all
of this too.
