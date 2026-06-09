#!/bin/bash
set -e

# Download Microsoft's official installer
wget https://dot.net/v1/dotnet-install.sh -O /tmp/deploy-actions/dotnet-install.sh
chmod +x /tmp/deploy-actions/dotnet-install.sh

# Install latest SDK for each major channel
CHANNELS=("8.0" "9.0" "10.0")
for channel in "${CHANNELS[@]}"; do
  echo "Installing .NET SDK channel $channel (latest)"
  /tmp/deploy-actions/dotnet-install.sh --channel $channel --install-dir /usr/share/dotnet --no-path
done

# Setup PATH
ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet
chmod +x /usr/share/dotnet/dotnet
