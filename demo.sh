#!/bin/sh
# Open demo.db in the terminal app. A one-argument launcher, so no terminal
# emulator can mis-split the command it is asked to run.
cd "$(dirname "$0")"
exec ./zig-out/bin/krtek "${1:-demo.db}"
