#!/bin/sh
# What somebody sees while a connection is being opened, and what esc does
# about it:
#
#     zig build && ./tests/connecting.sh
#
# There is no server to bring up, because the server this is about is the one
# that does not answer. A listener that takes a connection and then says nothing
# is that server, on any machine, for as long as the test wants it - which a real
# one being slow never is.
#
# What it looks for: that the wait is said on the screen and not sat through in
# silence, that the sentence names the step it is stuck on, that the password
# stays out of it, that esc gets the program back, and that the program is still
# good for something afterwards - the connection it had, or the next one.
set -e
cd "$(dirname "$0")/.."

BIN=zig-out/bin/krtek
test -x "$BIN" || { echo "$BIN is not there - zig build first" >&2; exit 1; }

CONFIG=$(mktemp -d)
trap 'kill "$SILENT" 2>/dev/null || true; rm -rf "$CONFIG"' EXIT
export XDG_CONFIG_HOME="$CONFIG"

# Two listeners, and the ports are theirs to choose, so two runs at once do not
# meet. One takes a connection and keeps it, saying nothing. The other hangs up
# after a while, which is a connect that takes that long and then fails - the
# only slow connect with an end that needs no server to play it.
python3 - "$CONFIG/ports" <<'PY' &
import os, signal, socket, sys, threading, time
# Told to stop, it stops quietly: a shell that sees a child die of a signal says
# so, on a line that reads like a failure at the end of a run that had none.
signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
# As long as the harness waits before its first key and a little more, however
# slow it has been told to be: the key has to arrive while the wait is on.
late = 1.5 * float(os.environ.get("SCREEN_SLOW", 1))

def listen():
	server = socket.socket()
	server.bind(("127.0.0.1", 0))
	server.listen(16)
	return server

def hang_up_later(server):
	while True:
		client = server.accept()[0]
		threading.Timer(late, client.close).start()

silent, leaving = listen(), listen()
threading.Thread(target=hang_up_later, args=(leaving,), daemon=True).start()
# Written whole or not at all, so a port is never read half written - and with
# a newline at the end, without which `read` calls a line it did read a failure.
with open(sys.argv[1] + ".tmp", "w") as file:
	file.write("%d %d\n" % (silent.getsockname()[1], leaving.getsockname()[1]))
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
held = []
while True:
	held.append(silent.accept()[0])
PY
SILENT=$!
tries=0
until [ -s "$CONFIG/ports" ]; do
	tries=$((tries + 1))
	[ "$tries" -gt 50 ] && { echo "the listeners never came up" >&2; exit 1; }
	sleep 0.1
done
read -r PORT LEAVING < "$CONFIG/ports"

# Something to be connected to already, for the checks that give up from inside
# a connection. In the directory this test owns, not beside the sources.
FILE="$CONFIG/notes.db"
python3 - "$FILE" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("create table notes (id integer primary key, body text)")
c.execute("insert into notes (body) values ('still here')")
c.commit()
PY

fail() { echo "FAIL: $1" >&2; exit 1; }

# What the screen holds after these keys. The last frame is kept rather than
# quit out of, so a panel that is up is still up when it is read.
drawn() {
	target=$1; shift
	SCREEN_COLS=110 SCREEN_ROWS=24 python3 tests/screen.py "$target" "$@" '{keep}' 2>&1 || true
}

has() {
	what=$1; wanted=$2
	printf '%s' "$out" | grep -q "$wanted" || {
		echo "--- what it drew:" >&2; printf '%s\n' "$out" >&2; fail "$what"
	}
	echo "ok: $what"
}

hasnt() {
	what=$1; unwanted=$2
	printf '%s' "$out" | grep -q "$unwanted" && {
		echo "--- what it drew:" >&2; printf '%s\n' "$out" >&2; fail "$what"
	}
	echo "ok: $what"
}

# Redis sends nothing until it has been spoken to and then waits for the answer,
# so against a listener that never gives one it is stuck in a known place.
out=$(drawn "redis://127.0.0.1:$PORT/0" '{sleep}')
has "a connection that takes a while says so" "connecting"
has "and says how to stop waiting" "esc gives up"
has "the panel names what is being opened" "redis://127.0.0.1:$PORT/0"
has "and the step it is waiting on" "waiting for 127.0.0.1 to answer"

# libpq asks for TLS first and waits to hear whether it may, which is as far as
# this one gets - or, built without TLS, sends its startup packet and waits for
# the server to ask who it is. Either way the step comes from inside libpq.
PG_STEP='TLS handshake with 127.0.0.1\|logging in as app'
out=$(drawn "postgres://app:tajne-heslo@127.0.0.1:$PORT/db" '{sleep}')
has "postgres says which step it is on" "$PG_STEP"
has "the panel shows the target" "postgres://app@127.0.0.1:$PORT/db"
hasnt "without the password in it" "tajne-heslo"

out=$(drawn "redis://127.0.0.1:$PORT/0" '{sleep}' '{esc}' '{sleep}')
has "esc gives up on it" "gave up on redis://127.0.0.1:$PORT/0"
has "and the list of connections is what is left" "connect to a database"
hasnt "with the panel gone" "esc gives up"

out=$(drawn "redis://127.0.0.1:$PORT/0" '{sleep}' '{ctrl-c}' '{sleep}')
has "ctrl+c gives up on it too" "gave up on redis://127.0.0.1:$PORT/0"

# A connect used to block with the keys queuing up behind it, and whatever was
# typed meanwhile happened once it was over. It still does: `a`, typed while the
# panel is up, opens the form for a new connection when the list comes back.
out=$(drawn "redis://127.0.0.1:$LEAVING/0" 'a' '{sleep}' '{sleep}' '{sleep}')
has "a connect that fails after a while says why" "redis closed the connection"
has "and a key typed while it was being waited for is not lost" "pick the engine"
# But not one typed before giving up: that was meant for the connection, and
# the list that comes back in its place is not what it was typed at.
out=$(drawn "redis://127.0.0.1:$PORT/0" 'a' '{sleep}' '{esc}' '{sleep}')
has "giving up says so" "gave up on redis://127.0.0.1:$PORT/0"
hasnt "and lets go of what was typed before it" "pick the engine"

# Nothing listens on port 1, so this one is over before a panel could be drawn:
# a failure that takes no time must not leave one behind.
out=$(drawn "redis://127.0.0.1:1/0" '{sleep}')
has "a refusal is still a sentence" "cannot reach redis at 127.0.0.1:1"
hasnt "and leaves no panel behind it" "esc gives up"

# From inside something that is open: giving up must leave that connection as
# it was, because nothing was closed to make room for the one that never came.
out=$(drawn "$FILE" '{sleep}' ':' "open redis://127.0.0.1:$PORT/0" '{enter}' '{sleep}' '{sleep}')
has "the panel goes over whatever was on screen" "waiting for 127.0.0.1 to answer"
has "which is still there underneath" "notes"
out=$(drawn "$FILE" '{sleep}' ':' "open redis://127.0.0.1:$PORT/0" '{enter}' '{sleep}' '{sleep}' '{esc}' '{sleep}')
has "giving up from inside a connection says so" "gave up on redis://127.0.0.1:$PORT/0"
has "and that connection is still the one on screen" "still here"

# The attempt that was given up on is still running somewhere, waiting for an
# answer that will not come. The next one must not be held up by it, and what
# the old one has to say must not turn up on the new one's panel.
out=$(drawn "redis://127.0.0.1:$PORT/0" '{sleep}' '{esc}' '{sleep}' ':' "open $FILE" '{enter}' '{sleep}')
has "a file opens after a connection was given up on" "still here"
out=$(drawn "redis://127.0.0.1:$PORT/0" '{sleep}' '{esc}' '{sleep}' \
	':' "open postgres://app@127.0.0.1:$PORT/db" '{enter}' '{sleep}' '{sleep}')
has "and so does the next attempt, with a panel of its own" "$PG_STEP"
hasnt "that the one before it does not write on" "waiting for 127.0.0.1 to answer"

echo "all good"
