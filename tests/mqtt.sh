#!/bin/sh
# Bring up a Mosquitto and check the driver against it:
#
#     zig build && ./tests/mqtt.sh
#
# Most of this driver is tested without a broker - the unit tests bring their
# own, on the other end of a socket pair. What they cannot bring is a real one,
# and the other side of every exchange: here `mosquitto_pub` and `mosquitto_sub`
# from the same image are that. What was retained before krtek connected has to
# be in `topics` when it does, what krtek publishes has to reach a subscriber
# that is not krtek, and what it clears has to be gone for the next client.
#
# Three listeners: one that lets anybody in, one with a password file, for the
# three ways of being refused, and one with TLS on it - under a certificate of
# its own making, so it is also the check that such a one is refused unless the
# target says not to look. And at the end the broker is restarted under an open
# connection, which has to come back by itself.
set -e
cd "$(dirname "$0")/.."

NAME=${NAME:-krtek-mqtt-test}
IMAGE=${IMAGE:-eclipse-mosquitto:2}
PORT=${PORT:-1884}
AUTH_PORT=${AUTH_PORT:-1885}
TLS_PORT=${TLS_PORT:-8884}

BIN=zig-out/bin/krtek
test -x "$BIN" || { echo "$BIN is not there - zig build first" >&2; exit 1; }

# A configuration of its own: the app remembers every connection it opens.
CONFIG=$(mktemp -d)
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$CONFIG"' EXIT
export XDG_CONFIG_HOME="$CONFIG"

# A certificate for the TLS listener, signed by nobody: made here because the
# image has no openssl in it, and good for a day.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=krtek-mqtt-test" \
	-keyout "$CONFIG/server.key" -out "$CONFIG/server.crt" >/dev/null 2>&1 ||
	{ echo "openssl could not make a certificate" >&2; exit 1; }

echo "starting $IMAGE"
docker rm -f "$NAME" >/dev/null 2>&1 || true
# As the broker's own user and with everything in /tmp, so that the files it
# reads are files it may read: a password file root wrote is one it refuses,
# and so is a key anybody else can read - which is why the certificate goes in
# through the environment and is written by the user that will read it.
docker run -d --name "$NAME" --user 1883:1883 \
	-p "$PORT:1883" -p "$AUTH_PORT:1884" -p "$TLS_PORT:8883" \
	-e "TLS_CERT=$(cat "$CONFIG/server.crt")" -e "TLS_KEY=$(cat "$CONFIG/server.key")" \
	"$IMAGE" sh -c '
	umask 077
	printf "%s\n" "$TLS_CERT" > /tmp/server.crt
	printf "%s\n" "$TLS_KEY" > /tmp/server.key
	printf "%s\n" \
		"per_listener_settings true" \
		"sys_interval 1" \
		"listener 1883" \
		"allow_anonymous true" \
		"listener 1884" \
		"allow_anonymous false" \
		"password_file /tmp/passwd" \
		"listener 8883" \
		"allow_anonymous true" \
		"certfile /tmp/server.crt" \
		"keyfile /tmp/server.key" > /tmp/mosquitto.conf
	mosquitto_passwd -b -c /tmp/passwd ada tajne
	exec mosquitto -c /tmp/mosquitto.conf' >/dev/null

pub() { docker exec "$NAME" mosquitto_pub -h 127.0.0.1 "$@"; }
# One message from a topic, or nothing when there is none within two seconds.
held() { docker exec "$NAME" mosquitto_sub -h 127.0.0.1 -t "$1" -C 1 -W 2 2>/dev/null || true; }

printf 'waiting for the broker'
until docker exec "$NAME" mosquitto_sub -h 127.0.0.1 -t '$SYS/broker/version' -C 1 -W 1 >/dev/null 2>&1; do
	printf .
	sleep 1
done
echo " up"

pub -t dum/kuchyn/teplota -m 21.5 -r
pub -t dum/lampa -m on -r
pub -t garaz/vrata -m closed -r -q 1
# And one that nobody holds: it went by before anybody was listening.
pub -t dum/zvonek -m ding

ROOT="mqtt://127.0.0.1:$PORT"
AUTH="127.0.0.1:$AUTH_PORT"

# --- and now the driver ---

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

check() {
	what=$1
	target=$2
	wanted=$3
	table=$4
	out=$(zig build dbcheck -- "$target" $table 2>&1 || true)
	printf '%s' "$out" | grep -qE "$wanted" || {
		echo "--- what came back:" >&2
		printf '%s\n' "$out" >&2
		fail "$what"
	}
	echo "ok: $what"
}

check "it connects, and the broker says what it is" "$ROOT" "connected: 127.0.0.1:$PORT / MQTT 3.1.1, mosquitto version 2"
# The three that were retained, and not the one that went by.
check "what the broker holds is in topics a moment after connecting" "$ROOT" 'table \.topics rows~3 '
check "and in the log, in the order it came" "$ROOT" 'table \.messages rows~3 '
check "the broker's own figures are apart from what goes through it" "$ROOT" 'table \.\$SYS rows~[1-9]'
check "both subscriptions were granted, at the quality asked for" "$ROOT" 'listening to = #  \(qos 2\)'
check "a row is addressed by its topic" "$ROOT" "row key: topic" topics
check "a filter in the target is all that is listened to" "$ROOT/dum/%23" 'table \.topics rows~2 '
check "and the broker's own figures are not asked for beside it" "$ROOT/dum/%23" 'table \.\$SYS rows~0 '
check "a filter that cannot be one is refused before connecting" "$ROOT/dum/%23/x" "is not something to subscribe to"

check "a user and a password" "mqtt://ada:tajne@$AUTH" "connected: $AUTH"
# Worded for the interface, which asks for a password when a refusal mentions
# one - and must not where there is no user to send it with.
check "a wrong password asks for the right one" "mqtt://ada:spatne@$AUTH" "the broker wants a password for ada"
check "no password asks for one" "mqtt://ada@$AUTH" "the broker wants a password for ada"
check "no user says to name one" "mqtt://$AUTH" "it wants a user, as mqtt://user@$AUTH"
check "nothing listening says so" "mqtt://127.0.0.1:1" "cannot reach an MQTT broker at 127.0.0.1:1"

# Over TLS: the same three topics have to arrive, which they only do if the
# thread that listens reads through the encryption as well as it reads a socket.
SECURE="mqtts://127.0.0.1:$TLS_PORT"
check "TLS, to a certificate the target says not to check" "$SECURE?insecure=1" "connected: 127.0.0.1:$TLS_PORT"
check "and what the broker holds arrives through it" "$SECURE?insecure=1" 'table \.topics rows~3 '
check "a certificate nobody signed is refused unless told otherwise" "$SECURE" "open failed: .*(certificate|TLS)"

# --- the screen ---

SCREEN="$CONFIG/screen.txt"
screen() {
	python3 tests/screen.py "$@" > "$SCREEN" 2>/dev/null || fail "the harness could not run: $*"
}
shows() {
	grep -qE "$2" "$SCREEN" || {
		cat "$SCREEN" >&2
		fail "$1"
	}
	echo "ok: $1"
}

# With a wait, because nothing is typed that would take the time for it: the
# first start of a binary and a connection to make are both in front of the
# first frame.
screen "$ROOT" '{wait}' '{wait}' '{keep}'
shows "the first screen is the topics, with what was last said on each" 'dum/kuchyn/teplota +21\.5 +yes'
shows "and the broker's version is in the header" "mosquitto version 2"

# Out through the console, and read back by a client that is not this one.
# (No braces in what is typed here: they are how the harness names a key.)
screen "$ROOT" s 'RETAIN dum/rezim noc' '{enter}' 'PUBLISH -r -q 2 dum/kvalita dve "slova" a; strednik' '{ctrl-s}' '{keep}'
test "$(held dum/rezim)" = "noc" || fail "RETAIN did not reach the broker"
echo "ok: a retained message from the console is held by the broker"
test "$(held dum/kvalita)" = 'dve "slova" a; strednik' || fail "a message at quality 2 did not reach the broker as it was typed"
echo "ok: and one at quality two, quotes and a semicolon and all"

# And out through TLS, read back in the clear.
screen "$SECURE?insecure=1" s 'RETAIN dum/sifrovane ano' '{ctrl-s}' '{keep}'
test "$(held dum/sifrovane)" = "ano" || fail "a message sent over TLS did not reach the broker"
echo "ok: a message sent over TLS is held by the broker"

# Through the grid: the payload of the first topic, changed in place. It was
# retained, so the new one is given to the broker to hold as well.
screen "$ROOT" '{tab}' '{right}' e '{bs}' '{bs}' '{bs}' '{bs}' '{bs}' '{bs}' '{bs}' '{bs}' '{bs}' '{bs}' '22' '{enter}' '{keep}'
shows "a payload changed in the grid is published" ' updated'
test "$(held dum/kuchyn/teplota)" = "22" || fail "the changed payload is not what the broker holds"
echo "ok: and the broker holds the new one"

# A new row through the form: a topic, a payload, and held.
screen "$ROOT" '{tab}' i 'dum/novy' '{tab}' 'ano' '{tab}' 'yes' '{ctrl-s}' '{keep}'
shows "a row inserted is a message published" 'row inserted'
test "$(held dum/novy)" = "ano" || fail "the inserted row did not reach the broker"
echo "ok: and it reached the broker"

# Deleting a topic clears what the broker holds for it. The list is in the
# order of the names, so the first row is the kitchen's.
screen "$ROOT" '{tab}' x y '{enter}' '{keep}'
shows "a deleted topic is gone from the list" '1 row deleted'
test -z "$(held dum/kuchyn/teplota)" || fail "the retained message was not cleared"
echo "ok: and the broker no longer holds it"

# What somebody else publishes while this is open is there on the next look,
# without this having asked for anything in between.
# The waits are longer than the sleep by enough that a slow machine does not
# turn "not yet" into a failure.
(sleep 2; pub -t dum/host -m prisel) &
screen "$ROOT" '{wait}' '{wait}' '{wait}' '{wait}' '{wait}' '{wait}' '{wait}' '{wait}' '{wait}' '{wait}' r '{keep}'
wait
shows "a message published by somebody else has arrived by the next reload" 'dum/host +prisel'

# The filter row speaks MQTT: a + is a level, typed where SQL would go.
screen "$ROOT" W '{tab}' '{tab}' '{tab}' '{tab}' '{tab}' '{tab}' '{tab}' '{tab}' '{tab}' 'garaz/+' '{ctrl-s}' '{keep}'
shows "a topic filter typed into the filter row narrows the list" 'garaz/vrata +closed'
grep -q "dum/lampa" "$SCREEN" && fail "the filter row left a topic it should have hidden"
echo "ok: and hides what it does not match"

# The broker goes away under an open connection and comes back. Without a
# place to keep them it comes back holding nothing, so what is on the screen
# afterwards is what this connection had heard - and a message sent after the
# restart has to arrive, which it only does over a connection made again.
#
# Nothing here waits on the clock for the broker to be back: the restart is
# over before the reload is pressed, and the reload is what reconnects. Should
# it be pressed too early all the same, typing the message takes longer than
# the driver leaves between two tries, so the publish is a second one.
(sleep 3; docker restart -t 1 "$NAME" >/dev/null) &
restarting=$!
screen "$ROOT" '{wait}' '{wait}' '{wait}' '{wait}' '{wait}' '{wait}' '{wait}' '{wait}' '{wait}' '{wait}' '{wait}' '{wait}' \
	'{wait}' '{wait}' '{wait}' '{wait}' r '{wait}' '{wait}' s 'PUBLISH dum/po restartu' '{ctrl-s}' '{tab}' '{enter}' '{wait}' '{keep}'
wait "$restarting"
shows "what was heard before the broker restarted is still on the screen" 'garaz/vrata +closed'
shows "and a message sent afterwards came back over the new connection" 'dum/po +restartu'
grep -q "not connected" "$SCREEN" && fail "the header still says the connection is lost"
echo "ok: and the header no longer says the connection is lost"

echo "all good"
