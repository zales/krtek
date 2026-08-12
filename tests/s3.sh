#!/bin/sh
# Bring up a MinIO and check the S3 driver against it:
#
#     zig build && ./tests/s3.sh
#
# MinIO rather than Amazon on purpose: it wants path-style addressing and a
# region it was never told about, which is where a driver written only against
# AWS falls over. The signature is the same either way - if MinIO accepts it,
# Amazon does, and the unit tests already check it against Amazon's own worked
# examples.
#
# Thirteen objects in one bucket, because a page is four in the check below: the
# pages have to cover everything exactly once, which is what a continuation token
# is for and what an offset would get wrong.
set -e
cd "$(dirname "$0")/.."

NAME=${NAME:-krtek-s3-test}
IMAGE=${IMAGE:-quay.io/minio/minio:latest}
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

BIN=zig-out/bin/krtek
test -x "$BIN" || { echo "$BIN is not there - zig build first" >&2; exit 1; }

echo "starting $IMAGE"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p 9000:9000 \
	-e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
	"$IMAGE" server /data >/dev/null

printf 'waiting for the server'
until curl -sf -o /dev/null http://127.0.0.1:9000/minio/health/live; do
	printf .
	sleep 1
done
echo " up"

docker exec "$NAME" sh -c '
	mc alias set local http://127.0.0.1:9000 minioadmin minioadmin >/dev/null
	mc mb -p local/photos local/druhy >/dev/null
	for i in $(seq -w 1 12); do
		echo "zaznam $i" | mc pipe local/photos/2015/soubor-$i.txt >/dev/null
	done
	# A key with a space in it: it travels percent-encoded and has to come back
	# as it was, which is what encoding-type=url is asked for.
	echo ahoj | mc pipe "local/photos/august trip.txt" >/dev/null' >/dev/null

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

ROOT="s3+http://minioadmin:minioadmin@127.0.0.1:9000"

check "a bucket named in the target" "$ROOT/photos" "connected: 127.0.0.1/photos"
check "the server says who it is" "$ROOT/photos" "MinIO"
check "every bucket, when none is named" "$ROOT" "table .druhy"
check "a key is a row key" "$ROOT/photos" "row key: key (usable=true)"

# Thirteen objects over four-object pages: every key exactly once, which is the
# continuation token doing its job. An offset would have skipped or repeated.
check "pages neither overlap nor skip" "$ROOT/photos" "paged: 13 records, 13 distinct" photos

check "the addressing MinIO wants" "$ROOT/photos" "addressing = path"
check "where the key came from" "$ROOT/photos" "credentials = the target"

# The failures, which matter more than the successes: each one has to say what
# is wrong rather than a number.
check "a wrong secret says so" \
	"s3+http://minioadmin:wrong@127.0.0.1:9000/photos" "SignatureDoesNotMatch"
check "a bucket that is not there says so" \
	"$ROOT/neexistuje" "NoSuchBucket"
check "no credentials says where to put them" \
	"s3+http://127.0.0.1:9000/photos" "no credentials were found"
# A key with no secret is the case that has to reach the password prompt, which
# the interface offers on the words "secret key" and on nothing else.
check "a key with no secret asks for one" \
	"s3+http://minioadmin@127.0.0.1:9000/photos" "the secret key for minioadmin is missing"
# And the retry the prompt makes: the secret arrives as ?password=, the same way
# it does for every other engine, so it can live in the keychain.
check "the secret may arrive as a password" \
	"s3+http://minioadmin@127.0.0.1:9000/photos?password=minioadmin" "connected: 127.0.0.1/photos"

echo "all good"
