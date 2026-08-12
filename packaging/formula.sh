#!/bin/sh
# Write the Homebrew formula for a release:
#
#     packaging/formula.sh <version> <directory of the release archives>
#
# It reads the .sha256 files that tests/package.sh wrote, so the formula can only
# ever name a checksum that a real archive has. Prints the formula on stdout.
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

cat <<EOF
# krtek $version. Written by packaging/formula.sh - do not edit by hand.
class Krtek < Formula
  desc "Terminal database manager for SQLite, PostgreSQL, MySQL, Redis, Kafka, S3, Azure Blob and RabbitMQ"
  homepage "https://github.com/zales/krtek"
  version "$version"
  license "MIT"

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
