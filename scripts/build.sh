#!/bin/bash
# Usage: build.sh <system> [branch] [tls]
# Examples:
#   build.sh valkey              - build valkey (current branch)
#   build.sh valkey 9.0          - checkout tag 9.0 and build
#   build.sh valkey 9.0 tls      - checkout tag 9.0, build with TLS
#   build.sh redis "" tls        - build redis (current branch) with TLS
#   build.sh garnet              - build garnet (current branch)
#   build.sh garnet main         - checkout main and build
#   build.sh resp-bench          - build Resp.benchmark (vazois/cluster-bench branch)
#   build.sh memtier             - build memtier_benchmark
set -e
source /opt/deploy-actions/config.env

SYSTEM="${1:?Usage: build.sh <system> [branch] [tls]}"
BRANCH="${2:-}"
TLS="${3:-}"

build_valkey_redis() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    echo "ERROR: $dir not found. Clone the repo first."
    exit 1
  fi
  cd "$dir"

  if [ -n "$BRANCH" ]; then
    echo "==== Checking out $SYSTEM $BRANCH ===="
    sudo -u $DEPLOY_USER git fetch --tags
    sudo -u $DEPLOY_USER git checkout "$BRANCH"
  fi

  make distclean 2>/dev/null || true

  if [ "$TLS" = "tls" ]; then
    echo "==== Building $SYSTEM with TLS ===="
    sudo -u $DEPLOY_USER make -j$(nproc) BUILD_TLS=yes
  else
    echo "==== Building $SYSTEM ===="
    sudo -u $DEPLOY_USER make -j$(nproc)
  fi

  echo "==== Installing $SYSTEM ===="
  sudo make install

  echo "==== Build complete ===="
  src/redis-server --version 2>/dev/null || src/valkey-server --version
}

build_garnet() {
  if [ ! -d "$GARNET_DIR" ]; then
    echo "ERROR: $GARNET_DIR not found. Clone the garnet repo first."
    exit 1
  fi
  cd "$GARNET_DIR"

  if [ -n "$BRANCH" ]; then
    echo "==== Checking out $BRANCH ===="
    sudo -u $DEPLOY_USER git fetch --all --tags
    sudo -u $DEPLOY_USER git checkout "$BRANCH"
  fi

  ARCH=$(uname -m)
  if [ "$ARCH" = "aarch64" ]; then
    RID="linux-arm64"
  else
    RID="linux-x64"
  fi

  echo "==== Building GarnetServer (Release, $RID) ===="
  sudo -u $DEPLOY_USER dotnet publish $GARNET_PROJECT -c Release -r $RID -f net10.0 -o "$GARNET_DIR/publish"

  mkdir -p "$INSTALL_DIR/garnet"
  cp -r "$GARNET_DIR/publish/"* "$INSTALL_DIR/garnet/"
  ln -sf "$INSTALL_DIR/garnet/GarnetServer" "$INSTALL_DIR/GarnetServer"
  chmod +x "$INSTALL_DIR/garnet/GarnetServer"

  echo "==== Build complete ===="
  GarnetServer --version 2>/dev/null || echo "GarnetServer installed at $INSTALL_DIR/GarnetServer"
}

build_memtier() {
  if [ ! -d "$MEMTIER_DIR" ]; then
    echo "ERROR: $MEMTIER_DIR not found. Clone the repo first."
    exit 1
  fi
  cd "$MEMTIER_DIR"

  if [ -n "$BRANCH" ]; then
    echo "==== Checking out memtier $BRANCH ===="
    sudo -u $DEPLOY_USER git fetch --tags
    sudo -u $DEPLOY_USER git checkout "$BRANCH"
  fi

  echo "==== Building memtier_benchmark ===="
  autoreconf -ivf
  ./configure
  make -j$(nproc)
  sudo make install

  echo "==== Build complete ===="
  memtier_benchmark --version
}

build_resp_bench() {
  if [ ! -d "$GARNET_DIR" ]; then
    echo "ERROR: $GARNET_DIR not found. Clone the garnet repo first."
    exit 1
  fi
  cd "$GARNET_DIR"

  if [ -n "$BRANCH" ]; then
    echo "==== Checking out $BRANCH ===="
    sudo -u $DEPLOY_USER git fetch --all
    sudo -u $DEPLOY_USER git checkout "$BRANCH"
  fi

  ARCH=$(uname -m)
  if [ "$ARCH" = "aarch64" ]; then
    RID="linux-arm64"
  else
    RID="linux-x64"
  fi

  echo "==== Building Resp.benchmark (Release, $RID) ===="
  sudo -u $DEPLOY_USER dotnet publish $RESP_BENCH_PROJECT -c Release -r $RID -f net10.0 -o "$GARNET_DIR/resp-bench-publish"

  mkdir -p "$INSTALL_DIR/resp-bench"
  cp -r "$GARNET_DIR/resp-bench-publish/"* "$INSTALL_DIR/resp-bench/"
  ln -sf "$INSTALL_DIR/resp-bench/Resp.benchmark" "$INSTALL_DIR/Resp.benchmark"
  chmod +x "$INSTALL_DIR/resp-bench/Resp.benchmark"

  echo "==== Resp.benchmark build complete ===="
  echo "Installed at $INSTALL_DIR/resp-bench/Resp.benchmark"
}

case "$SYSTEM" in
  redis)       build_valkey_redis "$REDIS_DIR" ;;
  valkey)      build_valkey_redis "$VALKEY_DIR" ;;
  garnet)      build_garnet ;;
  resp-bench)  build_resp_bench ;;
  memtier)     build_memtier ;;
  *)           echo "Unknown system: $SYSTEM (use redis, valkey, garnet, resp-bench, or memtier)"; exit 1 ;;
esac
