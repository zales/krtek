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
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$KEY" "$KEY.pub" "$LONE" "$HOME_DIR"' EXIT

BIN=zig-out/bin/krtek
test -x "$BIN" || { echo "$BIN is not there - zig build first" >&2; exit 1; }

echo "starting $IMAGE"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "$PORT:22" "$IMAGE" foo:heslo:::upload >/dev/null

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
check "a wrong password says so" \
	"sftp://foo:spatne@127.0.0.1:$PORT/upload?insecure=1" "password for foo was not accepted"
# And when there is nothing to log in with, the word "password" is what makes the
# interface offer one.
check "no credentials asks for a password" \
	"sftp://nikdo@127.0.0.1:$PORT/upload?insecure=1" "password"
check "a file is not a directory" \
	"sftp://foo:heslo@127.0.0.1:$PORT/upload/velky.bin?insecure=1" "is a file, not a directory"
check "a directory that is not there says so" \
	"sftp://foo:heslo@127.0.0.1:$PORT/neexistuje?insecure=1" "there is nothing there"

echo "all good"
