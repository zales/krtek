#!/bin/sh
# Bring up an SSH server and check the SFTP driver against it:
#
#     zig build && ./tests/sftp.sh
#
# Both ways in are checked, because both are how people connect: a password and a
# key. So is the host key, which is the part that matters and the part a client
# is tempted to skip - an unknown host has to be refused, and only `insecure=1`
# may let it through.
set -e
cd "$(dirname "$0")/.."

NAME=${NAME:-krtek-sftp-test}
IMAGE=${IMAGE:-atmoz/sftp:alpine}
PORT=${PORT:-2222}
KEY=/tmp/krtek-sftp-test-key
# The same key copied on its own, which is how a key usually arrives on a machine:
# the public half stays where it was made.
LONE=/tmp/krtek-sftp-test-lone
# A home of its own, so the check below reads a known_hosts this script wrote
# and not the one belonging to whoever is running it.
HOME_DIR=/tmp/krtek-sftp-test-home
# Somewhere to put the one line of sshd configuration below.
SSHD_DIR=/tmp/krtek-sftp-test-sshd
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$KEY" "$KEY.pub" "$LONE" "$HOME_DIR" "$SSHD_DIR" /tmp/krtek-sftp-test-local' EXIT

BIN=zig-out/bin/krtek
test -x "$BIN" || { echo "$BIN is not there - zig build first" >&2; exit 1; }

# Since 9.8, OpenSSH shuts a source out for some seconds after a failed
# authentication and drops what comes next before it says hello. This suite fails
# authentication on purpose, several times, from one address - so with the
# penalty on, the checks after those fail for a reason that has nothing to do
# with what they are checking. Off here, so what is measured is the driver.
#
# krtek says what that penalty is when it meets one on a real server; there is no
# check for it, because provoking it means waiting out what it costs.
rm -rf "$SSHD_DIR"
mkdir -p "$SSHD_DIR"
# atmoz/sftp runs whatever is in /etc/sftp.d before it starts sshd.
printf '#!/bin/sh\necho "PerSourcePenalties no" >> /etc/ssh/sshd_config\n' > "$SSHD_DIR/penalties.sh"
chmod 755 "$SSHD_DIR/penalties.sh"

echo "starting $IMAGE"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "$PORT:22" \
	-v "$SSHD_DIR/penalties.sh:/etc/sftp.d/penalties.sh:ro" \
	"$IMAGE" foo:heslo:::upload >/dev/null

printf 'waiting for sshd'
until docker logs "$NAME" 2>&1 | grep -q "Server listening on 0.0.0.0"; do
	printf .
	sleep 1
done
echo " up"

rm -f "$KEY" "$KEY.pub"
ssh-keygen -t ed25519 -f "$KEY" -N '' -q
cp "$KEY" "$LONE"
docker exec "$NAME" sh -c 'mkdir -p /home/foo/.ssh && chmod 700 /home/foo/.ssh'
docker cp "$KEY.pub" "$NAME:/home/foo/.ssh/authorized_keys" >/dev/null
docker exec "$NAME" sh -c '
	chown -R foo /home/foo/.ssh && chmod 600 /home/foo/.ssh/authorized_keys
	mkdir -p /home/foo/upload/2015 /home/foo/upload/podadresar
	for i in $(seq -w 1 12); do echo "zaznam $i" > /home/foo/upload/2015/soubor-$i.txt; done
	# A name with a space in it, and one that sorts first so a listing shows it.
	echo ahoj > "/home/foo/upload/0 august trip.txt"
	head -c 4096 /dev/zero > /home/foo/upload/velky.bin
	chown -R foo /home/foo/upload'

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

ROOT="sftp://foo:heslo@127.0.0.1:$PORT/upload?insecure=1"

check "a password gets in" "$ROOT" "connected: foo@127.0.0.1:/upload"
check "and so does a key" \
	"sftp://foo@127.0.0.1:$PORT/upload?insecure=1&key=$KEY" "connected: foo@127.0.0.1:/upload"
check "even a key with no .pub next to it" \
	"sftp://foo@127.0.0.1:$PORT/upload?insecure=1&key=$LONE" "connected: foo@127.0.0.1:/upload"
check "the directory is the table" "$ROOT" "table /upload.upload"
# A directory is what a schema is here, so the tree is walked with #.
check "and the directories around it are the schemas" "$ROOT" "schema /upload/2015"
check "a file is addressed by its name" "$ROOT" "row key: name (usable=true)"
check "a listing has what ls has" "$ROOT" "mode=drwxr-xr-x"
check "a name with a space in it comes back whole" "$ROOT" "0 august trip.txt"
check "the count is exact, because the listing is all here" "$ROOT" "exact=4"
check "paging covers everything exactly once" "$ROOT" "paged: 4 records, 4 distinct"

# The host key is the point of the exercise: known means in, unknown means out.
# Both halves are checked, because checking only the refusal is how a driver ends
# up refusing everybody - which is exactly what happened.
rm -rf "$HOME_DIR"
mkdir -p "$HOME_DIR/.ssh"
ssh-keyscan -p "$PORT" 127.0.0.1 > "$HOME_DIR/.ssh/known_hosts" 2>/dev/null
test -s "$HOME_DIR/.ssh/known_hosts" || fail "ssh-keyscan brought back nothing"

out=$(HOME="$HOME_DIR" zig build dbcheck -- "sftp://foo:heslo@127.0.0.1:$PORT/upload" 2>&1 || true)
printf '%s' "$out" | grep -q "connected: foo@127.0.0.1:/upload" || {
	echo "--- what came back:" >&2
	printf '%s\n' "$out" >&2
	fail "a host that is in known_hosts connects"
}
echo "ok: a host that is in known_hosts connects"

check "an unknown host is refused, with its fingerprint" \
	"sftp://foo:heslo@127.0.0.1:$PORT/upload" "known_hosts"
check "a file is not a directory" \
	"sftp://foo:heslo@127.0.0.1:$PORT/upload/velky.bin?insecure=1" "is a file, not a directory"
check "a directory that is not there says so" \
	"sftp://foo:heslo@127.0.0.1:$PORT/neexistuje?insecure=1" "there is nothing there"

# --- and the file manager, which is the only way the copying is reachable ---
#
# Driven through the pty harness rather than called directly, because what is
# worth checking is that the keys reach the copy and the copy reaches the far
# end - the parts either side of the transfer are where the mistakes were.
#
# The cursor is moved by counting, so each side is arranged to have exactly the
# entries these counts assume: a check that works because of how a listing
# happened to sort is a check that fails on the next change.
LOCAL=/tmp/krtek-sftp-test-local
rm -rf "$LOCAL"
mkdir -p "$LOCAL/strom/hloubeji" "$LOCAL/dolu"
echo ahoj > "$LOCAL/strom/jedna.txt"
echo nazdar > "$LOCAL/strom/hloubeji/dva.txt"

TARGET="sftp://foo:heslo@127.0.0.1:$PORT/upload?insecure=1"

# Down: the remote 2015 directory onto this machine, with everything in it.
# On the far side: .. 2015 podadresar, so one step down is 2015.
out=$(tests/screen.py "$TARGET" \
	"{sleep}f{sleep}/$LOCAL/dolu{enter}{sleep}{tab}{down}c{sleep}{keep}" 2>/dev/null || true)
test -f "$LOCAL/dolu/2015/soubor-01.txt" || {
	printf '%s\n' "$out" >&2
	fail "a directory comes down whole"
}
test "$(cat "$LOCAL/dolu/2015/soubor-12.txt")" = "zaznam 12" || fail "and arrives with what was in it"
echo "ok: a directory comes down whole, and arrives with what was in it"

# Up: a tree of directories from this machine to the server.
# On this side: .. dolu strom, so two steps down is strom.
out=$(tests/screen.py "$TARGET" \
	"{sleep}f{sleep}/$LOCAL{enter}{sleep}{down}{down}c{sleep}{keep}" 2>/dev/null || true)
docker exec "$NAME" test -f /home/foo/upload/strom/hloubeji/dva.txt || {
	printf '%s\n' "$out" >&2
	fail "a tree goes up whole"
}
test "$(docker exec "$NAME" cat /home/foo/upload/strom/hloubeji/dva.txt)" = "nazdar" ||
	fail "and lands with what was in it"
echo "ok: a tree goes up whole, and lands with what was in it"

# And removing one on the far side takes what is under it.
# On the far side now: .. 2015 podadresar strom, so three steps down is strom.
out=$(tests/screen.py "$TARGET" \
	"{sleep}f{sleep}{tab}{down}{down}{down}x{sleep}y{enter}{sleep}{keep}" 2>/dev/null || true)
if docker exec "$NAME" test -e /home/foo/upload/strom; then
	printf '%s\n' "$out" >&2
	fail "a tree is removed with everything under it"
fi
echo "ok: a tree is removed with everything under it"

# A copy that would write over something asks first. This is the one thing here
# that destroys without saying so - the name is the same on both sides, so the
# file that was there is simply gone - and removing has always asked.
#
# On this side: .. dolu strom, and `strom` went up a moment ago, so sending it
# again is a copy onto something that is there.
rm -rf "$LOCAL/znovu"
mkdir -p "$LOCAL/znovu"
echo ahoj > "$LOCAL/znovu/jedna.txt"
tests/screen.py "$TARGET" \
	"{sleep}f{sleep}/$LOCAL/znovu{enter}{sleep}{down}c{sleep}" >/dev/null 2>&1
out=$(tests/screen.py "$TARGET" \
	"{sleep}f{sleep}/$LOCAL/znovu{enter}{sleep}{down}c{sleep}{keep}" 2>&1 || true)
printf '%s' "$out" | grep -q "already there" || {
	printf '%s\n' "$out" >&2
	fail "a copy onto a file that is there should ask before writing over it"
}
echo "ok: a copy that would write over something asks first"

# And a name that is not taken goes straight through, because a question nobody
# needs is a question that teaches people to answer without reading.
#
# Named to sort before `jedna.txt`, so one step down is the free one whatever
# order it was made in: a listing is alphabetical and a check that counts on
# anything else is a check that fails the next time somebody adds a file.
echo nazdar > "$LOCAL/znovu/a-nove.txt"
out=$(tests/screen.py "$TARGET" \
	"{sleep}f{sleep}/$LOCAL/znovu{enter}{sleep}{down}c{sleep}{keep}" 2>&1 || true)
printf '%s' "$out" | grep -q "copied 1 file" || {
	printf '%s\n' "$out" >&2
	fail "a copy onto a free name should not ask"
}
echo "ok: a copy onto a free name does not ask"

# --- what a refused login says, which has to come last ---
#
# Everything that fails to authenticate goes here, and nothing follows it: since
# 9.8 OpenSSH shuts a source out for some seconds after a failed authentication
# and drops what comes next before the banner. On a slow machine the checks after
# these got in anyway; on a fast one they do not, and the failure has nothing to
# do with what they were checking.
check "a wrong password says so" \
	"sftp://foo:spatne@127.0.0.1:$PORT/upload?insecure=1" "password for foo was not accepted"
# And when there is nothing to log in with, the word "password" is what makes the
# interface offer one.
check "no credentials asks for a password" \
	"sftp://nikdo@127.0.0.1:$PORT/upload?insecure=1" "password"

# --- the password prompt, which is where those two messages end up ---
#
# The driver saying the right thing is only half of it: the interface decides
# whether to ask for a password by looking for the word in the message, and both
# "you gave me none" and "the one you gave me is wrong" have it. Answering the
# second with "the server wants a password" is what a form that does not work
# looks like from the outside.
ASK="sftp://foo@127.0.0.1:$PORT/upload?insecure=1"

out=$(tests/screen.py "$ASK" "{sleep}{keep}" 2>&1 || true)
printf '%s' "$out" | grep -q "the server wants a password" || {
	printf '%s\n' "$out" >&2
	fail "nothing to log in with should ask for a password"
}
echo "ok: nothing to log in with asks for a password"

out=$(tests/screen.py "$ASK" "{sleep}{sleep}spatne{enter}{sleep}{keep}" 2>&1 || true)
printf '%s' "$out" | grep -q "was not accepted" || {
	printf '%s\n' "$out" >&2
	fail "a refused password should say it was refused, not ask again in silence"
}
printf '%s' "$out" | grep -q "password:" || fail "and should leave the prompt up to try again"
echo "ok: a refused password says so, and can be typed again"

# Enter at the prompt with nothing typed. There is no password to try, so the
# answer is the question again - and what it must not be is a target made of the
# bytes `clearRetainingCapacity` leaves behind, which is what it was.
out=$(tests/screen.py "$ASK" "{sleep}{enter}{sleep}{keep}" 2>&1 || true)
printf '%s' "$out" | grep -q "the server wants a password" || {
	printf '%s\n' "$out" >&2
	fail "an empty password should ask again"
}
printf '%s' "$out" | grep -q "cannot open" && fail "and should not connect to whatever was left in the buffer"
echo "ok: an empty password asks again rather than connecting to nothing"

# And the right password after a wrong one, which is the retry actually working:
# the second attempt has to go in on its own, because adding a password to a
# target that has one leaves both in it.
out=$(tests/screen.py "$ASK" "{sleep}heslo{enter}{sleep}{keep}" 2>&1 || true)
printf '%s' "$out" | grep -q "SFTP (libssh2" || {
	printf '%s\n' "$out" >&2
	fail "the right password after a wrong one should get in"
}
echo "ok: the right password after a wrong one gets in"

echo "all good"
