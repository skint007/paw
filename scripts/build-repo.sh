#!/usr/bin/env bash
# Build the paw package repo into ./out/ — INCREMENTALLY.
#
# A package is only (re)built when its source repo's HEAD commit differs from
# what was last built (recorded in out/state.json). Unchanged packages are
# carried forward from the previously published repo, which CI restores into
# ./out/ before this runs. If nothing changed, this is a near-instant no-op.
#
# Detecting changes uses `git ls-remote` (one network call, no clone) — the
# commit SHA is a cheap, exact proxy for "would pkgver() change?": any source
# edit, pkgrel bump, or -bin version bump is a commit, which moves the SHA.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ./paw.conf

OUT="${OUT:-$PWD/out}"
WORK="${WORK:-$PWD/.build}"
mkdir -p "$OUT" "$WORK"

STATE="$OUT/state.json"                 # { "<pkgname>": "<last-built-sha>" }
[[ -f "$STATE" ]] || echo '{}' > "$STATE"

: > "$OUT/.upload"                       # basenames to (re)upload this run
mark_upload() { printf '%s\n' "$1" >> "$OUT/.upload"; }

CHANGED=""                              # set when anything is built or pruned
declare -A KEEP                         # pkgnames that should stay in the repo
FAILED=()                              # pkgnames that failed to build this run
statelines=""                          # name<TAB>sha lines for the new state.json

# pkgname from a pacman filename (pkgver/pkgrel/arch never contain hyphens).
pkgname_of() { basename "$1" | sed -E 's/-[^-]+-[^-]+-[^-]+\.pkg\.tar\.zst$//'; }

remove_pkg_files() {  # $1 = pkgname — drop its package files from OUT
  local want="$1" f
  shopt -s nullglob
  for f in "$OUT"/*.pkg.tar.zst; do
    [[ "$(pkgname_of "$f")" == "$want" ]] && rm -f "$f" "$f.sig"
  done
  shopt -u nullglob
}

have_pkg_files() {  # $1 = pkgname — true if OUT already holds a build of it
  local want="$1" f
  shopt -s nullglob
  for f in "$OUT"/*.pkg.tar.zst; do
    if [[ "$(pkgname_of "$f")" == "$want" ]]; then shopt -u nullglob; return 0; fi
  done
  shopt -u nullglob
  return 1
}

build_into_out() {  # $1 = dir with PKGBUILD ; $2 = pkgname. Returns 1 if the build fails.
  local dir="$1" name="$2"
  # Fast path: makepkg -s resolves deps from the official repos. Only touch OUT on
  # success, so a failed rebuild keeps the old version.
  if ! ( cd "$dir" && makepkg -scf --noconfirm --sign --key "$PAW_GPG_KEYID" ); then
    # It may have failed because a dependency lives in the AUR. If an AUR helper is
    # present (CI installs paru), install the PKGBUILD's deps through it and retry.
    command -v paru >/dev/null 2>&1 || return 1
    echo "  ↻ $name: retrying with AUR deps resolved via paru"
    local deps
    mapfile -t deps < <(
      cd "$dir" && bash -c 'source ./PKGBUILD; printf "%s\n" "${depends[@]}" "${makedepends[@]}" "${checkdepends[@]}"' 2>/dev/null \
        | sed -E 's/[<>=].*//' | grep -v '^[[:space:]]*$' | sort -u
    )
    if ((${#deps[@]})); then
      paru -S --needed --asdeps --noconfirm --skipreview "${deps[@]}" || return 1
    fi
    ( cd "$dir" && makepkg -dcf --noconfirm --sign --key "$PAW_GPG_KEYID" ) || return 1
  fi
  remove_pkg_files "$name"               # replace any older version
  local f
  shopt -s nullglob
  for f in "$dir"/*.pkg.tar.zst; do
    cp "$f" "$f.sig" "$OUT"/
    mark_upload "$(basename "$f")"
    mark_upload "$(basename "$f").sig"
  done
  shopt -u nullglob
  CHANGED=1
}

# --- paw CLI package (tracked by the paw repo's own HEAD) ---
KEEP[paw]=1
paw_ref=$(git rev-parse HEAD 2>/dev/null || echo local)
paw_old=$(jq -r '.["paw"] // ""' "$STATE")
if [[ -n "$paw_ref" && "$paw_ref" == "$paw_old" ]] && have_pkg_files paw; then
  echo "= paw (unchanged) — carried forward"
else
  echo "+ paw (building)"
  cp paw packaging/paw/paw
  cp LICENSE packaging/paw/LICENSE
  build_into_out packaging/paw paw || { echo "✗ paw FAILED to build"; FAILED+=("paw"); }
fi
statelines+="paw	$paw_ref"$'\n'

# --- manifest packages (rebuild only when the source commit changed) ---
echo ":: Checking manifest packages"
while IFS=$'\t' read -r name repo branch subdir; do
  [[ -n "$name" ]] || continue
  KEEP[$name]=1
  ref=$(git ls-remote "$repo" "${branch:-HEAD}" 2>/dev/null | head -n1 | cut -f1 || true)
  old=$(jq -r --arg n "$name" '.[$n] // ""' "$STATE")

  if [[ -n "$ref" && "$ref" == "$old" ]] && have_pkg_files "$name"; then
    echo "= $name (unchanged @ ${ref:0:7}) — carried forward"
    statelines+="$name	$ref"$'\n'
    continue
  fi

  echo "+ $name (building @ ${ref:-unknown})"
  dir="$WORK/$name"
  rm -rf "$dir"
  if git clone --depth 1 ${branch:+--branch "$branch"} "$repo" "$dir" \
     && build_into_out "$dir${subdir:+/$subdir}" "$name"; then
    statelines+="$name	${ref:-$(git -C "$dir" rev-parse HEAD)}"$'\n'
  else
    # Leave it out of state so it's retried next run; KEEP preserves any prior build.
    echo "✗ $name FAILED to build — keeping any previous version, will retry next run"
    FAILED+=("$name")
  fi
done < <(jq -r '.packages[] | [.name, .repo, (.branch // ""), (.subdir // "")] | @tsv' packages.json)

# --- prune packages no longer in the manifest ---
shopt -s nullglob
for f in "$OUT"/*.pkg.tar.zst; do
  n=$(pkgname_of "$f")
  if [[ -z "${KEEP[$n]:-}" ]]; then
    echo "- $n (removed from manifest) — pruning"
    rm -f "$f" "$f.sig"
    CHANGED=1
  fi
done
shopt -u nullglob

# Record build failures so the workflow can flag them AFTER publishing the successes.
if [[ ${#FAILED[@]} -gt 0 ]]; then
  printf '%s\n' "${FAILED[@]}" > "$OUT/.failed"
  echo "⚠ ${#FAILED[@]} package(s) failed to build: ${FAILED[*]}"
else
  rm -f "$OUT/.failed"
fi

if [[ -z "$CHANGED" ]]; then
  echo "✓ Nothing changed — repo already up to date."
  exit 0
fi

# --- rebuild the database from the full current package set ---
echo ":: Building repo database"
(
  cd "$OUT"
  rm -f "${PAW_REPO_NAME}".db* "${PAW_REPO_NAME}".files*
  repo-add --sign --key "$PAW_GPG_KEYID" "${PAW_REPO_NAME}.db.tar.zst" ./*.pkg.tar.zst
  # repo-add leaves .db/.files as symlinks; dereference so plain hosts serve real files.
  for ext in db db.sig files files.sig; do
    link="${PAW_REPO_NAME}.${ext}"
    [[ -L "$link" ]] && cp --remove-destination "$(readlink -f "$link")" "$link"
  done
)
for ext in db db.tar.zst db.sig db.tar.zst.sig files files.tar.zst files.sig files.tar.zst.sig; do
  [[ -e "$OUT/${PAW_REPO_NAME}.${ext}" ]] && mark_upload "${PAW_REPO_NAME}.${ext}"
done

# --- persist state + public key ---
printf '%s' "$statelines" \
  | jq -Rn '[inputs | select(length>0) | split("\t") | {key:.[0], value:.[1]}] | from_entries' \
  > "$STATE"
mark_upload "state.json"
gpg --export --armor "$PAW_GPG_KEYID" > "$OUT/paw.pub"
mark_upload "paw.pub"

# Keep only entries that still exist — a split/debug package may have been built
# and then pruned (e.g. a PKGBUILD missing options=('!debug')). The `if` form keeps
# the loop body's status 0 so a trailing missing entry can't trip `set -e`/pipefail.
sort -u "$OUT/.upload" | while IFS= read -r f; do
  if [[ -n "$f" && -e "$OUT/$f" ]]; then printf '%s\n' "$f"; fi
done > "$OUT/.upload.tmp"
mv "$OUT/.upload.tmp" "$OUT/.upload"
echo "✓ Repo ready in $OUT ($(grep -c . "$OUT/.upload") file(s) to upload)"
