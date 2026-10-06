#!/usr/bin/env bash
# Builds the course website into _book/.
#
# mdBook copies every non-Markdown file from its source folder into the site, so building
# straight from the repo root would publish .git/ and other dotfiles. Instead, stage only
# the course content in a temporary folder and build from there.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

rsync -a \
  --exclude '.*' \
  --exclude '_book' \
  --exclude 'scripts' \
  "$root"/ "$stage"/

rm -rf "$root/_book"
"${MDBOOK:-mdbook}" build "$stage" --dest-dir "$root/_book"
rm -f "$root/_book/book.toml"
