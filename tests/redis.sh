#!/bin/sh
# Bring up a Redis and check the driver against it:
#
#     zig build && ./tests/redis.sh
#
# The protocol reader is tested without a server - the unit tests hand it bytes
# on a socket pair. What they cannot hand it is a TLS session, which is what
# this is here for: one Redis with two ports, one in the clear and one that
# only speaks TLS, so that whatever arrives through the second arrived
# encrypted or did not arrive at all. `redis-cli` from the same image is the
# other side of every exchange, and it reads in the clear what krtek wrote
# through TLS.
#
# The certificate is signed by an authority made here and issued to
# `localhost`, which gives the three answers a certificate can get: refused
# when nobody knows who signed it, accepted when the authority is trusted and
# the name is the one on it, and refused again for the same server under a
# name that is not.
#
# And a second server beside it that wants a certificate from the client as
# well, which is how Redis comes once TLS is turned on and nothing else is
# said. This driver has none to give, so what is checked there is that the
# refusal says so.
#
# And a third that is what a hosted one is like: CONFIG renamed away, and then
# INFO taken from the user as well. Those are what a new connection asks first,
# and a server that answers them with an error has to open like any other.
set -e
cd "$(dirname "$0")/.."

NAME=${NAME:-krtek-redis-test}
IMAGE=${IMAGE:-redis:7-alpine}
PORT=${PORT:-6390}
TLS_PORT=${TLS_PORT:-6391}
MUTUAL_PORT=${MUTUAL_PORT:-6392}
HOSTED_PORT=${HOSTED_PORT:-6393}

BIN=zig-out/bin/krtek
test -x "$BIN" || { echo "$BIN is not there - zig build first" >&2; exit 1; }

# A configuration of its own: the app remembers every connection it opens.
CONFIG=$(mktemp -d)
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$CONFIG"' EXIT
export XDG_CONFIG_HOME="$CONFIG"

# An authority, and a certificate it signs for `localhost` and nothing else.
# Made here because the image has no openssl in it, and good for a day.
{
	openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=krtek test CA" \
		-keyout "$CONFIG/ca.key" -out "$CONFIG/ca.crt" &&
	openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" \
		-keyout "$CONFIG/server.key" -out "$CONFIG/server.csr" &&
	printf 'subjectAltName=DNS:localhost\n' > "$CONFIG/san.ext" &&
	openssl x509 -req -in "$CONFIG/server.csr" -CA "$CONFIG/ca.crt" -CAkey "$CONFIG/ca.key" \
		-CAcreateserial -days 1 -extfile "$CONFIG/san.ext" -out "$CONFIG/server.crt"
} >/dev/null 2>&1 || { echo "openssl could not make a certificate" >&2; exit 1; }

echo "starting $IMAGE"
docker rm -f "$NAME" >/dev/null 2>&1 || true
# The certificate goes in through the environment and is written by the user
# that will read it: a key somebody else owns is one the server may not open.
# Without `tls-auth-clients no` Redis wants a certificate from the client too,
# which is what the second server is left wanting; the authority it would check
# one against only has to be a certificate, so it is the server's own.
docker run -d --name "$NAME" -p "$PORT:6379" -p "$TLS_PORT:6380" -p "$MUTUAL_PORT:6381" -p "$HOSTED_PORT:6382" \
	-e "TLS_CERT=$(cat "$CONFIG/server.crt")" -e "TLS_KEY=$(cat "$CONFIG/server.key")" \
	"$IMAGE" sh -c '
	umask 077
	printf "%s\n" "$TLS_CERT" > /tmp/server.crt
	printf "%s\n" "$TLS_KEY" > /tmp/server.key
	redis-server --port 0 --tls-port 6381 --daemonize yes \
		--tls-cert-file /tmp/server.crt --tls-key-file /tmp/server.key \
		--tls-ca-cert-file /tmp/server.crt --save "" --appendonly no
	redis-server --port 6382 --daemonize yes --rename-command CONFIG "" \
		--save "" --appendonly no
	exec redis-server --port 6379 --tls-port 6380 \
		--tls-cert-file /tmp/server.crt --tls-key-file /tmp/server.key \
		--tls-auth-clients no --save "" --appendonly no' >/dev/null

# The other client, always in the clear.
cli() { docker exec "$NAME" redis-cli "$@"; }
# And the same to the server that has no CONFIG.
hosted() { docker exec "$NAME" redis-cli -p 6382 "$@"; }

printf 'waiting for the server'
until cli PING >/dev/null 2>&1 && hosted PING >/dev/null 2>&1; do
	printf .
	sleep 1
done
echo " up"

cli SET user:1 ada >/dev/null
cli SET user:2 grace EX 3600 >/dev/null
cli HSET cart:7 apples 3 pears 2 >/dev/null
cli RPUSH queue a b c >/dev/null
# One key in a database of its own, so that the first row of the grid is it.
cli -n 3 SET pozdrav ahoj >/dev/null
# A value of many TLS records and several reads, none of which ends where a
# reply does: 300 000 bytes, and not all one letter, so that a piece lost or
# read twice is a different value.
big() { awk 'BEGIN { for (i = 0; i < 37500; i++) printf "%07d;", i }'; }
docker exec "$NAME" sh -c "awk 'BEGIN { for (i = 0; i < 37500; i++) printf \"%07d;\", i }' | redis-cli -n 4 -x SET big" >/dev/null
# And a listing that is one: three thousand keys.
docker exec "$NAME" sh -c 'i=0; while [ $i -lt 3000 ]; do echo "SET klic:$i hodnota-$i"; i=$((i+1)); done | redis-cli -n 5' >/dev/null

CLEAR="redis://127.0.0.1:$PORT"
SECURE="rediss://127.0.0.1:$TLS_PORT"
NAMED="rediss://localhost:$TLS_PORT"

# --- and now the driver ---

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

check() {
	what=$1
	target=$2
	wanted=$3
	out=$(zig build dbcheck -- "$target" 2>&1 || true)
	printf '%s' "$out" | grep -qE "$wanted" || {
		echo "--- what came back:" >&2
		printf '%s\n' "$out" | cut -c1-300 >&2
		fail "$what"
	}
	echo "ok: $what"
}

check "it connects, and the server says what it is" "$CLEAR" "connected: 127.0.0.1:$PORT/0 / Redis [0-9]"
check "the keys are one table" "$CLEAR" 'table 0\.data rows~4 '
check "and the connection is said not to be encrypted" "$CLEAR" 'encryption = none'

# Over TLS: on a port that takes nothing else, so connecting at all is the
# proof that the handshake was made and everything after it went through it.
check "TLS, to a certificate the target says not to check" "$SECURE?insecure=1" "connected: 127.0.0.1:$TLS_PORT/0 / Redis [0-9]"
check "and the same keys arrive through it" "$SECURE?insecure=1" 'table 0\.data rows~4 '
check "which the settings say, and that nobody looked at the certificate" "$SECURE?insecure=1" 'encryption = TLSv1\.[23], certificate not checked'
check "the database in the target is the one opened" "$SECURE/3?insecure=1" "connected: 127.0.0.1:$TLS_PORT/3"

check "a certificate signed by nobody known is refused" "$NAMED" "open failed: .*(certificate|TLS)"
export SSL_CERT_FILE="$CONFIG/ca.crt"
check "with its authority trusted and its own name asked for, it is accepted" "$NAMED" "connected: localhost:$TLS_PORT/0"
check "and then the settings say TLS and nothing more" "$NAMED" 'encryption = TLSv1\.[23]$'
check "the same server under a name the certificate does not carry is refused" "$SECURE" "open failed: .*(certificate|TLS)"
unset SSL_CERT_FILE

# The scheme used to be thrown away, so this is what a rediss:// target got:
# a conversation in the clear with a port that only speaks TLS.
check "the clear on a port that wants TLS says what to try" "redis://127.0.0.1:$TLS_PORT" "redis closed the connection - if it wants TLS, that is rediss://"
check "nothing listening says so, whichever was asked for" "rediss://127.0.0.1:1" "cannot reach redis at 127.0.0.1:1"
# The handshake is let through and the refusal comes after it, as an alert:
# without that alert in the message this was a connection closed for no reason.
check "a server that wants a certificate from the client is quoted saying so" "rediss://127.0.0.1:$MUTUAL_PORT?insecure=1" "open failed: redis closed the connection: .*certificate required"

# A server with CONFIG renamed away, which is how the hosted ones come. How
# many databases it has is the third thing a new connection asks, the answer
# was an error, and the error was read as the list that had been asked for:
# the program ended there, on every one of them. The count is the last of the
# settings, which dbcheck prints after everything it reads, so it also says
# that the rest was got through.
HOSTED="redis://127.0.0.1:$HOSTED_PORT"
hosted CONFIG GET databases 2>&1 | grep -q "unknown command" || fail "the server that should have no CONFIG has one"
hosted SET user:1 ada >/dev/null
hosted HSET cart:7 apples 3 pears 2 >/dev/null
check "a server with no CONFIG opens" "$HOSTED" "connected: 127.0.0.1:$HOSTED_PORT/0 / Redis [0-9]"
check "with the keys it has" "$HOSTED" 'table 0\.data rows~2 '
check "and the sixteen databases Redis has unless it is told otherwise" "$HOSTED" 'databases = 16$'
# And with INFO not among what the user may run, which an ACL can see to.
hosted ACL SETUSER default -info >/dev/null
check "one that will not say what it is opens as well, as a Redis of no known version" "$HOSTED" "connected: 127.0.0.1:$HOSTED_PORT/0 / Redis [?]\$"
check "and its keys are read all the same" "$HOSTED" 'row key=cart:7  type=hash  ttl=-1  value=apples=3, pears=2'

# What dbcheck prints of the first rows is the whole value, so this is every
# byte of it as it came through the encryption.
came=$(zig build dbcheck -- "$SECURE/4?insecure=1" 2>&1 | sed -n 's/^  row key=big  type=string  ttl=-1  value=\(.*\)  $/\1/p')
test "$(printf '%s' "$came" | cksum)" = "$(big | cksum)" ||
	fail "a value of 300 000 bytes is not what it was after coming through TLS (${#came} bytes came)"
echo "ok: a value of 300 000 bytes comes through TLS as it went in"
check "three thousand keys are counted through TLS" "$SECURE/5?insecure=1" 'table 5\.data rows~3000 '
check "and paged through it, each of them once" "$SECURE/5?insecure=1" 'paged: 200 records, 200 distinct'

# A password, which is the thing that went out in the clear when the second s
# was ignored. With characters a URL has other uses for.
cli CONFIG SET requirepass 'ta&j=ne' >/dev/null
check "a server that wants a password says so through TLS" "$SECURE?insecure=1" "open failed: NOAUTH"
check "a wrong one is refused" "rediss://:spatne@127.0.0.1:$TLS_PORT?insecure=1" "open failed: WRONGPASS"
check "the right one in the address" "rediss://:ta%26j%3Dne@127.0.0.1:$TLS_PORT?insecure=1" "connected: 127.0.0.1:$TLS_PORT/0"
check "and beside the option, where the app puts the one it was typed" "$SECURE/3?insecure=1&password=ta%26j%3Dne" "connected: 127.0.0.1:$TLS_PORT/3"

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

# The password asked for and typed, on a target that already has an option.
screen "$SECURE/3?insecure=1" '{wait}' 'ta&j=ne' '{enter}' '{wait}' '{keep}'
shows "a password typed at the prompt opens it, through TLS" 'pozdrav +string +-1 +ahoj'
cli -a 'ta&j=ne' --no-auth-warning CONFIG SET requirepass '' >/dev/null

# With a wait, because nothing is typed that would take the time for it: the
# first start of a binary and a handshake are both in front of the first frame.
screen "$SECURE/3?insecure=1" '{wait}' '{wait}' '{keep}'
shows "the first screen is the keys, through TLS" 'pozdrav +string +-1 +ahoj'
shows "and the server's version is in the header" "127.0.0.1:$TLS_PORT/3 .*Redis [0-9]"

# The whole value of a cell is that cell's. `gv` asks the server again for the
# one column the cursor is on and shows the first cell of what comes back - and
# what came back was the whole row, so the box said `value` along the top and
# had the key inside. `yc` copies what `gv` shows, and copied the key.
whole() {
	grep -A1 "$1 ─ enter/esc closes" "$SCREEN" | tail -1 | sed 's/\(.*\)│.*$/\1/; s/ *$//; s/^.*│ //'
}
screen "$SECURE/3?insecure=1" '{tab}' '{right}' '{right}' '{right}' g v '{wait}' '{keep}'
test "$(whole value)" = "ahoj" || {
	cat "$SCREEN" >&2
	fail "gv on the value of pozdrav should show ahoj, and shows '$(whole value)'"
}
echo "ok: gv shows the value under the cursor, and not the key of its row"
screen "$SECURE/3?insecure=1" '{tab}' '{right}' '{right}' '{right}' y c '{wait}' '{keep}'
shows "and yc copies it" '^CLIPBOARD: ahoj$'

# In through TLS, and read back by a client that is not this one and does not
# use it. Four letters out, six in.
screen "$SECURE/3?insecure=1" '{tab}' '{right}' '{right}' '{right}' e '{bs}' '{bs}' '{bs}' '{bs}' 'nazdar' '{enter}' '{keep}'
shows "a value changed in the grid is written" ' updated'
test "$(cli -n 3 GET pozdrav)" = "nazdar" || fail "the changed value is not what the server holds"
echo "ok: and the server holds the new one"

screen "$SECURE/3?insecure=1" s 'SET z:konzole ano' '{ctrl-s}' '{keep}'
test "$(cli -n 3 GET z:konzole)" = "ano" || fail "a command typed in the console did not reach the server"
echo "ok: a command from the console reaches the server through TLS"

# An answer that takes its time. The socket gives up waiting every 400 ms so
# that the app can be asked whether to carry on, and through TLS that giving
# up looks like something else than it does on a bare socket: mistaken for a
# failure, the connection would be called lost a moment into any wait.
(sleep 2; cli -n 3 RPUSH fronta prisel >/dev/null) &
screen "$SECURE/3?insecure=1" s 'BLPOP fronta 8' '{ctrl-s}' '{wait}' '{wait}' '{wait}' '{wait}' '{wait}' '{wait}' '{wait}' '{wait}' '{keep}'
wait
shows "an answer that arrives after several waits is still read" 'prisel'

# The form. A saved connection is taken apart into its fields and put together
# again on saving, and TLS is one of them: five fields down from the name.
connections() {
	printf '# krtek connections\n%s\t%s\n' "$1" "$2" > "$CONFIG/krtek/connections"
}
mkdir -p "$CONFIG/krtek"
connections cache "redis://127.0.0.1:$PORT/3"
screen '' e '{keep}'
shows "the form for a Redis has a TLS toggle, off for redis://" '\[ \] TLS'
screen '' e '{tab}' '{tab}' '{tab}' '{tab}' '{tab}' ' ' '{ctrl-s}' '{keep}'
grep -q "^cache	rediss://127.0.0.1:$PORT/3\$" "$CONFIG/krtek/connections" || {
	cat "$CONFIG/krtek/connections" >&2
	fail "turning TLS on in the form did not save a rediss:// target"
}
echo "ok: turning it on saves the target as rediss://"

connections cache "rediss://127.0.0.1:$TLS_PORT/3"
screen '' e '{keep}'
shows "and it is on for rediss://" '\[x\] TLS'
screen '' e '{tab}' '{tab}' '{tab}' '{tab}' '{bs}' '5' '{ctrl-s}' '{keep}'
grep -q "^cache	rediss://127.0.0.1:$TLS_PORT/5\$" "$CONFIG/krtek/connections" || {
	cat "$CONFIG/krtek/connections" >&2
	fail "changing the database in the form lost the TLS of a rediss:// target"
}
echo "ok: changing another field keeps it"

# --- a connection that is lost ---

# Sixteen waits: long enough for whatever is done to the server behind them to
# be over before the next key is pressed.
LATER="{wait} {wait} {wait} {wait} {wait} {wait} {wait} {wait} {wait} {wait} {wait} {wait} {wait} {wait} {wait} {wait}"

# Hung up on, with the server still there: every client but the one that asks
# is thrown out, which is what an idle timeout does and a restart does not -
# the data stays, and so does the password, so what comes next is only let in
# by a connection that said it again. Through TLS, in database 3, and by way of
# the console, whose commands are never sent twice: the connection has to be
# found gone before the command is written, and made again there. The command
# is one that shows if it was done more than once, or somewhere else.
cli CONFIG SET requirepass 'ta&j=ne' >/dev/null
secret() { cli -a 'ta&j=ne' --no-auth-warning "$@"; }
(sleep 3; secret CLIENT KILL TYPE normal >/dev/null; secret -n 3 SET po:odpojeni ano >/dev/null) &
cutting=$!
# shellcheck disable=SC2086
screen "$SECURE/3?insecure=1&password=ta%26j%3Dne" $LATER s 'INCR z:pocet' '{ctrl-s}' '{tab}' '{enter}' '{wait}' '{keep}'
wait "$cutting"
test "$(secret -n 3 GET z:pocet)" = "1" ||
	fail "a command typed after the connection was cut was not done once in database 3 (it holds '$(secret -n 3 GET z:pocet)', and database 0 '$(secret GET z:pocet)')"
echo "ok: a command typed after the connection was cut is done once, in the database that was open"
shows "and what was written meanwhile is read over the new connection, password and TLS and all" 'po:odpojeni +string +-1 +ano'
secret CONFIG SET requirepass '' >/dev/null

# The server goes away under an open connection and comes back, and `r` is
# pressed: the case this was written for, where the screen said `reloaded` over
# a table of no rows and went on saying it. The server keeps nothing on disk,
# so it comes back empty, and what the reload shows is what was put in after
# the restart - in database 3, which a connection made again is only in if it
# was told so again.
#
# Nothing waits on the clock for the server to be back: the restart is over
# before the reload is pressed.
(sleep 3; docker restart -t 1 "$NAME" >/dev/null; until cli PING >/dev/null 2>&1; do sleep 0.2; done
	cli -n 3 SET po:restartu ano >/dev/null) &
restarting=$!
# shellcheck disable=SC2086
screen "$CLEAR/3" $LATER r '{wait}' '{keep}'
wait "$restarting"
shows "a reload after the server restarted reads what it holds now" 'po:restartu +string +-1 +ano'
shows "and says that it did" '^ reloaded'
grep -q "pozdrav" "$SCREEN" && fail "the screen still shows a key the server lost in the restart"
echo "ok: and what it held before is gone from the screen"

# And one that does not come back. The counts have nothing to say and the rows
# have a reason, which is what the screen is left with - not `reloaded`.
(sleep 3; docker stop -t 1 "$NAME" >/dev/null) &
stopping=$!
# shellcheck disable=SC2086
screen "$CLEAR/3" $LATER r '{wait}' '{keep}'
wait "$stopping"
shows "a server that is gone and stays gone is said to be" "the connection to redis at 127.0.0.1:$PORT was lost, and it cannot be reached again"
shows "and the table is not called empty" 'could not be read - r tries again'
grep -q "reloaded" "$SCREEN" && fail "the screen says reloaded over a server that is not there"
echo "ok: and nothing says reloaded"

echo "all good"
