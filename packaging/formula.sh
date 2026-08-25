#!/bin/sh
# Write the Homebrew formula for a release:
#
#     packaging/formula.sh <version> <directory of the release archives>
#
# It reads the .sha256 files that tests/package.sh wrote, so the formula can only
# ever name a checksum that a real archive has. Prints the formula on stdout.
#
# Where the directory also holds the JSON that `brew bottle` writes, a bottle
# block is added from it - same rule, the checksums come from files that exist.
# Bottles matter here for a reason that is not speed: Homebrew runs its
# build-from-source checks on any formula it cannot pour, and one of those refuses
# to install anything at all when the machine's Xcode is older than its macOS.
# Nothing is compiled by this formula, so that check is answering a question
# nobody asked - and a bottle is the only way to say so.
#
# The archives hold one static binary each, so the formula installs rather than
# builds: that is what a tap is for. homebrew-core would want to compile from
# source instead.
#
# The release attaches what this prints as krtek.rb, and the tap - zales/krtek,
# the repository homebrew-krtek - fetches it from there hourly with a workflow of
# its own. That way round on purpose: pushing into the tap from here would need a
# personal access token kept as a secret, and the tap can already write to itself.
set -e
cd "$(dirname "$0")/.."

version=${1#v}
dir=${2:-.}
: "${version:?usage: packaging/formula.sh <version> <directory>}"

sha() {
	file=$(ls "$dir"/krtek-v"$version"-"$1".tar.gz.sha256 2>/dev/null | head -1)
	test -n "$file" || { echo "no checksum for $1 in $dir" >&2; exit 1; }
	# shasum writes "<hash>  <name>"; take the hash.
	awk '{print $1; exit}' "$file"
}

url() {
	echo "https://github.com/zales/krtek/releases/download/v$version/krtek-v$version-$1.tar.gz"
}

# The bottle block, from whatever `brew bottle --json` files are in the directory.
# Nothing at all where there are none, so a release without bottles still writes a
# formula that works.
bottles() {
	files=$(ls "$dir"/*.bottle.json 2>/dev/null) || return 0
	test -n "$files" || return 0
	printf '\n  # Poured rather than "built", which is what stops Homebrew asking a\n'
	printf '  # machine that compiles nothing whether its Xcode is new enough.\n'
	printf '  bottle do\n'
	printf '    root_url "https://github.com/zales/krtek/releases/download/v%s"\n' "$version"
	# One line per tag: {"krtek":{"bottle":{"tags":{"<tag>":{"sha256":"..."}}}}}
	for file in $files; do
		python3 - "$file" <<-'PY'
			import json, sys
			with open(sys.argv[1]) as f:
			    root = json.load(f)
			for formula in root.values():
			    bottle = formula.get("bottle", {})
			    for tag, said in sorted(bottle.get("tags", {}).items()):
			        # Whether the bottle can be poured anywhere is `brew bottle`'s
			        # to decide, not this script's to assume: it looks inside for
			        # the prefix it was built under.
			        cellar = said.get("cellar", bottle.get("cellar", "any_skip_relocation"))
			        # `any` and `any_skip_relocation` are symbols; a cellar that is a
			        # path is a string, and writing one as the other is a formula
			        # Homebrew will not read.
			        where = '"%s"' % cellar if cellar.startswith("/") else ":" + cellar
			        print('    sha256 cellar: %s, %s: "%s"' % (where, tag, said["sha256"]))
		PY
	done
	printf '  end\n'
}


cat <<EOF
# krtek $version. Written by packaging/formula.sh - do not edit by hand.
class Krtek < Formula
  desc "Terminal database manager for SQLite, PostgreSQL, MySQL, Redis, Kafka, S3, Azure Blob, RabbitMQ, SFTP and Kubernetes"
  homepage "https://github.com/zales/krtek"
  version "$version"
  license "MIT"
$(bottles)
  # One static binary per platform: nothing is compiled and nothing is depended
  # on, because the client libraries are already inside it.
  on_macos do
    on_arm do
      url "$(url macos-arm64)"
      sha256 "$(sha macos-arm64)"
    end
    on_intel do
      url "$(url macos-x86_64)"
      sha256 "$(sha macos-x86_64)"
    end
  end

  on_linux do
    on_arm do
      url "$(url linux-arm64)"
      sha256 "$(sha linux-arm64)"
    end
    on_intel do
      url "$(url linux-x86_64)"
      sha256 "$(sha linux-x86_64)"
    end
  end

  def install
    bin.install "krtek"
    man1.install "krtek.1"
    doc.install "README.md", "LICENSE"
  end

  test do
    # Not much can be tested without a terminal, but this proves the binary runs
    # on this machine, which is the thing a downloaded binary has to prove.
    assert_match "database manager for the terminal", shell_output("#{bin}/krtek --help")
  end
end
EOF
