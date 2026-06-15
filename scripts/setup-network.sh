#!/bin/bash
set -e
source /opt/deploy-actions/config.env

# =============================================================
# Network configuration script for Azure VMSS instances.
# Configures eth1 (secondary NIC) for cross-VM communication
# used in Redis/Valkey/Garnet benchmarking scenarios.
#
# Usage:
#   setup-network.sh [engine] [nodes]
#     engine - "valkey" or "garnet" (default: garnet)
#     nodes  - number of instances (default: 1, used for valkey IRQ scaling)
#
# Engine profiles:
#   valkey: limit RSS queues to nodes*2, pin IRQs to first nodes*2 cores, stop irqbalance
#   garnet: maximize RSS queues, spread IRQs across all cores (inline processing)
# =============================================================

ENGINE="${1:-garnet}"
NODES="${2:-1}"
TOTAL_CORES=$(nproc)

# -------------------------------------------------------------
# 1. Engine-Specific RSS & IRQ Configuration
# -------------------------------------------------------------
configure_irq_valkey() {
  local irq_cores=$(( NODES * 2 ))
  if [ "$irq_cores" -ge "$TOTAL_CORES" ]; then
    echo "ERROR: IRQ cores ($irq_cores) >= total cores ($TOTAL_CORES). Reduce node count."
    exit 1
  fi

  echo "[valkey] Configuring $irq_cores RSS queues for $NODES instances on $TOTAL_CORES cores"

  # Set RSS queues to nodes*2
  if [ -d "/sys/class/net/$IFACE" ]; then
    local max_q=$(ethtool -l $IFACE 2>/dev/null | grep -m1 "Combined:" | awk '{print $2}')
    local target_q=$irq_cores
    if [ "$target_q" -gt "$max_q" ]; then
      echo "  WARNING: Requested $target_q queues but max is $max_q, using $max_q"
      target_q=$max_q
    fi
    echo "  [$IFACE] Setting RSS queues to $target_q"
    ethtool -L $IFACE combined $target_q
  fi

  # Pin each IRQ to a dedicated core (0 through irq_cores-1)
  local irqs=($(grep -w "$IFACE" /proc/interrupts | awk '{gsub(":",""); print $1}'))
  local cpu=0
  for irq in "${irqs[@]}"; do
    if [ "$cpu" -ge "$irq_cores" ]; then
      break
    fi
    echo "$cpu" > /proc/irq/$irq/smp_affinity_list
    echo "  IRQ $irq -> CPU $cpu"
    cpu=$((cpu + 1))
  done

  # Stop irqbalance to prevent it from overriding our pinning
  systemctl stop irqbalance 2>/dev/null || true
  systemctl disable irqbalance 2>/dev/null || true
  echo "  irqbalance stopped and disabled"
}

configure_irq_garnet() {
  echo "[garnet] Maximizing RSS queues for inline processing on $TOTAL_CORES cores"

  # Maximize RSS queues — spread across all cores
  for NIC in eth0 $IFACE; do
    if [ -d "/sys/class/net/$NIC" ]; then
      local max_q=$(ethtool -l $NIC 2>/dev/null | grep -m1 "Combined:" | awk '{print $2}')
      if [ -n "$max_q" ] && [ "$max_q" -gt 0 ]; then
        local current_q=$(ethtool -l $NIC | grep -A4 "Current" | grep "Combined:" | awk '{print $2}')
        if [ "$current_q" -lt "$max_q" ]; then
          echo "  [$NIC] Setting RSS queues from $current_q to $max_q"
          ethtool -L $NIC combined $max_q
        else
          echo "  [$NIC] Already at max RSS queues ($max_q)"
        fi
      fi
    fi
  done

  # Spread IRQ affinity across all cores (round-robin)
  local irqs=($(grep -w "$IFACE" /proc/interrupts | awk '{gsub(":",""); print $1}'))
  local cpu=0
  for irq in "${irqs[@]}"; do
    echo "$cpu" > /proc/irq/$irq/smp_affinity_list
    echo "  IRQ $irq -> CPU $cpu"
    cpu=$(( (cpu + 1) % TOTAL_CORES ))
  done
}

case "$ENGINE" in
  valkey)
    configure_irq_valkey
    ;;
  garnet)
    configure_irq_garnet
    ;;
  *)
    echo "Unknown engine: $ENGINE (expected 'valkey' or 'garnet')"
    exit 1
    ;;
esac

# -------------------------------------------------------------
# 2. Policy-Based Routing for eth1
#    By default, reply traffic from eth1's IP exits via eth0
#    (asymmetric routing). Azure drops these packets. We fix this
#    by creating a separate routing table (100) for eth1 traffic.
# -------------------------------------------------------------
ETH1_IP=$(ip -4 addr show dev $IFACE | grep -oP 'inet \K[\d.]+')
ETH1_CIDR=$(ip -4 addr show dev $IFACE | grep -oP 'inet \K[\d./]+')
SUBNET_CIDR=$(echo "$ETH1_CIDR" | sed 's/\.[0-9]*\//\.0\//')

if [ -z "$ETH1_IP" ]; then
  echo "ERROR: No IP found on $IFACE, skipping routing setup"
  exit 0
fi

echo "Configuring policy routing for $IFACE (IP: $ETH1_IP, Subnet: $SUBNET_CIDR)"

# Disable reverse path filtering so inbound packets on eth1
# are not dropped by the kernel's source validation check
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.$IFACE.rp_filter=0

# Route eth1 subnet traffic through table 100 via eth1
ip route add $SUBNET_CIDR dev $IFACE src $ETH1_IP table 100 2>/dev/null || true

# Force all packets with src=eth1_IP to use routing table 100
ip rule add from $ETH1_IP table 100 priority 100 2>/dev/null || true

# -------------------------------------------------------------
# 3. Iptables Rules
#    Default INPUT policy is DROP on Azure Linux. Open ICMP for
#    ping diagnostics, TCP 6379 for Redis/Valkey/Garnet, and
#    SSH (22) for inter-VM communication within the subnet.
# -------------------------------------------------------------
iptables -C INPUT -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null || \
  iptables -I INPUT -p icmp --icmp-type echo-request -j ACCEPT
iptables -C INPUT -p icmp --icmp-type echo-reply -j ACCEPT 2>/dev/null || \
  iptables -I INPUT -p icmp --icmp-type echo-reply -j ACCEPT
iptables -C INPUT -i $IFACE -p tcp --dport 6379 -j ACCEPT 2>/dev/null || \
  iptables -I INPUT -i $IFACE -p tcp --dport 6379 -j ACCEPT
iptables -C INPUT -i $IFACE -p tcp --dport 7000:7099 -j ACCEPT 2>/dev/null || \
  iptables -I INPUT -i $IFACE -p tcp --dport 7000:7099 -j ACCEPT
iptables -C INPUT -i $IFACE -p tcp --dport 17000:17099 -j ACCEPT 2>/dev/null || \
  iptables -I INPUT -i $IFACE -p tcp --dport 17000:17099 -j ACCEPT
# Allow SSH between VMs in the same subnet
iptables -C INPUT -p tcp --dport 22 -s $SUBNET -j ACCEPT 2>/dev/null || \
  iptables -I INPUT -p tcp --dport 22 -s $SUBNET -j ACCEPT

# -------------------------------------------------------------
# 4. TCP Tuning for High-Throughput Benchmarking
#    Increase socket buffer sizes and backlog to sustain multi-GB/s
#    traffic without kernel-level drops.
# -------------------------------------------------------------
sysctl -w net.core.wmem_max=67108864
sysctl -w net.core.netdev_max_backlog=250000
sysctl -w net.ipv4.tcp_rmem="4096 87380 33554432"
sysctl -w net.ipv4.tcp_wmem="4096 87380 33554432"

# -------------------------------------------------------------
# 5. File Descriptor Limits
#    Raise open file limit for high-connection benchmarks.
# -------------------------------------------------------------
cat >> /etc/security/limits.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
sudo sysctl -w fs.nr_open=1048576
sudo sysctl -w fs.file-max=2097152

echo "Network setup complete ($ENGINE mode, $NODES nodes): RSS/IRQ, routing, iptables, TCP tuning, fd limits."
