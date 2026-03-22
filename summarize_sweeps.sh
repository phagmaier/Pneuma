#!/bin/bash
set -euo pipefail

MIN_REQUESTED_TICKS="${MIN_REQUESTED_TICKS:-100000}"

if [ "$#" -eq 0 ]; then
  set -- /tmp/pneuma_seed_*_inj_*.err
fi

have_files=0
for path in "$@"; do
  if [ -e "$path" ]; then
    have_files=1
    break
  fi
done

if [ "$have_files" -eq 0 ]; then
  echo "No matching log files found." >&2
  exit 1
fi

extract_field() {
  local text="$1"
  local expr="$2"
  sed -n "$expr" <<< "$text" | head -n1
}

requested_ticks_from_path() {
  local log="$1"
  sed -n 's#^.*/pneuma_seed_[^_]*_\([0-9]\+\)_inj_.*#\1#p' <<< "$log" | head -n1
}

classify_verdict() {
  local status="$1"
  local end_tick="$2"
  local stage4_full_events="$3"
  local stage4_partial_events="$4"
  local final_s4f="$5"

  if [ "$status" = "dead" ] && [ "${end_tick:-0}" -lt 90000 ]; then
    echo "died_pre_stage4"
    return
  fi
  if [ "${stage4_full_events:-0}" -gt 0 ] && [ "${final_s4f:-0}" -gt 0 ]; then
    echo "persistent_stage4"
    return
  fi
  if [ "${stage4_full_events:-0}" -gt 0 ] || [ "${stage4_partial_events:-0}" -gt 0 ]; then
    echo "flash_only"
    return
  fi
  if [ "${end_tick:-0}" -ge 90000 ]; then
    echo "no_stage4"
    return
  fi
  echo "pre_stage4"
}

echo -e "file\trequested_ticks\tseed\tinject\tenergy\treseed_policy\tstatus\tend_tick\tsurvived_90k\tverdict\tfinal_pop\tfinal_stage\tfinal_lineages\tfinal_harv\tfinal_ph\tfinal_reseeds\tfinal_i4\tfinal_s4r\tfinal_s4f\tstage4_full_events\tstage4_partial_events\tfirst_stage4_tick\tlast_stage4_tick"

for log in "$@"; do
  [ -e "$log" ] || continue
  if [ ! -s "$log" ]; then
    continue
  fi

  requested_ticks="$(requested_ticks_from_path "$log")"
  if [ -n "$requested_ticks" ] && [ "$requested_ticks" -lt "$MIN_REQUESTED_TICKS" ]; then
    continue
  fi

  start_line="$(grep '^=== Pneuma started' "$log" | head -n1 || true)"
  final_line="$(grep '^t=' "$log" | tail -n1 || true)"
  death_line="$(grep '^All organisms dead at tick ' "$log" | tail -n1 || true)"
  stop_line="$(grep '^Stopped at tick ' "$log" | tail -n1 || true)"
  stage4_full_count="$(grep -Ec '^  event .* stage=4 out=full ' "$log" || true)"
  stage4_partial_count="$(grep -Ec '^  event .* stage=4 out=part ' "$log" || true)"
  first_stage4_tick="$(sed -n 's/^  event t=\([0-9]\+\).* stage=4 .*/\1/p' "$log" | head -n1)"
  last_stage4_tick="$(sed -n 's/^  event t=\([0-9]\+\).* stage=4 .*/\1/p' "$log" | tail -n1)"

  seed="$(extract_field "$start_line" 's/^=== Pneuma started seed=\([^ ]*\) .*/\1/p')"
  inject="$(extract_field "$start_line" 's/^=== Pneuma started .* stage4_inject=\([^ ]*\) .*/\1/p')"
  energy="$(extract_field "$start_line" 's/^=== Pneuma started .* stage4_energy=\([^ ]*\) .*/\1/p')"
  reseed_policy="$(extract_field "$start_line" 's/^=== Pneuma started .* stage4_reseed=\([^ ]*\) ===$/\1/p')"

  if [ -n "$death_line" ]; then
    status="dead"
    end_tick="$(extract_field "$death_line" 's/^All organisms dead at tick \([0-9]\+\)$/\1/p')"
  elif [ -n "$stop_line" ]; then
    status="stopped"
    end_tick="$(extract_field "$stop_line" 's/^Stopped at tick \([0-9]\+\) due to maxTicks=[0-9]\+$/\1/p')"
  else
    status="running"
    end_tick="$(extract_field "$final_line" 's/^t=\([0-9]\+\) .*/\1/p')"
  fi

  survived_90k="no"
  if [ -n "$end_tick" ] && [ "$end_tick" -ge 90000 ]; then
    survived_90k="yes"
  fi

  final_pop="$(extract_field "$final_line" 's/^t=[0-9]\+ *pop=\([0-9]\+\) .*/\1/p')"
  final_stage="$(extract_field "$final_line" 's/^t=[0-9]\+ .* stage=\([0-9]\+\) .*/\1/p')"
  final_lineages="$(extract_field "$final_line" 's/^t=[0-9]\+ .* lineages=\(\[[^]]*\]\) .*/\1/p')"
  final_harv="$(extract_field "$final_line" 's/^t=[0-9]\+ .* harv=\([0-9]\+\) .*/\1/p')"
  final_ph="$(extract_field "$final_line" 's/^t=[0-9]\+ .* ph=\([0-9]\+\) .*/\1/p')"
  final_reseeds="$(extract_field "$final_line" 's/^t=[0-9]\+ .* reseeds=\([0-9]\+\) .*/\1/p')"
  final_i4="$(extract_field "$final_line" 's/^t=[0-9]\+ .* i4=\([0-9]\+\) .*/\1/p')"
  final_s4r="$(extract_field "$final_line" 's/^t=[0-9]\+ .* s4r=\([0-9]\+\) .*/\1/p')"
  final_s4f="$(extract_field "$final_line" 's/^t=[0-9]\+ .* s4f=\([0-9]\+\) .*/\1/p')"
  verdict="$(classify_verdict "$status" "${end_tick:-0}" "${stage4_full_count:-0}" "${stage4_partial_count:-0}" "${final_s4f:-0}")"

  if [ -z "$first_stage4_tick" ]; then
    first_stage4_tick="-"
    last_stage4_tick="-"
  fi

  echo -e "${log}\t${requested_ticks}\t${seed}\t${inject}\t${energy}\t${reseed_policy}\t${status}\t${end_tick}\t${survived_90k}\t${verdict}\t${final_pop}\t${final_stage}\t${final_lineages}\t${final_harv}\t${final_ph}\t${final_reseeds}\t${final_i4}\t${final_s4r}\t${final_s4f}\t${stage4_full_count}\t${stage4_partial_count}\t${first_stage4_tick}\t${last_stage4_tick}"
done
