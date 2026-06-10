#!/bin/bash
# update.sh — Pull latest configs repo and copy scripts to their deployed locations.
# Reads manifest.json for source→destination mapping.
# Usage: update.sh [--pull]
#   --pull  Run git pull before copying (default: just copy)

set -e

REPO_DIR="$HOME/configs"
MANIFEST="$REPO_DIR/manifest.json"

if [ "${1:-}" = "--pull" ]; then
  echo "Pulling latest from repo..."
  git -C "$REPO_DIR" pull --ff-only -q || echo "  WARNING: git pull failed"
fi

if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: $MANIFEST not found"
  exit 1
fi

echo "Copying scripts to deployed locations..."

# Ensure target directories exist
sudo mkdir -p /tmp/deploy-actions

# Read manifest and copy each entry
jq -c '.scripts[]' "$MANIFEST" | while read -r entry; do
  src="$REPO_DIR/$(echo "$entry" | jq -r '.src')"
  dst=$(echo "$entry" | jq -r '.dst')
  mode=$(echo "$entry" | jq -r '.mode')

  if [ -f "$src" ]; then
    sudo cp "$src" "$dst"
    sudo chmod "$mode" "$dst"
    echo "  $dst"
  else
    echo "  SKIP: $src (not found)"
  fi
done

echo "Done. All scripts updated."
