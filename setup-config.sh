#!/bin/bash
# setup-config.sh <system> <profile> [num-nodes]
# Resolves $eth1 and $port placeholders from templates into per-port folders.
#
# Examples:
#   setup-config.sh valkey cache 16    → creates ~/valkey-cluster/7000..7015/
#   setup-config.sh garnet cache       → creates ~/garnet-cluster/ with resolved conf

set -e

SYSTEM="${1:?Usage: setup-config.sh <system> <profile> [num-nodes]}"
PROFILE="${2:?Usage: setup-config.sh <system> <profile> [num-nodes]}"
NUM_NODES="${3:-1}"
BASE_PORT=7000
CONF_DIR="$HOME/node-conf"
TEMPLATE="$CONF_DIR/${SYSTEM}-${PROFILE}.conf"

if [ ! -f "$TEMPLATE" ]; then
    echo "ERROR: Template not found: $TEMPLATE"
    echo "Available templates:"
    ls "$CONF_DIR"/*.conf 2>/dev/null || echo "  (none)"
    exit 1
fi

# Resolve eth1 IP
ETH1_IP=$(ip -4 addr show eth1 | grep -oP 'inet \K[\d.]+')
if [ -z "$ETH1_IP" ]; then
    echo "ERROR: Could not determine eth1 IP"
    exit 1
fi

echo "=== setup-config: system=$SYSTEM profile=$PROFILE nodes=$NUM_NODES eth1=$ETH1_IP ==="

if [ "$SYSTEM" = "garnet" ]; then
    # Garnet: single cluster directory
    CLUSTER_DIR="$HOME/garnet-cluster"
    mkdir -p "$CLUSTER_DIR"

    for ((i = 0; i < NUM_NODES; i++)); do
        PORT=$((BASE_PORT + i))
        PORT_DIR="$CLUSTER_DIR/$PORT"
        mkdir -p "$PORT_DIR"
        sed -e "s/\$eth1/$ETH1_IP/g" -e "s/\$port/$PORT/g" "$TEMPLATE" > "$PORT_DIR/garnet.conf"
    done
    echo "Created $NUM_NODES garnet config(s) in $CLUSTER_DIR/"

else
    # Valkey/Redis: one folder per port
    CLUSTER_DIR="$HOME/valkey-cluster"
    mkdir -p "$CLUSTER_DIR"

    for ((i = 0; i < NUM_NODES; i++)); do
        PORT=$((BASE_PORT + i))
        PORT_DIR="$CLUSTER_DIR/$PORT"
        mkdir -p "$PORT_DIR"
        sed -e "s/\$eth1/$ETH1_IP/g" -e "s/\$port/$PORT/g" "$TEMPLATE" > "$PORT_DIR/valkey.conf"
    done
    echo "Created $NUM_NODES valkey config(s) in $CLUSTER_DIR/"
fi
