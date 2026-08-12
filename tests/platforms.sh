#!/bin/sh
# Does the code that touches the operating system compile for every platform the
# release builds for?
#
# The full build needs libpq and the rest, which only exist for the machine doing
# the building - that is why CI builds inside Alpine. But the file layer talks to
# libc directly and needs nothing else, and libc is exactly where the platforms
# disagree: this Zig routes Linux to `statx` and leaves `fstatat` undefined
# there, which a machine building only for macOS never finds out.
#
# The compiler is lazy, so a function nobody calls is a function nobody checks -
# hence the list of references below, which is what makes this look at anything
# at all.
set -e
cd "$(dirname "$0")/.."

FORCE=$(mktemp /tmp/krtek-platforms-XXXXXX.zig)
trap 'rm -f "$FORCE"' EXIT
cat > "$FORCE" <<'EOF'
const store = @import("store");
comptime {
    _ = &store.Local.list;
    _ = &store.Local.stat;
    _ = &store.Local.openRead;
    _ = &store.Local.openWrite;
    _ = &store.Local.makeDir;
    _ = &store.Local.remove;
    _ = &store.Local.rename;
    _ = &store.copy;
    _ = &store.removeAll;
}
EOF

failed=0
for target in x86_64-linux-musl aarch64-linux-musl x86_64-macos aarch64-macos; do
	printf '%-22s ' "$target"
	# To a real file rather than /dev/null, which the compiler cannot write an
	# object to and dies trying.
	if zig build-obj -target "$target" -lc -femit-bin="/tmp/krtek-platforms-$target.o" \
		--dep store -Mroot="$FORCE" \
		--dep db -Mstore=src/db/store.zig \
		-Mdb=src/db/db.zig 2>/tmp/krtek-platforms.err
	then
		echo ok
	else
		echo FAIL
		sed -n '1,20p' /tmp/krtek-platforms.err >&2
		failed=1
	fi
	rm -f "/tmp/krtek-platforms-$target.o"
done

test "$failed" -eq 0 || exit 1
echo "all good"
