#!/bin/sh
# Bring up a SQL Server and check the driver against it:
#
#     zig build && ./tests/mssql.sh
#
# This one is worth more than the other suites, because this driver speaks the
# protocol itself rather than through a library. Nothing here is checked by a
# vendor's code: the packet framing, the TLS handshake that happens inside those
# packets, the login, the token stream and twenty data types are all this
# program's own, and the only thing that can say they are right is a server.
#
# What it looks for, beyond "does it connect":
#
#   - every type comes back as what went in, dates and money and decimals
#     included, which is the tds.zig test run against this container;
#   - every schema statement this program writes is one the server accepts,
#     which is the mssql.zig test doing the same;
#   - a transaction is a transaction: TDS puts the transaction's descriptor in
#     every statement's header, and a statement that carries the wrong one is
#     quietly not part of it;
#   - text keeps its accents. Written without the `N` in front of the literal a
#     value goes through the database's single-byte codepage on the way in, and
#     `příklep` becomes `príklep` - which looks close enough to miss.
set -e
cd "$(dirname "$0")/.."

NAME=${NAME:-krtek-mssql-test}
IMAGE=${IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
PASSWORD=${PASSWORD:-Krtek-heslo-1}
PORT=${PORT:-1433}
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

BIN=zig-out/bin/krtek
test -x "$BIN" || { echo "$BIN is not there - zig build first" >&2; exit 1; }

# A configuration of its own: the app remembers every connection it opens, and
# a test has no business editing the list somebody actually uses.
CONFIG=$(mktemp -d)
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$CONFIG"' EXIT
export XDG_CONFIG_HOME="$CONFIG"

echo "starting $IMAGE"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "$PORT:1433" \
	-e ACCEPT_EULA=Y -e "MSSQL_SA_PASSWORD=$PASSWORD" -e MSSQL_PID=Developer \
	"$IMAGE" >/dev/null

SQLCMD="docker exec $NAME /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P $PASSWORD -C"

printf 'waiting for the server'
tries=0
until $SQLCMD -Q "SELECT 1" >/dev/null 2>&1; do
	tries=$((tries + 1))
	if [ "$tries" -gt 60 ]; then
		echo " gave up" >&2
		docker logs --tail 40 "$NAME" >&2
		exit 1
	fi
	printf .
	sleep 2
done
echo " up"

$SQLCMD -Q "IF DB_ID('demo') IS NULL CREATE DATABASE demo"
# A view has to be the first statement in its batch, which is why this is not
# one batch. `-b` so that a statement the server refuses stops the script here
# rather than three checks later, where it looks like a driver fault.
$SQLCMD -b -d demo -Q "
CREATE TABLE dbo.zbozi (
  id int IDENTITY(1,1) NOT NULL PRIMARY KEY,
  nazev nvarchar(80) NOT NULL,
  cena decimal(10,2) NULL DEFAULT 0,
  skladem bit NOT NULL DEFAULT 1,
  zalozeno datetime2(0) NOT NULL DEFAULT SYSUTCDATETIME()
);
CREATE INDEX ix_nazev ON dbo.zbozi(nazev);
INSERT INTO dbo.zbozi (nazev, cena) VALUES (N'šroubovák', 129.50), (N'kladivo', 249.00), (N'pilník', 89.90);
CREATE TABLE dbo.objednavky (
  id int NOT NULL PRIMARY KEY,
  zbozi_id int NULL REFERENCES dbo.zbozi(id) ON DELETE CASCADE
);"
$SQLCMD -b -d demo -Q "CREATE VIEW dbo.levne AS SELECT id, nazev FROM dbo.zbozi WHERE cena < 200;"

# --- and now the driver ---

fail() { echo "FAIL: $1" >&2; exit 1; }

ROOT="mssql://sa:$PASSWORD@127.0.0.1:$PORT"

check() {
	what=$1
	target=$2
	wanted=$3
	table=$4
	out=$(zig build dbcheck -- "$target" $table 2>&1 || true)
	printf '%s' "$out" | grep -q "$wanted" || {
		echo "--- what came back:" >&2
		printf '%s\n' "$out" >&2
		fail "$what"
	}
	echo "ok: $what"
}

# What the app draws, so a driver that answers correctly and then cannot fill a
# screen is still a failure.
screen() {
	what=$1
	shift
	wanted=$1
	shift
	out=$(SCREEN_COLS=110 SCREEN_ROWS=20 python3 tests/screen.py "$ROOT/demo" "$@" '{keep}' 2>&1 || true)
	# A target that failed to open leaves the app on its list of connections,
	# where the keys below mean something else entirely - so say that rather than
	# blaming whatever check happens to be running.
	printf '%s' "$out" | grep -q "connect to a database" && {
		echo "--- the server was not there; the app fell back to its connection list:" >&2
		printf '%s\n' "$out" >&2
		fail "$what"
	}
	printf '%s' "$out" | grep -q "$wanted" || {
		echo "--- what it drew:" >&2
		printf '%s\n' "$out" >&2
		fail "$what"
	}
	echo "ok: $what"
}

check "the server says what it is" "$ROOT/demo" "SQL Server 16"
check "and which database it landed in" "$ROOT/demo" "connected: sa@127.0.0.1:$PORT/demo"
check "dbo is a schema" "$ROOT/demo" "schema dbo"
check "a table, with the count the server keeps" "$ROOT/demo" "table dbo.zbozi rows~3 exact=3" zbozi
check "a view is a view" "$ROOT/demo" "view dbo.levne" zbozi
check "an identity column says where its numbers come from" \
	"$ROOT/demo" "column id int NOT NULL PK default=IDENTITY(1,1)" zbozi
check "a length that was declared is a length that is shown" \
	"$ROOT/demo" "column nazev nvarchar(80) NOT NULL" zbozi
check "and so are the digits of a decimal" "$ROOT/demo" "column cena decimal(10,2)" zbozi
# The catalog wraps a default in brackets; none of them mean anything to read.
check "a default arrives without the brackets the catalog put on it" \
	"$ROOT/demo" "column skladem bit NOT NULL default=1" zbozi
check "the primary key is told from the other indexes" "$ROOT/demo" "PRIMARY (id)" zbozi
check "an index of its own" "$ROOT/demo" "index ix_nazev INDEX (nazev)" zbozi
check "a row is addressed by its key" "$ROOT/demo" "row key: id (usable=true)" zbozi
check "a foreign key, and what it does on delete" \
	"$ROOT/demo" "fk zbozi_id -> zbozi.id on delete CASCADE" objednavky
check "accented text survives the trip out" "$ROOT/demo" "nazev=šroubovák" zbozi
# A page here is OFFSET/FETCH and not LIMIT, and the standard spelling refuses to
# page anything it has not been told how to sort.
check "paging reaches every row exactly once" "$ROOT/demo" "paged: 3 records, 3 distinct" zbozi
check "a view can be read back as it was written" "$ROOT/demo" "cena" levne

check "a wrong password says so rather than asking again" \
	"mssql://sa:nonsense@127.0.0.1:$PORT/demo" "Login failed"
check "a port with nothing behind it says which one" \
	"mssql://sa:$PASSWORD@127.0.0.1:14330/demo" "cannot reach 127.0.0.1:14330"

# The table is picked by name. Counting {down}s worked until the suite created a
# table of its own and every count after that pointed one row further down.
ZBOZI="{sleep} / z b o z i {enter} {sleep} {enter} {sleep}"
# shellcheck disable=SC2086
screen "the grid draws the table" "šroubovák" $ZBOZI
screen "a batch is split and the last statement is what shows" "zbylo" \
	'{sleep}' 's' "select count(*) as zbylo from dbo.zbozi" '{ctrl-s}' '{sleep}'
# TDS carries the transaction's descriptor in every statement's header. Without
# it the server takes each statement as its own, and a delete inside a
# transaction is neither rolled back nor visible - it simply happened.
screen "a statement inside a transaction is inside it" "v_transakci" \
	'{sleep}' 's' "begin transaction; delete from dbo.zbozi; select count(*) as v_transakci from dbo.zbozi" \
	'{ctrl-s}' '{sleep}'
screen "and the object list still works while one is open" "zbozi" \
	'{sleep}' 's' "begin transaction" '{ctrl-s}' '{sleep}'

# Nothing was committed above, so the rows are still there.
$SQLCMD -d demo -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.zbozi" -h -1 -W \
	| grep -qx 3 || fail "a transaction nobody committed changed the table anyway"
echo "ok: an uncommitted transaction leaves nothing behind"

# The create-table form with nothing but a name typed in: a key column, and the
# nullability left alone. SQL Server refuses a key that may be empty, where the
# other engines here decide for themselves.
screen "a table made from the form is a table the server takes" "sklady" \
	'{sleep}' 'c' 'sklady' '{ctrl-s}' '{sleep}'

# An accent that is not in the database's own codepage: without the N in front
# of the literal this comes back as `príklep`, which is close enough to miss.
# shellcheck disable=SC2086
screen "an edited value keeps its accents" "příklepová" \
	$ZBOZI '{down}' '{right}' 'e' '{ctrl-u}' 'příklepová vrtačka' '{enter}' '{sleep}'
$SQLCMD -d demo -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.zbozi WHERE nazev = N'příklepová vrtačka'" -h -1 -W \
	| grep -qx 1 || fail "the accented value did not reach the table intact"
echo "ok: and the server has it, character for character"

# What comes out has to go back in. This is the check that found three separate
# faults at once: no CREATE TABLE at all, because a table keeps no text on this
# engine and the driver said so instead of writing one out of the catalog; text
# without its `N`, so a replayed dump lost its accents; and a column that numbers
# itself refusing every row, because nothing told the table to accept the values.
# It is replayed with plain sqlcmd rather than through krtek, so the file has to
# stand on its own - which is what the `SET QUOTED_IDENTIFIER ON` at the top of
# it is for.
DUMP=$(mktemp -d)
(
	cd "$DUMP"
	XDG_CONFIG_HOME="$DUMP" SCREEN_COLS=110 SCREEN_ROWS=20 \
		python3 "$OLDPWD/tests/screen.py" "$ROOT/demo" \
		'{sleep}' / z b o z i '{enter}' '{sleep}' '{enter}' '{sleep}' 'E' '{ctrl-s}' '{sleep}' '{keep}' >/dev/null 2>&1
)
test -s "$DUMP/dump.sql" || fail "the export wrote nothing"
grep -q 'CREATE TABLE' "$DUMP/dump.sql" || fail "the dump has no CREATE TABLE"
grep -q "N'" "$DUMP/dump.sql" || fail "the dump writes text without saying which encoding it is in"
echo "ok: the dump has a table in it, and its text says what it is"

$SQLCMD -Q "IF DB_ID('obnova') IS NOT NULL DROP DATABASE obnova; CREATE DATABASE obnova" >/dev/null
docker cp "$DUMP/dump.sql" "$NAME:/tmp/dump.sql" >/dev/null
$SQLCMD -b -d obnova -i /tmp/dump.sql >/dev/null 2>&1 || fail "the dump would not go back in"
$SQLCMD -d obnova -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.zbozi WHERE nazev = N'šroubovák'" -h -1 -W \
	| grep -qx 1 || fail "the replayed dump lost a value on the way"
rm -rf "$DUMP"
echo "ok: and it goes back in, character for character"

# A statement that will not finish, and ctrl+c. TDS has a packet of its own for
# this, and the server has to acknowledge it before anything else may be sent -
# so what is checked is not only that the statement stops but that the next one
# still works, which is what tells a cancel from a broken connection.
screen "a statement that will not finish can be stopped" "stopped" \
	'{sleep}' 's' "waitfor delay '00:00:30'" '{ctrl-s}' '{sleep}' '{ctrl-c}' '{sleep}'
screen "and the connection is still good afterwards" "po_zruseni" \
	'{sleep}' 's' "waitfor delay '00:00:30'" '{ctrl-s}' '{sleep}' '{ctrl-c}' '{sleep}' \
	's' '{ctrl-u}' "select count(*) as po_zruseni from dbo.zbozi" '{ctrl-s}' '{sleep}'

# The two tests that need a server rather than a laptop: every data type read
# back, and every schema statement this program writes run as written.
echo "the unit tests that want a server"
KRTEK_MSSQL="127.0.0.1:$PORT:sa:$PASSWORD" zig build test

echo "all good"
