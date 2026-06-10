#!/bin/bash
set -e

# Usage: memtier-bench <address> <port> [threads] [clients] [pipeline] [dbSize] [dataSize] [testTime] [skip-load] [cluster]
#   address   - server IP to benchmark
#   port      - server port
#   threads   - number of threads (default: 128)
#   clients   - number of clients per thread (default: 64)
#   pipeline  - pipeline depth (default: 1024)
#   dbSize    - number of keys to load (default: 268435456)
#   dataSize  - value size in bytes (default: 8)
#   testTime  - benchmark duration in seconds (default: 15)
#   skip-load - pass "skip" to skip the key loading phase
#   cluster   - pass "cluster" to enable --cluster-mode

address=${1:?Usage: memtier-bench <address> <port> [threads] [clients] [pipeline] [dbSize] [dataSize] [testTime] [skip-load] [cluster]}
port=${2:?Usage: memtier-bench <address> <port> [threads] [clients] [pipeline] [dbSize] [dataSize] [testTime] [skip-load] [cluster]}
startThreads=${3:-128}
endThreads=$startThreads
clients=${4:-64}
pipeline=${5:-1024}
dbSize=${6:-1048576}
dataSize=${7:-8}
testTime=${8:-15}
skipLoad=${9:-""}
clusterOpt=${10:-""}

CLUSTER_FLAG=""
if [ "$clusterOpt" = "cluster" ]; then
  CLUSTER_FLAG="--cluster-mode"
fi

# Print parameters for this run
echo "==== Parameters ===="
echo "  address:    $address"
echo "  port:       $port"
echo "  threads:    $startThreads"
echo "  clients:    $clients"
echo "  pipeline:   $pipeline"
echo "  dbSize:     $dbSize"
echo "  dataSize:   $dataSize"
echo "  testTime:   $testTime"
echo "  skipLoad:   ${skipLoad:-no}"
echo "  cluster:    ${clusterOpt:-no}"
echo ""

# Phase 1: Load keys (skip if "skip" is passed as 9th arg)
if [ "$skipLoad" != "skip" ]; then
  echo "==== Loading keys ===="
  memtier_benchmark -s $address \
      --port=$port \
      --ratio=1:0 \
      --pipeline=$pipeline \
      --data-size=$dataSize \
      --clients=$clients \
      --threads=$startThreads \
      --key-minimum=1 \
      --key-maximum=$dbSize \
      --key-pattern=P:P \
      --run-count=1 \
      --hide-histogram \
      --requests=allkeys \
      $CLUSTER_FLAG
else
  echo "==== Skipping load phase ===="
fi

echo ""
echo "==== Running benchmark ===="
all_results=""

for (( i=$startThreads; i<=$endThreads; i*=2 ))
do
    memtier_benchmark -s $address \
        --port=$port \
        --ratio=1:9 \
        --pipeline=$pipeline \
        --data-size=$dataSize \
        --clients=$clients \
        --threads=$i \
        --test-time=$testTime \
        --run-count=1 \
        --hide-histogram \
        --key-minimum=1 \
        --key-maximum=$dbSize \
        --key-pattern=R:R \
        $CLUSTER_FLAG \
        2>&1 | tee /tmp/memtier-last-run.txt

        result=$(grep "Totals" /tmp/memtier-last-run.txt | tail -n 1)
        echo "$i $result"
        all_results+="$result"$'\n'
done

echo ""
echo "==== Final Summary ===="
echo "pipeline: $pipeline, threads: $startThreads, clients: $clients, payload: $dataSize, dbSize: $dbSize, testTime: $testTime"
echo "$all_results"
