#!/bin/sh
# Bring up Azurite - Microsoft's own emulator - and check the driver against it:
#
#     zig build && ./tests/azure.sh
#
# The emulator rather than a real account for the obvious reason, but also for a
# better one: it puts the account in the *path*, which is the thing a driver
# written only against Azure gets wrong. The signature is the same either way,
# and the unit tests check that against signatures computed elsewhere.
#
# The account and key below are not secrets. They are the same on every machine
# that has ever run the emulator, which is what makes this test reproducible.
set -e
cd "$(dirname "$0")/.."

NAME=${NAME:-krtek-azure-test}
IMAGE=${IMAGE:-mcr.microsoft.com/azure-storage/azurite:latest}
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

ACCOUNT=devstoreaccount1
KEY='Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=='

BIN=zig-out/bin/krtek
test -x "$BIN" || { echo "$BIN is not there - zig build first" >&2; exit 1; }

echo "starting $IMAGE"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p 10000:10000 "$IMAGE" \
	azurite-blob --blobHost 0.0.0.0 --skipApiVersionCheck >/dev/null

printf 'waiting for the emulator'
until curl -s -o /dev/null "http://127.0.0.1:10000/$ACCOUNT?comp=list"; do
	printf .
	sleep 1
done
echo " up"

# Seeded with a signature of its own making, so the seeding does not depend on
# the thing being tested.
python3 - "$ACCOUNT" "$KEY" <<'PY'
import base64, hmac, hashlib, datetime, subprocess, sys
ACC, KEY = sys.argv[1], sys.argv[2]
VER = "2021-08-06"

def call(verb, path, params=None, body=None, extra=None):
	params, extra = params or {}, extra or {}
	when = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")
	ms = {"x-ms-date": when, "x-ms-version": VER}
	ms.update({k.lower(): v for k, v in extra.items() if k.lower().startswith("x-ms-")})
	canon = "".join(f"{k}:{ms[k]}\n" for k in sorted(ms))
	resource = f"/{ACC}{path}" + "".join(f"\n{k}:{params[k]}" for k in sorted(params))
	length = str(len(body)) if body else ""
	sts = "\n".join([verb, "", "", length, "", extra.get("Content-Type", ""), "", "", "", "", "", ""]) + "\n" + canon + resource
	mac = hmac.new(base64.b64decode(KEY), sts.encode(), hashlib.sha256).digest()
	args = ["curl", "-s", "-o", "/dev/null", "-X", verb,
		"-H", f"x-ms-date: {when}", "-H", f"x-ms-version: {VER}",
		"-H", f"Authorization: SharedKey {ACC}:{base64.b64encode(mac).decode()}"]
	for k, v in extra.items():
		args += ["-H", f"{k}: {v}"]
	if body is not None:
		args += ["--data-binary", body]
	else:
		args += ["-H", "Content-Length: 0"]
	url = f"http://127.0.0.1:10000{path}" + ("?" + "&".join(f"{k}={v}" for k, v in params.items()) if params else "")
	subprocess.run(args + [url], check=True)

call("PUT", f"/{ACC}/photos", {"restype": "container"})
call("PUT", f"/{ACC}/druhy", {"restype": "container"})
for i in range(1, 13):
	call("PUT", f"/{ACC}/photos/2015%2Fsoubor-{i:02d}.txt", body=f"zaznam {i}\n",
		extra={"x-ms-blob-type": "BlockBlob", "Content-Type": "text/plain"})
# A name with a space in it, which is where an unescaped path shows up. Named so
# that it sorts first, because a listing is what the check reads.
call("PUT", f"/{ACC}/photos/2015%20august%20trip.txt", body="ahoj\n",
	extra={"x-ms-blob-type": "BlockBlob", "Content-Type": "text/plain"})
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

ROOT="azure+http://$ACCOUNT:$KEY@127.0.0.1:10000/$ACCOUNT"
STRING="DefaultEndpointsProtocol=http;AccountName=$ACCOUNT;AccountKey=$KEY;BlobEndpoint=http://127.0.0.1:10000/$ACCOUNT"

check "a container named in the target" "$ROOT/photos" "connected: devstoreaccount1/photos"
check "the emulator says who it is" "$ROOT/photos" "Azurite"
# The key is base64 and has slashes in it: the credentials end at the last @, not
# at the first slash, and getting that wrong loses the account entirely.
check "a key with slashes in it survives the target" "$ROOT/photos" "account = devstoreaccount1"
check "the account is in the path here" "$ROOT/photos" "addressing = account in the path"
check "the connection string from the portal is a target too" "$STRING;Container=photos" "connected: devstoreaccount1/photos"
check "every container, when none is named" "$STRING" "table .druhy"
check "a blob is addressed by its name" "$ROOT/photos" "row key: name (usable=true)"
check "a name with a space in it comes back whole" "$ROOT/photos" "2015 august trip.txt" photos

# Thirteen blobs over four-blob pages: every name exactly once, which is the
# marker doing its job.
check "pages neither overlap nor skip" "$ROOT/photos" "paged: 13 records, 13 distinct" photos
check "and the count is exact" "$ROOT/photos" "exact=13" photos

check "a wrong key says so" \
	"azure+http://$ACCOUNT:RUJ5OHZkTTAyeE5PY3FGbHFVd0pQTGxtRXRsQ0RYSjE=@127.0.0.1:10000/$ACCOUNT/photos" \
	"AuthorizationFailure"
check "a container that is not there says so" "$ROOT/neexistuje" "ContainerNotFound"
check "a key that is not base64 is refused before it is used" \
	"azure+http://$ACCOUNT:not-base64@127.0.0.1:10000/$ACCOUNT/photos" "could not be signed"

# --- and the file manager, which is the only way the copying is reachable ---
#
# None of the above goes near it: the table listing and the file listing are two
# different calls, and only the second asks for a delimiter. Which is how a
# folded listing came to be signed wrong without a single check noticing.
LOCAL=/tmp/krtek-azure-test-local
rm -rf "$LOCAL"
mkdir -p "$LOCAL"
echo "ahoj z krtka" > "$LOCAL/jedna.txt"

# The panes start local on the left and the account on the right, so one tab and
# a step down and an enter is inside `photos`.
#
# Asked for as what should be there rather than as what should not: a listing
# that failed says so in a sentence the screen is too narrow to hold, and a check
# reading the visible half of an error message passes whatever happens.
out=$(tests/screen.py "$ROOT" "{sleep}f{sleep}{tab}{sleep}{down}{enter}{sleep}{keep}" 2>&1 || true)
printf '%s' "$out" | grep -q "2015 august trip.txt" || {
	printf '%s\n' "$out" >&2
	fail "a container should list in the file manager"
}
# And the delimiter is what turns names sharing a prefix into one directory.
printf '%s' "$out" | grep -q "2015 *<dir>" || {
	printf '%s\n' "$out" >&2
	fail "blobs sharing a prefix should fold into a directory"
}
echo "ok: a container lists, and names sharing a prefix fold into a directory"

# Up: a file from this machine into a container.
tests/screen.py "$ROOT" "{sleep}f{sleep}/$LOCAL{enter}{sleep}{tab}{enter}{sleep}{tab}{down}c{sleep}{keep}" >/dev/null 2>&1 || true
check "a file copied up arrives" "$ROOT/druhy" "jedna.txt" druhy
echo "ok: a file goes up into a container"

# And the same copy where a blob cannot go - the account itself, which has no
# container to put one in. What matters is that it says so rather than falling
# over: finishing an upload releases what it held, and abandoning it afterwards
# released the same bytes twice.
out=$(tests/screen.py "$ROOT" "{sleep}f{sleep}/$LOCAL{enter}{sleep}{down}c{sleep}{keep}" 2>&1 || true)
printf '%s' "$out" | grep -q "jedna.txt:" || {
	printf '%s\n' "$out" >&2
	fail "a copy with nowhere to go should say so"
}
printf '%s' "$out" | grep -qi "panic\|abort\|segmentation" && fail "and should not take the program with it"
echo "ok: a copy with nowhere to go says so and survives"
rm -rf "$LOCAL"

echo "all good"
