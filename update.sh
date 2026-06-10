#!/bin/bash
# update.sh — Pull latest configs repo, copy scripts, and optionally run deploy commands.
# Reads manifest.json for source→destination mapping and runcmd definitions.
# Usage: update.sh [--pull] [--run]
#   --pull  Run git pull before copying (default: just copy)
#   --run   Execute the runcmd section from manifest after copying

set -e

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]:-$0}")"
REPO_DIR="$(dirname "$SCRIPT_PATH")"
MANIFEST="$REPO_DIR/manifest.json"
DO_PULL=false
DO_RUN=false

for arg in "$@"; do
  case "$arg" in
    --pull) DO_PULL=true ;;
    --run)  DO_RUN=true ;;
  esac
done

if [ "$DO_PULL" = true ]; then
  echo "Pulling latest from repo..."
  git -C "$REPO_DIR" pull --ff-only -q || echo "  WARNING: git pull failed"
fi

if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: $MANIFEST not found"
  exit 1
fi

echo "Copying scripts to deployed locations..."

# Ensure target directories exist (derive from manifest destinations)
jq -r '.scripts[].dst' "$MANIFEST" | xargs -n1 dirname | sort -u | while read -r dir; do
  sudo mkdir -p "$dir"
done

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

echo "Scripts updated."

# Execute runcmd section if --run is passed
if [ "$DO_RUN" = true ]; then
  if ! jq -e '.runcmd' "$MANIFEST" > /dev/null 2>&1; then
    echo "No runcmd section in manifest. Skipping."
    exit 0
  fi

  echo ""
  echo "Executing runcmd from manifest..."
  jq -c '.runcmd[]' "$MANIFEST" | while read -r cmd; do
    script_name=$(echo "$cmd" | jq -r '.run')
    use_sudo=$(echo "$cmd" | jq -r '.sudo')
    args=$(echo "$cmd" | jq -r '.args')
    background=$(echo "$cmd" | jq -r '.background // false')

    # Resolve script path from the scripts section by matching the filename
    script_path=$(jq -r --arg name "$script_name" '.scripts[] | select(.src | endswith($name)) | .dst' "$MANIFEST" | head -1)

    if [ -z "$script_path" ] || [ ! -f "$script_path" ]; then
      echo "  ERROR: Cannot resolve script '$script_name' from manifest"
      continue
    fi

    # Build the command
    run_cmd="$script_path $args"
    if [ "$use_sudo" = "true" ]; then
      run_cmd="sudo $run_cmd"
    fi

    echo "  -> $run_cmd"
    if [ "$background" = "true" ]; then
      nohup bash -c "$run_cmd" > /var/log/${script_name%.sh}.log 2>&1 &
    else
      eval "$run_cmd"
    fi
  done

  echo "All runcmd steps complete."
fi
