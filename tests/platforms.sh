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
// One module, because `db` already exports the file layer and naming it twice
// makes two modules out of one file, which the compiler will not have.
const db = @import("db");
const store = db.store;
comptime {
    // The Kubernetes driver reaches for libc as directly as the file layer does -
    // fork, execve, pipe, poll and waitpid to run a credential plugin, and a
    // socket read that must not wait, for a shell - and musl and Darwin do not
    // agree about all of it.
    _ = &db.k8s_exec.run;
    _ = &db.k8s_exec.which;
    _ = &db.ws.connect;
    _ = &db.net.startTls;
    _ = &db.net.Stream.readNow;
    _ = &db.k8s_config.find;
    // Reading a small file the target or the environment named, which every
    // driver that has one of those does through libc.
    _ = &db.targets.readFile;
    _ = &db.targets.getenv;
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
		--dep db -Mroot="$FORCE" \
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
