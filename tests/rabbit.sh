#!/bin/sh
# Bring up a RabbitMQ with its management plugin and check the driver against it:
#
#     zig build && ./tests/rabbit.sh
#
# One broker, a topic exchange bound to a queue, and a few messages. What is
# checked is the topology - queues, exchanges, bindings - because that is what
# this driver makes tables of, plus the two things that are easy to get wrong:
# the vhost has to travel escaped in every path, and the broker's own count is
# `filtered_count` and not `item_count`, which is the size of the page and would
# make every listing look like one screen.
#
# Messages are deliberately not browsed: reading a queue takes the message off
# it, so nothing here does it by accident and neither does the interface.
#
# After the driver, the screen: the console that is the one way to a message,
# the grid that declares and removes, a connection marked read-only that does
# neither, and a dump of a vhost put back into another one - which is where a
# queue with a space in its name came back as a queue called `dead`.
set -e
cd "$(dirname "$0")/.."

NAME=${NAME:-krtek-rabbit-test}
IMAGE=${IMAGE:-rabbitmq:3-management}
DUMP=/tmp/krtek-rabbit-dump.txt

BIN=zig-out/bin/krtek
test -x "$BIN" || { echo "$BIN is not there - zig build first" >&2; exit 1; }

# A configuration of its own: the app remembers every connection it opens, and
# the last checks here mark one read-only - in a list of this test's, not in
# the one somebody actually uses.
CONFIG=$(mktemp -d)
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$CONFIG" "$DUMP"' EXIT
export XDG_CONFIG_HOME="$CONFIG"

echo "starting $IMAGE"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p 15672:15672 "$IMAGE" >/dev/null

printf 'waiting for the broker'
until curl -sf -u guest:guest -o /dev/null http://127.0.0.1:15672/api/overview; do
	printf .
	sleep 2
done
echo " up"

docker exec "$NAME" sh -c '
	rabbitmqadmin declare vhost name=druhy >/dev/null
	rabbitmqadmin declare permission vhost=druhy user=guest configure=".*" write=".*" read=".*" >/dev/null
	rabbitmqadmin declare queue name=orders durable=true >/dev/null
	rabbitmqadmin declare queue name="dead letters" durable=true >/dev/null
	rabbitmqadmin declare exchange name=events type=topic >/dev/null
	rabbitmqadmin declare binding source=events destination=orders routing_key=order.# >/dev/null
	for i in 1 2 3 4 5; do
		rabbitmqadmin publish exchange=events routing_key=order.new payload="objednavka $i" >/dev/null
	done' >/dev/null

# --- and now the driver ---

fail() { echo "FAIL: $1" >&2; exit 1; }

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

ROOT="rabbit://guest:guest@127.0.0.1:15672"

check "the default vhost, written as a slash" "$ROOT/%2F" "connected: 127.0.0.1:15672/"
check "the broker says what it is" "$ROOT/%2F" "RabbitMQ 3"
check "an amqp url reaches the management port anyway" \
	"amqp://guest:guest@127.0.0.1:5672/%2F" "connected: 127.0.0.1:15672/"
check "a vhost of its own" "$ROOT/druhy" "connected: 127.0.0.1:15672/druhy"

# The counts come from the broker, and it counts the listing rather than the page.
check "the queues are a table" "$ROOT/%2F" "table /.queues rows~null exact=2" queues
check "so are the bindings" "$ROOT/%2F" "table /.bindings" bindings
check "a queue's columns are its own" "$ROOT/%2F" "column messages number" queues
check "a queue is addressed by its name" "$ROOT/%2F" "row key: name (usable=true)" queues
check "and its rows come back" "$ROOT/%2F" "name=orders" queues
# A queue with a space in its name is where an unescaped path shows up.
check "a name with a space in it survives the path" "$ROOT/%2F" "dead letters" queues
check "the broker's own state is there but is not the user's data" "$ROOT/%2F" "table /.connections" connections
check "paging over a listing the broker does not page" "$ROOT/%2F" "paged: 1 records, 1 distinct" nodes

check "a wrong password says so" \
	"rabbit://guest:nonsense@127.0.0.1:15672/%2F" "password for guest was not accepted"
check "a vhost that is not there says so" \
	"$ROOT/neexistuje" "there is no vhost called neexistuje"
# The AMQP port speaks AMQP, and this is the mistake somebody makes once.
check "a port that is not the management one says what it is" \
	"rabbit://guest:guest@127.0.0.1:5673/%2F" "cannot reach 127.0.0.1:5673"

# --- and now the screen: what a person does with a broker ---

screen() {
	what=$1; shift; wanted=$1; shift; target=$1; shift
	out=$(SCREEN_COLS=118 SCREEN_ROWS=22 python3 tests/screen.py "$target" "$@" '{sleep}' '{keep}' 2>&1 || true)
	printf '%s' "$out" | grep -q "connect to a database" && {
		echo "--- the broker was not there; the app fell back to its connection list:" >&2
		printf '%s\n' "$out" >&2; fail "$what"
	}
	printf '%s' "$out" | grep -q "$wanted" || {
		echo "--- what it drew:" >&2; printf '%s\n' "$out" >&2; fail "$what"
	}
	echo "ok: $what"
}

# What the broker itself says, which is the yardstick: rabbitmqctl rather than
# the management API, because that one answers out of statistics it gathers
# every five seconds and is five seconds behind whatever was just done.
waiting() {
	docker exec "$NAME" rabbitmqctl -q list_queues name messages --no-table-headers |
		awk -F'\t' -v queue="$1" '$1 == queue { print $2 }'
}
queues() {
	docker exec "$NAME" rabbitmqctl -q -p "${1:-/}" list_queues name --no-table-headers
}

screen "the queues are on the grid, the one with a space in its name too" "dead letters" "$ROOT/%2F"

# The whole value of a cell is that cell's. `gv` asks the broker again for the
# one column the cursor is on and shows the first cell of what comes back - and
# what came back was every column, so the box said `type` along the top and had
# the queue's name inside.
whole=$(SCREEN_COLS=118 SCREEN_ROWS=22 python3 tests/screen.py "$ROOT/%2F" '{tab}' '{right}' 'g' 'v' '{sleep}' '{keep}' 2>&1 |
	grep -A1 'type ─ enter/esc closes' | tail -1 | sed 's/\(.*\)│.*$/\1/; s/ *$//; s/^.*│ //')
[ "$whole" = "classic" ] || fail "gv on the type of dead letters should show classic, and shows '$whole'"
echo "ok: gv shows the value under the cursor, and not the name of its row"

# The console is the one way to a message, and what each of its two ways does
# to the queue is on the screen rather than in a footnote - so it is checked
# against the broker's own count, not against what the screen says about itself.
[ "$(waiting orders)" = "5" ] || fail "orders should have the 5 messages published above, and has $(waiting orders)"
screen "PEEK shows what is waiting" "objednavka 1" "$ROOT/%2F" 's' 'PEEK orders 2' '{ctrl-s}'
[ "$(waiting orders)" = "5" ] || fail "PEEK should put back what it took, and left $(waiting orders) of 5"
echo "ok: and puts it back"
screen "DRAIN shows it too" "taken" "$ROOT/%2F" 's' 'DRAIN orders 2' '{ctrl-s}'
[ "$(waiting orders)" = "3" ] || fail "DRAIN should keep what it took, and left $(waiting orders) of 5"
echo "ok: and keeps it off the queue"
screen "PUBLISH sends one through an exchange and its binding" "published" "$ROOT/%2F" \
	's' 'PUBLISH events order.new "ahoj, svete"' '{ctrl-s}'
[ "$(waiting orders)" = "4" ] || fail "the published message did not reach the queue it is bound to"
echo "ok: and it arrives where the binding says"

screen "DECLARE makes a queue, with a space in its name and of the kind asked for" "declared" "$ROOT/%2F" \
	's' 'DECLARE QUEUE "nova fronta" quorum' '{ctrl-s}'
docker exec "$NAME" rabbitmqctl -q list_queues name type --no-table-headers |
	grep -q "^nova fronta	quorum$" || fail "DECLARE did not make the queue it was asked for"
screen "DELETE takes it away again" "deleted" "$ROOT/%2F" 's' 'DELETE QUEUE "nova fronta"' '{ctrl-s}'
queues | grep -qx "nova fronta" && fail "DELETE left the queue where it was"
echo "ok: and the broker agrees about both"

# The grid does the same two things to the topology and refuses the third,
# because a queue is declared and not altered.
screen "i on the queues declares one" "row inserted" "$ROOT/%2F" '{enter}' 'i' 'zgridu' '{ctrl-s}'
queues | grep -qx zgridu || fail "the queue made from the form is not on the broker"
screen "x removes the one under the cursor" "1 row(s) deleted" "$ROOT/%2F" '{enter}' 'G' 'x'
queues | grep -qx zgridu && fail "x left the queue on the broker"
echo "ok: and the broker agrees about both"
screen "an edit is refused, in the driver's own words" "declared rather than altered" "$ROOT/%2F" '{enter}' 'e'
screen "a vhost is a schema, so # moves to another" "VHOST druhy" "$ROOT/%2F" '#' '{right}' '{ctrl-s}'

# What comes out of a dump has to go back in: the topology of one vhost, replayed
# into the other. Three things were wrong with it at once. A name was written
# bare, so `DECLARE QUEUE dead letters classic` made a queue called `dead`; the
# exchange with no name was declared too, and came back as one called `direct`;
# and so were the broker's own `amq.` exchanges, one of which it refuses.
python3 tests/screen.py "$ROOT/%2F" ':' "dump $DUMP" '{enter}' '{sleep}' '{keep}' >/dev/null 2>&1
grep -qx 'DECLARE QUEUE "dead letters" classic' "$DUMP" || fail "the dump should quote a name with a space in it"
grep -qx 'DECLARE EXCHANGE events topic' "$DUMP" || fail "the dump has lost the exchange"
grep -qx 'BIND events orders order.#' "$DUMP" || fail "the dump has lost the binding"
grep -q '^DECLARE EXCHANGE \( \|amq\.\)' "$DUMP" && fail "the dump declares exchanges that are the broker's own"
python3 tests/screen.py "$ROOT/druhy" '{ctrl-k}' 'import' '{enter}' '{down}' "$DUMP" '{ctrl-s}' \
	'{sleep}{sleep}' '{keep}' >/dev/null 2>&1
queues druhy | grep -qx "dead letters" || fail "the queue with a space in its name did not come back as itself"
queues druhy | grep -qx orders || fail "replaying the dump did not bring the queues back"
docker exec "$NAME" rabbitmqctl -q -p druhy list_exchanges name type --no-table-headers > "$CONFIG/exchanges"
grep -q "^events	topic$" "$CONFIG/exchanges" || fail "replaying the dump did not bring the exchange back"
grep -q "^direct	" "$CONFIG/exchanges" && fail "the default exchange came back as one called direct"
docker exec "$NAME" rabbitmqctl -q -p druhy list_bindings source_name destination_name routing_key --no-table-headers |
	grep -q "^events	orders	order.#$" || fail "replaying the dump did not bring the binding back"
echo "ok: a dump of a vhost puts the vhost back, a name with a space in it and all"

# Last, because the mark stays in this test's list for every run after it: a
# connection marked read-only. The grid's keys go through the same refusal the
# forms do, and the console's lines are read before they are sent - a broker in
# production is the place where one key too many is a queue gone.
python3 tests/screen.py "$ROOT/%2F" 'O' 'r' '{keep}' >/dev/null 2>&1
screen "a broker marked read-only says so" "15672/  read-only" "$ROOT/%2F"
screen "and x removes nothing there" "marked read-only" "$ROOT/%2F" '{enter}' 'G' 'x'
queues | grep -qx orders || fail "x deleted a queue through a connection marked read-only"
screen "and its console refuses what would change the broker" "read-only: PURGE" "$ROOT/%2F" \
	's' 'PURGE orders' '{ctrl-s}'
[ "$(waiting orders)" = "4" ] || fail "a read-only connection purged a queue"
echo "ok: and the broker still has every queue and every message"

echo "all good"
