#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${CACHE_DIR:-/tmp/pneuma-zig-cache}"
GLOBAL_CACHE_DIR="${GLOBAL_CACHE_DIR:-/tmp/pneuma-zig-global-cache}"
TICKS="${1:-100000}"
shift || true
STAGE4_TIMINGS_STRING="${STAGE4_TIMINGS:-93000}"
STAGE4_ENERGIES_STRING="${STAGE4_ENERGIES:-3000}"
STAGE4_RESEED_POLICIES_STRING="${STAGE4_RESEED_POLICIES:-stage4}"

if [ "$#" -eq 0 ]; then
  SEEDS=(1 2 3 4 5)
else
  SEEDS=("$@")
fi

read -r -a STAGE4_TIMINGS <<< "$STAGE4_TIMINGS_STRING"
read -r -a STAGE4_ENERGIES <<< "$STAGE4_ENERGIES_STRING"
read -r -a STAGE4_RESEED_POLICIES <<< "$STAGE4_RESEED_POLICIES_STRING"

mkdir -p "$CACHE_DIR" "$GLOBAL_CACHE_DIR"

for timing in "${STAGE4_TIMINGS[@]}"; do
  for energy in "${STAGE4_ENERGIES[@]}"; do
    for policy in "${STAGE4_RESEED_POLICIES[@]}"; do
      for seed in "${SEEDS[@]}"; do
        timing_slug="${timing//[^[:alnum:]]/_}"
        log="/tmp/pneuma_seed_${seed}_${TICKS}_inj_${timing_slug}_e_${energy}_reseed_${policy}.err"
        echo "=== seed=${seed} ticks=${TICKS} inject=${timing} energy=${energy} reseed=${policy} ==="
        zig run -O ReleaseFast "$ROOT/src/main.zig" \
          --cache-dir "$CACHE_DIR" \
          --global-cache-dir "$GLOBAL_CACHE_DIR" \
          -- "$TICKS" "$seed" "$timing" "$energy" "$policy" 2> "$log"

        grep -E '^=== Pneuma started|^t=13000|^t=50000|^t=90000|^t=91500|^t=95000|^t=100000|^Stopped at tick|^All organisms dead|^  event' "$log" || true
        echo "log=$log"
        echo
      done
    done
  done
done
