#!/bin/bash
#
# Benchmark sweep: 6 input/output-length profiles x concurrency {1,2,4,8,16}
#
# Derived metrics:
#   MEAN_OUT_TPS_PER_REQ = 1000 / mean_tpot_ms
#   P99_OUT_TPS_PER_REQ  = 1000 / p99_tpot_ms
#
# Inspect a single run:
#   jq 'keys' /tmp/bench_in128_out1024_c1.json
# Check CSV:
#   column -t -s, /tmp/vllm_benchmark_results.csv
#

set -u

# ----------------------------- Configuration ------------------------------
RESULT_CSV="/tmp/vllm_benchmark_results.csv"
BASE_URL="http://localhost:8000"
MODEL_PATH="/models/Qwen3.8-27B"
SERVED_NAME="Qwen3.8-27B"
ENDPOINT="/v1/completions"
MIN_ROUNDS=1
SLEEP_BETWEEN=2

CONCURRENCIES=(1 2 4 8 16)

# "input_len:output_len" profiles
PROFILES=(
  "128:1024"
  "1024:1024"
  "8192:1024"
  "8192:4096"
  "8192:8192"
  "8192:16384"
  "16384:1024"
  "32768:1024"
)

CSV_HEADER="input_len,output_len,concurrency,completed,failed,duration_s,qps_req_s,input_throughput_tps,output_throughput_tps,mean_output_tps_per_req,p99_output_tps_per_req,e2e_throughput_tps,mean_ttft_ms,p99_ttft_ms,mean_tpot_ms,p99_tpot_ms,mean_itl_ms,p99_itl_ms,mean_e2el_ms_est,p99_e2el_ms_est"

# ------------------------------- Functions --------------------------------

init_csv() {
  echo "$CSV_HEADER" > "$RESULT_CSV"
}

# Append a placeholder row (all metrics N/A) when a run fails.
append_failure_row() {
  local in_len=$1 out_len=$2 conc=$3
  echo "$in_len,$out_len,$conc,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A" >> "$RESULT_CSV"
}

# Extract metrics from the vllm JSON, compute derived values, append one CSV row.
collect_and_append_metrics() {
  local in_len=$1 out_len=$2 conc=$3 json=$4

  local COMPLETED FAILED DURATION QPS MEAN_TTFT P99_TTFT
  local MEAN_TPOT P99_TPOT MEAN_ITL P99_ITL TOTAL_IN_TOK TOTAL_OUT_TOK
  local OUTPUT_TPS

  COMPLETED=$(jq -r '.completed'               "$json")
  FAILED=$(jq -r '.failed'                     "$json")
  DURATION=$(jq -r '.duration'                 "$json")
  QPS=$(jq -r '.request_throughput'            "$json")
  MEAN_TTFT=$(jq -r '.mean_ttft_ms'            "$json")
  P99_TTFT=$(jq -r '.p99_ttft_ms'              "$json")
  MEAN_TPOT=$(jq -r '.mean_tpot_ms'            "$json")
  P99_TPOT=$(jq -r '.p99_tpot_ms'              "$json")
  MEAN_ITL=$(jq -r '.mean_itl_ms'              "$json")
  P99_ITL=$(jq -r '.p99_itl_ms'                "$json")
  TOTAL_IN_TOK=$(jq -r '.total_input_tokens'   "$json")
  TOTAL_OUT_TOK=$(jq -r '.total_output_tokens' "$json")
  OUTPUT_TPS=$(jq -r '.output_throughput'      "$json")

  # Input throughput = total_input_tokens / duration
  local INPUT_TPS
  INPUT_TPS=$(awk -v tot="$TOTAL_IN_TOK" -v d="$DURATION" \
    'BEGIN { if (d>0) printf "%.2f", tot/d; else print "N/A" }')

  # Per-request generation speed derived from TPOT
  local MEAN_OUT_TPS_PER_REQ P99_OUT_TPS_PER_REQ
  MEAN_OUT_TPS_PER_REQ=$(awk -v p="$MEAN_TPOT" \
    'BEGIN { if (p>0) printf "%.2f", 1000/p; else print "N/A" }')
  P99_OUT_TPS_PER_REQ=$(awk -v p="$P99_TPOT" \
    'BEGIN { if (p>0) printf "%.2f", 1000/p; else print "N/A" }')

  # E2E throughput = (input + output tokens) / duration
  local E2E_TPS
  E2E_TPS=$(awk -v i="$TOTAL_IN_TOK" -v o="$TOTAL_OUT_TOK" -v d="$DURATION" \
    'BEGIN { if (d>0) printf "%.2f", (i+o)/d; else print "N/A" }')

  # Estimated mean / P99 E2E latency: TTFT + TPOT * (avg_output_tokens - 1)
  local MEAN_E2EL P99_E2EL
  MEAN_E2EL=$(awk -v t="$MEAN_TTFT" -v p="$MEAN_TPOT" -v tot="$TOTAL_OUT_TOK" -v c="$COMPLETED" \
    'BEGIN { if (c>0) printf "%.2f", t + p * (tot/c - 1); else print "N/A" }')
  P99_E2EL=$(awk -v t="$P99_TTFT" -v p="$P99_TPOT" -v tot="$TOTAL_OUT_TOK" -v c="$COMPLETED" \
    'BEGIN { if (c>0) printf "%.2f", t + p * (tot/c - 1); else print "N/A" }')

  echo "$in_len,$out_len,$conc,$COMPLETED,$FAILED,$DURATION,$QPS,$INPUT_TPS,$OUTPUT_TPS,$MEAN_OUT_TPS_PER_REQ,$P99_OUT_TPS_PER_REQ,$E2E_TPS,$MEAN_TTFT,$P99_TTFT,$MEAN_TPOT,$P99_TPOT,$MEAN_ITL,$P99_ITL,$MEAN_E2EL,$P99_E2EL" >> "$RESULT_CSV"

  echo "Done: QPS=$QPS req/s | InTPS=$INPUT_TPS tok/s | OutTPS=$OUTPUT_TPS tok/s | MeanReqTPS=$MEAN_OUT_TPS_PER_REQ tok/s | P99ReqTPS=$P99_OUT_TPS_PER_REQ tok/s | E2ETPS=$E2E_TPS tok/s"
  echo "      TTFT=${MEAN_TTFT}/${P99_TTFT} ms, TPOT=${MEAN_TPOT}/${P99_TPOT} ms, E2EL(est)=${MEAN_E2EL}/${P99_E2EL} ms"
}

# Run one vllm bench serve invocation and record results.
run_one_bench() {
  local in_len=$1 out_len=$2 conc=$3

  local total_prompts=$((conc * MIN_ROUNDS))
  local json_out="/tmp/bench_in${in_len}_out${out_len}_c${conc}.json"

  echo "=== input_len=$in_len output_len=$out_len concurrency=$conc (total prompts: $total_prompts) ==="

  vllm bench serve \
    --backend vllm \
    --base-url "$BASE_URL" \
    --model "$MODEL_PATH" \
    --served-model-name "$SERVED_NAME" \
    --endpoint "$ENDPOINT" \
    --dataset-name random \
    --input-len "$in_len" \
    --output-len "$out_len" \
    --num-prompts "$total_prompts" \
    --max-concurrency "$conc" \
    --save-result \
    --result-filename "$json_out"

  if [ ! -f "$json_out" ]; then
    echo "ERROR: JSON not generated for in=$in_len out=$out_len conc=$conc"
    append_failure_row "$in_len" "$out_len" "$conc"
    return 1
  fi

  collect_and_append_metrics "$in_len" "$out_len" "$conc" "$json_out"
}

# Sweep all concurrency levels for one (input_len, output_len) profile.
run_profile() {
  local in_len=$1 out_len=$2
  local conc

  echo
  echo "############################################################"
  echo "# Profile: input_len=$in_len  output_len=$out_len"
  echo "############################################################"

  for conc in "${CONCURRENCIES[@]}"; do
    run_one_bench "$in_len" "$out_len" "$conc"
    sleep "$SLEEP_BETWEEN"
  done
}

# Sweep all profiles.
run_all_profiles() {
  local profile in_len out_len

  for profile in "${PROFILES[@]}"; do
    in_len="${profile%%:*}"
    out_len="${profile##*:}"
    run_profile "$in_len" "$out_len"
  done
}

# ---------------------------------- Main ----------------------------------

main() {
  init_csv
  run_all_profiles

  echo
  echo "Results saved to: $RESULT_CSV"
  column -t -s, "$RESULT_CSV" 2>/dev/null || cat "$RESULT_CSV"
}

main "$@"