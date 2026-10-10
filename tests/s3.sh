#!/bin/sh
# Bring up a Garage and check the S3 driver against it:
#
#     zig build && ./tests/s3.sh
#
# Garage rather than Amazon on purpose: it wants path-style addressing and it
# has a region of its own that nobody told the driver about, which is where a
# driver written only against AWS falls over. The signature is the same either
# way - if Garage accepts it, Amazon does, and the unit tests already check it
# against Amazon's own worked examples.
#
# Thirteen objects in one bucket, because a page is four in the check below: the
# pages have to cover everything exactly once, which is what a continuation token
# is for and what an offset would get wrong.
set -e
cd "$(dirname "$0")/.."

NAME=${NAME:-krtek-s3-test}
# A release by its number: there is no `latest` to follow, and a server that
# changes under the suite is a failure nobody caused.
IMAGE=${IMAGE:-dxflrs/garage:v2.4.1}
WORK=$(mktemp -d)
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

# Not secrets: made up here, in the only shape Garage takes - GK and twenty-four
# hex digits for the key, sixty-four for the secret.
KEY=GK0123456789abcdef01234567
SECRET=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

BIN=zig-out/bin/krtek
test -x "$BIN" || { echo "$BIN is not there - zig build first" >&2; exit 1; }

# Everything one node needs to be a cluster of one. The image has no shell in it
# to write this with, so it is copied in before the server starts.
cat >"$WORK/garage.toml" <<'TOML'
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "sqlite"
replication_factor = 1
rpc_bind_addr = "0.0.0.0:3901"
rpc_secret = "0000000000000000000000000000000000000000000000000000000000000000"

[s3_api]
s3_region = "garage"
api_bind_addr = "0.0.0.0:3900"
TOML

echo "starting $IMAGE"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker create --name "$NAME" -p 9000:3900 \
	-e GARAGE_DEFAULT_ACCESS_KEY="$KEY" -e GARAGE_DEFAULT_SECRET_KEY="$SECRET" \
	-e GARAGE_DEFAULT_BUCKET=photos \
	"$IMAGE" /garage server --single-node --default-bucket >/dev/null
docker cp "$WORK/garage.toml" "$NAME:/etc/garage.toml" >/dev/null
docker start "$NAME" >/dev/null

# Nobody is let in without a key, so a 403 is the server saying it is there. A
# server that went away instead is a failure and not a wait.
printf 'waiting for the server'
until curl -s -o /dev/null http://127.0.0.1:9000/; do
	test "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true || {
		echo " gone" >&2
		docker logs --tail 20 "$NAME" >&2 || true
		exit 1
	}
	printf .
	sleep 1
done
echo " up"

# Garage's own tool, which reports every connection it makes on the way: worth
# reading only when it fails.
garage() {
	said=$(docker exec "$NAME" /garage "$@" 2>&1) || {
		printf '%s\n' "$said" >&2
		exit 1
	}
}

# The second bucket, and the key let into it: a key lists what it was given and
# nothing else.
garage bucket create druhy
garage bucket allow --read --write --owner druhy --key "$KEY"

# Seeded with a signature of its own making, so the seeding does not depend on
# the thing being tested.
python3 - "$KEY" "$SECRET" <<'PY'
import datetime, hashlib, hmac, subprocess, sys
KEY, SECRET = sys.argv[1], sys.argv[2]
HOST = "127.0.0.1:9000"

def mac(key, text):
	return hmac.new(key, text.encode(), hashlib.sha256).digest()

def put(path, body):
	when = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
	digest = hashlib.sha256(body.encode()).hexdigest()
	scope = f"{when[:8]}/garage/s3/aws4_request"
	signed = "host;x-amz-content-sha256;x-amz-date"
	canon = "\n".join(["PUT", path, "",
		f"host:{HOST}", f"x-amz-content-sha256:{digest}", f"x-amz-date:{when}", "",
		signed, digest])
	sts = "\n".join(["AWS4-HMAC-SHA256", when, scope, hashlib.sha256(canon.encode()).hexdigest()])
	key = ("AWS4" + SECRET).encode()
	for part in scope.split("/"):
		key = mac(key, part)
	subprocess.run(["curl", "-sf", "-o", "/dev/null", "-X", "PUT",
		"-H", f"x-amz-date: {when}", "-H", f"x-amz-content-sha256: {digest}",
		"-H", f"Authorization: AWS4-HMAC-SHA256 Credential={KEY}/{scope}, "
			f"SignedHeaders={signed}, Signature={mac(key, sts).hex()}",
		"--data-binary", body, f"http://{HOST}{path}"], check=True)

for i in range(1, 13):
	put(f"/photos/2015/soubor-{i:02d}.txt", f"zaznam {i}\n")
# A key with a space in it: it travels percent-encoded and has to come back as
# it was, which is what encoding-type=url is asked for.
put("/photos/august%20trip.txt", "ahoj\n")
PY

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

ROOT="s3+http://$KEY:$SECRET@127.0.0.1:9000"

check "a bucket named in the target" "$ROOT/photos" "connected: 127.0.0.1/photos"
# Garage sends no Server header. What it speaks is all there is to call it.
check "a server that does not say who it is" "$ROOT/photos" "127.0.0.1/photos / S3"
check "every bucket, when none is named" "$ROOT" "table .druhy"
check "a key is a row key" "$ROOT/photos" "row key: key (usable=true)"

# Thirteen objects over four-object pages: every key exactly once, which is the
# continuation token doing its job. An offset would have skipped or repeated.
check "pages neither overlap nor skip" "$ROOT/photos" "paged: 13 records, 13 distinct" photos

check "the addressing Garage wants" "$ROOT/photos" "addressing = path"
# Nothing above names a region, so the first request is signed for Amazon's
# default and refused. The refusal says which one it should have been.
check "the region Garage names is the one used" "$ROOT/photos" "region = garage"
check "where the key came from" "$ROOT/photos" "credentials = the target"

# The failures, which matter more than the successes: each one has to say what
# is wrong rather than a number.
check "a wrong secret says so" \
	"s3+http://$KEY:wrong@127.0.0.1:9000/photos" "Invalid signature"
check "a bucket that is not there says so" \
	"$ROOT/neexistuje" "NoSuchBucket"
check "no credentials says where to put them" \
	"s3+http://127.0.0.1:9000/photos" "no credentials were found"
# A key with no secret is the case that has to reach the password prompt, which
# the interface offers on the words "secret key" and on nothing else.
check "a key with no secret asks for one" \
	"s3+http://$KEY@127.0.0.1:9000/photos" "the secret key for $KEY is missing"
# And the retry the prompt makes: the secret arrives as ?password=, the same way
# it does for every other engine, so it can live in the keychain.
check "the secret may arrive as a password" \
	"s3+http://$KEY@127.0.0.1:9000/photos?password=$SECRET" "connected: 127.0.0.1/photos"

# --- and the screen ---
#
# The whole value of a cell is that cell's. `gv` asks the server again for the
# one column the cursor is on and shows the first cell of what comes back - and
# what came back was every column, so the box said `size` along the top and had
# the key inside. A bucket opens on the file manager, so `q` first, for the
# grid; the first object there is `zaznam 1` and a newline, nine bytes.
whole=$(python3 tests/screen.py "$ROOT/photos" '{sleep}' 'q' '{tab}' '{right}' 'g' 'v' '{sleep}' '{keep}' 2>&1 |
	grep -A1 'size ─ enter/esc closes' | tail -1 | sed 's/\(.*\)│.*$/\1/; s/ *$//; s/^.*│ //')
[ "$whole" = "9" ] || fail "gv on the size of 2015/soubor-01.txt should show 9, and shows '$whole'"
echo "ok: gv shows the value under the cursor, and not the key of its row"

# One object has one `modified`, whichever request answered for it. The grid is
# a listing, which writes the time as 2026-10-09T20:11:46.999Z; `gv` asks for
# the one key, which is a HEAD, and a HEAD says it in a header: Fri, 09 Oct 2026
# 20:11:46 GMT. That is what the box showed, over a grid that had the same time
# written the other way. It is the listing's form now, to the second - a header
# has no milliseconds, and none are made up for it.
listed=$(python3 tests/screen.py "$ROOT/photos" '{sleep}' 'q' '{sleep}' '{keep}' 2>&1 |
	grep '2015/soubor-01.txt' | head -1 | awk '{ print $4 }')
printf '%s' "$listed" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+Z$' ||
	fail "the grid should say when 2015/soubor-01.txt was modified, and says '$listed'"
whole=$(python3 tests/screen.py "$ROOT/photos" '{sleep}' 'q' '{tab}' '{right}{right}' 'g' 'v' '{sleep}' '{keep}' 2>&1 |
	grep -A1 'modified ─ enter/esc closes' | tail -1 | sed 's/\(.*\)│.*$/\1/; s/ *$//; s/^.*│ //')
[ "$whole" = "${listed%.*}Z" ] ||
	fail "gv on the modified of 2015/soubor-01.txt should show ${listed%.*}Z as the grid has it, and shows '$whole'"
echo "ok: gv writes a time the way the grid does"

# --- and the file manager ---
#
# A bucket named in the target opens on it, this machine on the left and the
# bucket on the right. An object says there when it was written, to the minute:
# the time the listing gave, which for an object put there a moment ago is about
# now - an hour out would be a zone read into a time that has none.
out=$(python3 tests/screen.py "$ROOT/photos" '{sleep}' '{keep}' 2>&1 || true)
facts=$(zig build dbcheck -- "$ROOT/photos" photos 2>&1 | grep 'file august trip.txt listed: ' || true)
listed=$(printf '%s' "$facts" | sed -n 's/.* listed: size=5 modified=\([0-9]*\) asked: .*/\1/p')
asked=$(printf '%s' "$facts" | sed -n 's/.* asked: size=5 modified=\([0-9]*\)$/\1/p')
[ -n "$listed" ] && [ "$listed" -gt 0 ] || fail "a listing should say when an object was modified, and says: $facts"
age=$(($(date +%s) - listed))
[ "$age" -gt -1800 ] && [ "$age" -lt 1800 ] || fail "an object written just now is said to be $age seconds old"
shown=$(printf '%s\n' "$out" | sed -n 's/.*august trip\.txt  *5 \([0-9-]* [0-9:]*\).*/\1/p' | head -1)
wanted=$(python3 -c 'import sys, time; print(time.strftime("%Y-%m-%d %H:%M", time.gmtime(int(sys.argv[1]))))' "$listed")
[ "$shown" = "$wanted" ] || {
	printf '%s\n' "$out" >&2
	fail "the file manager should say august trip.txt was modified $wanted, and says '$shown'"
}
echo "ok: an object says when it was modified in the file manager"
# A copy asks about one object by name before it starts, which is a HEAD and
# not a listing: the time comes in a header, written another way and to the
# second. That is the same object and has to be the same second.
[ "$asked" = "$listed" ] || fail "an object asked about by name should say $listed like the listing, and says '$asked'"
echo "ok: and says the same when it is asked about by name"

echo "all good"
