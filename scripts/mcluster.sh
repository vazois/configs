#!/bin/bash
# Usage:
#   mcluster start <system> <template> <nodes> [--cluster|--no-cluster]
#   mcluster stop [system] [nodes]
#
# Examples:
#   mcluster start valkey cache 16              - start 16 valkey instances (cluster enabled)
#   mcluster start valkey cache 16 --no-cluster - start 16 valkey instances (standalone)
#   mcluster start garnet cache 1               - start 1 GarnetServer (cluster enabled)
#   mcluster start garnet cache 1 --no-cluster  - start 1 GarnetServer (cluster disabled)
#   mcluster stop valkey 16                     - stop 16 valkey instances by port
#   mcluster stop garnet                        - stop all GarnetServer instances
#   mcluster stop                               - stop all (valkey + garnet)

source /tmp/deploy-actions/config.env
ACTION="${1:?Usage: mcluster [start|stop] <system> <template> <nodes> [--cluster|--no-cluster]}"
CONF_DIR="$HOME/configs"
CLUSTER_MODE="true"

pull_configs() {
  if [ -d "$CONF_DIR/.git" ]; then
    echo "Pulling latest configs..."
    git -C "$CONF_DIR" pull --ff-only -q 2>/dev/null || echo "  WARNING: git pull failed, using cached configs"
  fi
}

resolve_template() {
  local system="$1" template="$2" nodes="$3"
  local tmpl_file="$CONF_DIR/${system}-${template}.conf"

  if [ ! -f "$tmpl_file" ]; then
    echo "ERROR: Template not found: $tmpl_file"
    echo "Available: $(ls "$CONF_DIR"/*.conf 2>/dev/null | xargs -n1 basename)"
    exit 1
  fi

  local eth1_ip
  eth1_ip=$(ip -4 addr show "$IFACE" | grep -oP 'inet \K[\d.]+')
  if [ -z "$eth1_ip" ]; then
    echo "ERROR: Could not determine $IFACE IP"
    exit 1
  fi

  local cluster_dir
  if [ "$system" = "garnet" ]; then
    cluster_dir="$HOME/garnet-cluster"
  else
    cluster_dir="$HOME/valkey-cluster"
  fi
  mkdir -p "$cluster_dir"

  for (( i=0; i<nodes; i++ )); do
    local port=$(( BASE_PORT + i ))
    local port_dir="$cluster_dir/$port"
    mkdir -p "$port_dir"
    if [ "$system" = "garnet" ]; then
      sed -e "s/\$eth1/$eth1_ip/g" -e "s/\$port/$port/g" \
          -e "s/\"EnableCluster\": true/\"EnableCluster\": $CLUSTER_MODE/g" \
          "$tmpl_file" > "$port_dir/garnet.conf"
    else
      sed -e "s/\$eth1/$eth1_ip/g" -e "s/\$port/$port/g" "$tmpl_file" > "$port_dir/valkey.conf"
      if [ "$CLUSTER_MODE" = "true" ]; then
        grep -q "^cluster-enabled" "$port_dir/valkey.conf" && \
          sed -i "s/^cluster-enabled.*/cluster-enabled yes/" "$port_dir/valkey.conf" || \
          echo "cluster-enabled yes" >> "$port_dir/valkey.conf"
      else
        grep -q "^cluster-enabled" "$port_dir/valkey.conf" && \
          sed -i "s/^cluster-enabled.*/cluster-enabled no/" "$port_dir/valkey.conf" || \
          echo "cluster-enabled no" >> "$port_dir/valkey.conf"
      fi
    fi
  done
  echo "Resolved $nodes config(s) from ${system}-${template}.conf (cluster=$CLUSTER_MODE) -> $cluster_dir/"
}

start_valkey() {
  local nodes="$1"
  local cluster_dir="$HOME/valkey-cluster"
  echo "Starting $nodes valkey-server instances (ports ${BASE_PORT}-$(( BASE_PORT + nodes - 1 )))..."
  for (( i=0; i<nodes; i++ )); do
    local port=$(( BASE_PORT + i ))
    local dir="$cluster_dir/$port"
    if [ ! -f "$dir/valkey.conf" ]; then
      echo "  ERROR: $dir/valkey.conf not found"
      exit 1
    fi
    if pgrep -f "valkey-server.*:${port}" > /dev/null 2>&1; then
      echo "  Port $port: already running (skipped)"
      continue
    fi
    cd "$dir"
    valkey-server "$dir/valkey.conf"
    echo "  Port $port: started"
  done
}

start_garnet() {
  local nodes="$1"
  local cluster_dir="$HOME/garnet-cluster"
  echo "Starting $nodes GarnetServer instance(s)..."
  for (( i=0; i<nodes; i++ )); do
    local port=$(( BASE_PORT + i ))
    local dir="$cluster_dir/$port"
    if [ ! -f "$dir/garnet.conf" ]; then
      echo "  ERROR: $dir/garnet.conf not found"
      exit 1
    fi
    if pgrep -f "GarnetServer.*--port ${port}" > /dev/null 2>&1; then
      echo "  Port $port: already running (skipped)"
      continue
    fi
    GarnetServer $(cat "$dir/garnet.conf" | grep -v '^#') &
    echo "  Port $port: started (pid $!)"
  done
}

stop_system() {
  local system="$1" nodes="$2"
  if [ "$system" = "garnet" ]; then
    if [ -n "$nodes" ]; then
      for (( i=0; i<nodes; i++ )); do
        local port=$(( BASE_PORT + i ))
        local pid=$(pgrep -f "GarnetServer.*--port ${port}" 2>/dev/null)
        if [ -n "$pid" ]; then
          kill $pid; echo "  Garnet port $port: stopped (pid $pid)"
        else
          echo "  Garnet port $port: not running"
        fi
      done
    else
      pkill -f "GarnetServer" 2>/dev/null && echo "All GarnetServer instances stopped." || echo "No GarnetServer running."
    fi
  else
    if [ -n "$nodes" ]; then
      for (( i=0; i<nodes; i++ )); do
        local port=$(( BASE_PORT + i ))
        local pid=$(pgrep -f "valkey-server.*:${port}" 2>/dev/null)
        if [ -n "$pid" ]; then
          kill $pid; echo "  Valkey port $port: stopped (pid $pid)"
        else
          echo "  Valkey port $port: not running"
        fi
      done
    else
      pkill -f "valkey-server" 2>/dev/null && echo "All valkey-server instances stopped." || echo "No valkey-server running."
    fi
  fi
}

case "$ACTION" in
  start)
    SYSTEM="${2:?Usage: mcluster start <system> <template> <nodes> [--cluster|--no-cluster]}"
    TEMPLATE="${3:?Usage: mcluster start <system> <template> <nodes> [--cluster|--no-cluster]}"
    NODES="${4:?Usage: mcluster start <system> <template> <nodes> [--cluster|--no-cluster]}"
    if [ "${5:-}" = "--no-cluster" ]; then
      CLUSTER_MODE="false"
    elif [ "${5:-}" = "--cluster" ]; then
      CLUSTER_MODE="true"
    fi

    pull_configs
    resolve_template "$SYSTEM" "$TEMPLATE" "$NODES"

    if [ "$SYSTEM" = "garnet" ]; then
      start_garnet "$NODES"
    else
      start_valkey "$NODES"
    fi
    echo "Done."
    ;;

  stop)
    SYSTEM="${2:-}"
    NODES="${3:-}"
    if [ -z "$SYSTEM" ]; then
      echo "Stopping all instances..."
      pkill -f "valkey-server" 2>/dev/null && echo "  valkey-server stopped." || true
      pkill -f "GarnetServer" 2>/dev/null && echo "  GarnetServer stopped." || true
      echo "Done."
    else
      stop_system "$SYSTEM" "$NODES"
    fi
    ;;

  *)
    echo "Unknown action: $ACTION"
    echo "Usage: mcluster start <system> <template> <nodes> [--cluster|--no-cluster]"
    echo "       mcluster stop [system] [nodes]"
    exit 1
    ;;
esac
