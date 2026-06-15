#!/usr/bin/env bash
# Build every package in packages.json (plus the paw CLI), sign them, and
# assemble a pacman repo database in ./out/. Run locally on Arch or in CI.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ./paw.conf

OUT="${OUT:-$PWD/out}"
WORK="${WORK:-$PWD/.build}"
rm -rf "$OUT"; mkdir -p "$OUT" "$WORK"

build_dir() {  # $1 = directory containing a PKGBUILD
  ( cd "$1" && makepkg -cf -s --noconfirm --sign --key "$PAW_GPG_KEYID" )
  cp "$1"/*.pkg.tar.zst     "$OUT"/
  cp "$1"/*.pkg.tar.zst.sig "$OUT"/
}

echo ":: Building paw CLI package"
cp paw packaging/paw/paw
cp LICENSE packaging/paw/LICENSE
build_dir packaging/paw

echo ":: Building manifest packages"
jq -r '.packages[] | [.name, .repo, (.branch // "")] | @tsv' packages.json |
while IFS=$'\t' read -r name repo branch; do
  echo "   - $name"
  dir="$WORK/$name"
  if [[ -d "$dir/.git" ]]; then
    git -C "$dir" fetch --all -p
    git -C "$dir" reset --hard '@{u}'
  else
    git clone --depth 1 ${branch:+--branch "$branch"} "$repo" "$dir"
  fi
  build_dir "$dir"
done

echo ":: Building repo database"
(
  cd "$OUT"
  repo-add --sign --key "$PAW_GPG_KEYID" "${PAW_REPO_NAME}.db.tar.zst" ./*.pkg.tar.zst
  # repo-add leaves .db/.files as symlinks; dereference them so plain file
  # hosts (e.g. GitHub Releases) serve real files that pacman can fetch.
  for ext in db db.sig files files.sig; do
    link="${PAW_REPO_NAME}.${ext}"
    [[ -L "$link" ]] && cp --remove-destination "$(readlink -f "$link")" "$link"
  done
)

echo ":: Exporting public key"
gpg --export --armor "$PAW_GPG_KEYID" > "$OUT/paw.pub"

echo "✓ Repo ready in $OUT"
