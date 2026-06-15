#!/usr/bin/env bash
# Maintainer helper: interactively append a package to packages.json.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v gum >/dev/null || { echo "needs gum"; exit 1; }
command -v jq  >/dev/null || { echo "needs jq";  exit 1; }

name=$(gum input   --placeholder "package name (pkgname)")
repo=$(gum input   --placeholder "git URL of the package repo")
desc=$(gum input   --placeholder "short description")
branch=$(gum input --placeholder "branch (optional, blank = default)")
subdir=$(gum input --placeholder "PKGBUILD subdir (optional, e.g. aur)")

[[ -n "$name" && -n "$repo" ]] || { echo "name and repo are required."; exit 1; }

tmp=$(mktemp)
jq --arg n "$name" --arg r "$repo" --arg d "$desc" --arg b "$branch" --arg s "$subdir" \
  '.packages += [ ({name:$n, repo:$r, desc:$d}
                   + (if $b == "" then {} else {branch:$b} end)
                   + (if $s == "" then {} else {subdir:$s} end)) ]' \
  packages.json > "$tmp" && mv "$tmp" packages.json

echo "✓ Added '$name'. Commit & push to trigger a rebuild."
