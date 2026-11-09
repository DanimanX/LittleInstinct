#!/bin/sh
# Fetch the reference Pocket core this port reuses its APF scaffolding from.
#
# references/ is not vendored (it is a git clone, and .gitignore excludes it).
# The APF framework files in src/fpga/apf/ and src/fpga/core/ were copied from
# it once and are now part of this tree; this script is only needed to read the
# reference again or to refresh those copies deliberately.
#
# Pinned to the commit the copies came from.
set -eu
REF_REPO=https://github.com/akoaysigod/pocket_saturn_core.git
REF_COMMIT=$(cat "$(dirname "$0")/../references.lock" 2>/dev/null || echo main)

mkdir -p "$(dirname "$0")/../references"
cd "$(dirname "$0")/../references"
if [ ! -d pocket_saturn_core ]; then
    git clone "$REF_REPO" pocket_saturn_core
fi
cd pocket_saturn_core
git fetch --all --quiet
git checkout --quiet "$REF_COMMIT"
git log -1 --format='%H %ad %s' --date=short
