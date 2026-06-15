#!/usr/bin/env bash
# Bootstrap a machine to use the paw repo.
# Friends run:  curl -fsSL https://raw.githubusercontent.com/youruser/yourrepo/main/install.sh | bash
set -euo pipefail

# ---- keep these in sync with paw.conf, then commit ----
PAW_GH_REPO="skint007/paw"
PAW_RELEASE_TAG="repo"
PAW_REPO_NAME="paw"
PAW_GPG_KEYID="BAA249F70CDB0F045B83F6CF640578DB1360A8A5"
# -------------------------------------------------------

SERVER="https://github.com/${PAW_GH_REPO}/releases/download/${PAW_RELEASE_TAG}"
KEY_URL="${SERVER}/paw.pub"

command -v pacman >/dev/null || { echo "This installer is for Arch-based systems (pacman not found)."; exit 1; }

echo ":: Installing prerequisites (gum, expac)…"
sudo pacman -S --needed --noconfirm gum expac

echo ":: Importing signing key…"
tmp=$(mktemp)
curl -fsSL "$KEY_URL" -o "$tmp"
sudo pacman-key --add "$tmp"
sudo pacman-key --lsign-key "$PAW_GPG_KEYID"
rm -f "$tmp"

if ! grep -q "^\[${PAW_REPO_NAME}\]" /etc/pacman.conf; then
  echo ":: Adding [${PAW_REPO_NAME}] repo to /etc/pacman.conf…"
  sudo tee -a /etc/pacman.conf >/dev/null <<EOF

[${PAW_REPO_NAME}]
SigLevel = Required
Server = ${SERVER}
EOF
else
  echo ":: [${PAW_REPO_NAME}] already present in pacman.conf, skipping."
fi

echo ":: Syncing and installing paw…"
sudo pacman -Sy
sudo pacman -S --needed --noconfirm paw

echo "✓ Done. Run 'paw' to browse packages."
