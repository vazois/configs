#!/bin/bash
# Usage: setup-cluster-dir.sh <system> [nodes]
# Examples:
#   setup-cluster-dir.sh valkey       - create ~/valkey-cluster/ with one folder per CPU core
#   setup-cluster-dir.sh valkey 16    - create ~/valkey-cluster/ with 16 port folders
#   setup-cluster-dir.sh garnet       - create ~/garnet-cluster/ (single folder)
set -e
source /tmp/deploy-actions/config.env

SYSTEM="${1:?Usage: setup-cluster-dir.sh <system> [nodes]}"
NUM_NODES="${2:-$(nproc)}"

case "$SYSTEM" in
  redis|valkey)
    DIR="$HOME/valkey-cluster"
    mkdir -p "$DIR"
    for (( i=0; i<NUM_NODES; i++ )); do
      mkdir -p "$DIR/$(( BASE_PORT + i ))"
    done
    chown -R $DEPLOY_USER:$DEPLOY_USER "$DIR"
    echo "Created $DIR with $NUM_NODES port folders (${BASE_PORT}-$(( BASE_PORT + NUM_NODES - 1 )))"
    ;;
  garnet)
    DIR="$HOME/garnet-cluster"
    mkdir -p "$DIR"
    chown -R $DEPLOY_USER:$DEPLOY_USER "$DIR"
    echo "Created $DIR (single instance, multi-threaded)"
    ;;
  *)
    echo "Unknown system: $SYSTEM (use redis, valkey, or garnet)"
    exit 1
    ;;
esac
