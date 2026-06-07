#!/usr/bin/env bash
# Stage the SafehouseInventory mod into the Project Zomboid (Proton) Workshop folder, ready to
# upload with the in-game Workshop tool (Main Menu -> Workshop). Run after making changes: ./deploy.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZOMBOID="$HOME/.local/share/Steam/steamapps/compatdata/108600/pfx/drive_c/users/steamuser/Zomboid"

NAME="SafehouseInventory"
TITLE="Safehouse Inventory"
WS="$ZOMBOID/Workshop/$NAME"           # workshop project root (the in-game tool reads this)
DEST="$WS/Contents/mods/$NAME"         # the actual mod folder

mkdir -p "$DEST"
rsync -a --delete \
  --exclude='.git/' \
  --exclude='.github/' \
  --exclude='deploy.sh' \
  --exclude='README.md' \
  --exclude='.gitignore' \
  --exclude='workshop.txt' \
  "$REPO_DIR/" "$DEST/"

# Steam preview image (shown on the Workshop page / in the uploader).
cp -f "$REPO_DIR/42/poster.png" "$WS/preview.png"

# workshop.txt (title, tags, visibility, published id, description) is the canonical metadata kept
# in the repo, with a human-readable multi-line description. Project Zomboid's parser, however,
# requires EVERY description line to be prefixed with "description=" (single "description=" + raw
# lines makes it drop the description and treat the item as new). Convert on the way out.
awk '/^description=/&&!s{s=1;sub(/^description=/,"")} s{print "description=" $0; next} {print}' \
  "$REPO_DIR/workshop.txt" > "$WS/workshop.txt"

# Moved to Workshop staging: remove any old plain mods/ copy so the game doesn't load a duplicate.
OLD="$ZOMBOID/mods/$NAME"
if [ -d "$OLD" ]; then rm -rf "$OLD"; echo "Removed old $OLD"; fi

echo "Deployed $TITLE -> $DEST"
echo "Upload it from the game: Main Menu -> Workshop -> (select '$NAME')."
