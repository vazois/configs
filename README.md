# Node Configuration Templates

Configuration templates for VMSS cluster deployments (Valkey/Redis and Garnet).

## Structure

```
├── valkey-cache.conf     # Valkey/Redis in-memory cluster
├── valkey-disk.conf      # Valkey/Redis larger-than-memory cluster
├── garnet-cache.conf     # Garnet in-memory cluster
├── garnet-disk.conf      # Garnet larger-than-memory cluster
├── setup-config.sh       # Resolves templates → per-port configs
└── broadcast             # SSH command/file distribution across nodes
```

## Placeholders

Templates use these placeholders (resolved at runtime by `setup-config.sh`):

| Placeholder | Resolved to |
|-------------|-------------|
| `$eth1` | Secondary NIC IP (data plane) |
| `$port` | Instance port (7000 + i) |

## Usage

```bash
# Clone to ~/node-conf/ on each VM (done via cloud-init or broadcast)
git clone https://github.com/vazois/configs.git ~/node-conf

# Generate 16-node valkey cluster configs (in-memory)
setup-config.sh valkey cache 16

# Generate garnet cluster configs (larger-than-memory)
setup-config.sh garnet disk 16

# Start the cluster
mcluster start 16 valkey

# Update configs on all nodes
broadcast --copy ~/node-conf/valkey-cache.conf ~/node-conf/valkey-cache.conf
broadcast "setup-config.sh valkey cache 16 && mcluster start 16 valkey"
```

## Deployment

Templates are deployed to `~/node-conf/` on each VM either:
1. Via cloud-init at VMSS creation
2. Via `git pull` for updates
3. Via `broadcast --copy` for ad-hoc pushes
