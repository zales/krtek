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
set -e
cd "$(dirname "$0")/.."

NAME=${NAME:-krtek-rabbit-test}
IMAGE=${IMAGE:-rabbitmq:3-management}
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

BIN=zig-out/bin/krtek
test -x "$BIN" || { echo "$BIN is not there - zig build first" >&2; exit 1; }

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

echo "all good"
