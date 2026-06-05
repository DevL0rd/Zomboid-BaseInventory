#!/usr/bin/env bash
# Deploy the BaseInventory mod from this repo into the Project Zomboid (Proton) mods folder.
# Run after making changes:  ./deploy.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.local/share/Steam/steamapps/compatdata/108600/pfx/drive_c/users/steamuser/Zomboid/mods/BaseInventory"

mkdir -p "$DEST"
rsync -a --delete \
  --exclude='.git/' \
  --exclude='deploy.sh' \
  --exclude='README.md' \
  --exclude='.gitignore' \
  "$REPO_DIR/" "$DEST/"

echo "Deployed BaseInventory -> $DEST"
echo "Restart Project Zomboid (mods are scanned at launch) and ensure 'Base Inventory' is enabled."
