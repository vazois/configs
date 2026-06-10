#!/bin/bash
# Usage:
#   mcluster start <system> <template> <nodes> [--cluster|--no-cluster] [--clean]
#   mcluster stop [system] [nodes]
#   mcluster clean [system]
#   mcluster update <system> <template> [nodes] [--cluster|--no-cluster]
#
# Examples:
#   mcluster start valkey cache 16              - start 16 valkey instances (cluster enabled)
#   mcluster start valkey cache 16 --no-cluster - start 16 valkey instances (standalone)
#   mcluster start valkey cache 16 --clean      - clean dirs, then start 16 instances
#   mcluster start garnet cache 1               - start 1 GarnetServer (cluster enabled)
#   mcluster start garnet cache 1 --no-cluster  - start 1 GarnetServer (cluster disabled)
#   mcluster stop valkey 16                     - stop 16 valkey instances by port
#   mcluster stop garnet                        - stop all GarnetServer instances
#   mcluster stop                               - stop all (valkey + garnet)
#   mcluster clean valkey                       - remove valkey-cluster directory
#   mcluster clean garnet                       - remove garnet-cluster directory
#   mcluster clean                              - remove both cluster directories
#   mcluster update garnet cache                - pull latest configs, regenerate existing configs
#   mcluster update valkey cache 16             - pull latest configs, regenerate 16 configs

source /opt/deploy-actions/config.env
ACTION="${1:?Usage: mcluster [start|stop|update] <system> <template> <nodes> [--cluster|--no-cluster]}"
CONF_DIR="$HOME/configs"
CLUSTER_MODE="true"
TOTAL_CORES=$(nproc)

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
  local irq_cores=$(( nodes * 2 ))
  local cores_per_instance=6
  local required_cores=$(( irq_cores + nodes * cores_per_instance ))

  if [ "$required_cores" -gt "$TOTAL_CORES" ]; then
    echo "ERROR: Need $required_cores cores ($irq_cores IRQ + $nodes×$cores_per_instance valkey) but only $TOTAL_CORES available"
    exit 1
  fi

  # Apply valkey network profile (RSS queues, IRQ pinning, stop irqbalance)
  echo "Applying valkey network profile ($nodes instances, $irq_cores IRQ cores)..."
  sudo /opt/deploy-actions/setup-network.sh valkey "$nodes"

  echo "Starting $nodes valkey-server instances (ports ${BASE_PORT}-$(( BASE_PORT + nodes - 1 )))..."
  echo "  CPU layout: IRQ cores 0-$(( irq_cores - 1 )), then $cores_per_instance cores per instance"
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
    local cpu_start=$(( irq_cores + i * cores_per_instance ))
    local cpu_end=$(( cpu_start + cores_per_instance - 1 ))
    cd "$dir"
    taskset -c ${cpu_start}-${cpu_end} valkey-server "$dir/valkey.conf"
    echo "  Port $port: started (pinned to CPU ${cpu_start}-${cpu_end})"
  done
}

start_garnet() {
  local nodes="$1"
  local cluster_dir="$HOME/garnet-cluster"

  # Apply garnet network profile (maximize RSS queues, spread IRQs)
  echo "Applying garnet network profile..."
  sudo /opt/deploy-actions/setup-network.sh garnet "$nodes"

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
    GarnetServer --config-import-path="$dir/garnet.conf" &
    echo "  Port $port: started (pid $!, using all cores)"
  done
}

clean_system() {
  local system="$1"
  if [ "$system" = "garnet" ] || [ -z "$system" ]; then
    local garnet_dir="$HOME/garnet-cluster"
    if [ -d "$garnet_dir" ]; then
      rm -rf "$garnet_dir"
      echo "  Removed $garnet_dir"
    else
      echo "  $garnet_dir does not exist (skipped)"
    fi
  fi
  if [ "$system" = "valkey" ] || [ -z "$system" ]; then
    local valkey_dir="$HOME/valkey-cluster"
    if [ -d "$valkey_dir" ]; then
      rm -rf "$valkey_dir"
      echo "  Removed $valkey_dir"
    else
      echo "  $valkey_dir does not exist (skipped)"
    fi
  fi
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
    SYSTEM="${2:?Usage: mcluster start <system> <template> <nodes> [--cluster|--no-cluster] [--clean]}"
    TEMPLATE="${3:?Usage: mcluster start <system> <template> <nodes> [--cluster|--no-cluster] [--clean]}"
    NODES="${4:?Usage: mcluster start <system> <template> <nodes> [--cluster|--no-cluster] [--clean]}"
    # Parse optional flags
    shift 4
    for arg in "$@"; do
      case "$arg" in
        --no-cluster) CLUSTER_MODE="false" ;;
        --cluster)    CLUSTER_MODE="true" ;;
        --clean)      echo "Cleaning $SYSTEM cluster directory..."; clean_system "$SYSTEM" ;;
      esac
    done

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
      local valkey_pids=$(pgrep -f "valkey-server" 2>/dev/null)
      if [ -n "$valkey_pids" ]; then
        echo "$valkey_pids" | while read -r pid; do
          local port=$(ps -p $pid -o args= 2>/dev/null | grep -oP ':\K[0-9]+' | head -1)
          kill $pid
          echo "  valkey-server port ${port:-?}: stopped (pid $pid)"
        done
      else
        echo "  No valkey-server running."
      fi
      local garnet_pids=$(pgrep -f "GarnetServer" 2>/dev/null)
      if [ -n "$garnet_pids" ]; then
        echo "$garnet_pids" | while read -r pid; do
          local port=$(ps -p $pid -o args= 2>/dev/null | grep -oP '\-\-port \K[0-9]+' | head -1)
          kill $pid
          echo "  GarnetServer port ${port:-?}: stopped (pid $pid)"
        done
      else
        echo "  No GarnetServer running."
      fi
      echo "Done."
    else
      stop_system "$SYSTEM" "$NODES"
    fi
    ;;

  update)
    SYSTEM="${2:?Usage: mcluster update <system> <template> [nodes] [--cluster|--no-cluster]}"
    TEMPLATE="${3:?Usage: mcluster update <system> <template> [nodes] [--cluster|--no-cluster]}"
    NODES="${4:-}"
    if [ "${5:-}" = "--no-cluster" ]; then
      CLUSTER_MODE="false"
    elif [ "${5:-}" = "--cluster" ]; then
      CLUSTER_MODE="true"
    fi

    pull_configs

    # Auto-detect node count from existing cluster dir if not specified
    if [ -z "$NODES" ]; then
      if [ "$SYSTEM" = "garnet" ]; then
        UPDATE_DIR="$HOME/garnet-cluster"
      else
        UPDATE_DIR="$HOME/valkey-cluster"
      fi
      NODES=$(find "$UPDATE_DIR" -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | wc -l)
      if [ "$NODES" -eq 0 ]; then
        echo "ERROR: No existing cluster dir found and no node count specified"
        exit 1
      fi
    fi

    resolve_template "$SYSTEM" "$TEMPLATE" "$NODES"
    echo "Updated configs in place. Restart instances to apply."
    ;;

  clean)
    SYSTEM="${2:-}"
    echo "Cleaning cluster directories..."
    clean_system "$SYSTEM"
    echo "Done."
    ;;

  *)
    echo "Unknown action: $ACTION"
    echo "Usage: mcluster start <system> <template> <nodes> [--cluster|--no-cluster] [--clean]"
    echo "       mcluster stop [system] [nodes]"
    echo "       mcluster clean [system]"
    echo "       mcluster update <system> <template> [nodes] [--cluster|--no-cluster]"
    exit 1
    ;;
esac
