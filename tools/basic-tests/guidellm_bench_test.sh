#!/bin/bash
# GuideLLM benchmark sweep: 6 prompt/output-length profiles x concurrency {1,2,4,8,16}
# Uses a local tokenizer path to avoid HuggingFace network requests.
#
# Derived metrics:
#   MEAN_OUT_TPS_PER_REQ = 1000 / mean_tpot_ms
#   P99_OUT_TPS_PER_REQ  = 1000 / p99_tpot_ms
#
# Inspect a single run:
#   jq 'keys' /tmp/guidellm/bench_in128_out1024_c1.json
#   jq '.benchmarks[0] | keys' /tmp/guidellm/bench_in128_out1024_c1.json
# Check CSV:
#   column -t -s, /tmp/guidellm_benchmark_results.csv
#

set -u

# ----------------------------- Configuration ------------------------------
RESULT_CSV="/tmp/guidellm_benchmark_results.csv"

# ---- Offline configuration ----
export HF_ENDPOINT=https://hf-mirror.com
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1

LOCAL_MODEL_PATH="/models/Qwen3.8-27B"
MODEL_NAME="Qwen3.8-27B"
TARGET_URL="http://localhost:8000"
OUT_DIR="/tmp/guidellm"
MAX_DURATION_S=120
SLEEP_BETWEEN=3

CONCURRENCIES=(1 2 4 8 16)

# "prompt_tokens:output_tokens" profiles  (== input-len : output-len)
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

CSV_HEADER="input_len,output_len,concurrency,completed,failed,duration_s,qps_req_s,input_throughput_tps,output_throughput_tps,mean_output_tps_per_req,p99_output_tps_per_req,e2e_throughput_tps,mean_ttft_ms,p99_ttft_ms,mean_tpot_ms,p99_tpot_ms,mean_itl_ms,p99_itl_ms,mean_e2el_ms,p99_e2el_ms"

# ------------------------------- Functions --------------------------------

init_csv() {
  echo "$CSV_HEADER" > "$RESULT_CSV"
  mkdir -p "$OUT_DIR"
}

# Append a placeholder row (all metrics N/A) when a run fails.
append_failure_row() {
  local in_len=$1 out_len=$2 conc=$3
  echo "$in_len,$out_len,$conc,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A" >> "$RESULT_CSV"
}

# Extract metrics from the GuideLLM JSON, compute derived values, append one CSV row.
collect_and_append_metrics() {
  local in_len=$1 out_len=$2 conc=$3 json=$4

  local COMPLETED FAILED DURATION TOTAL_IN_TOK TOTAL_OUT_TOK
  local QPS INPUT_TPS OUTPUT_TPS E2E_TPS
  local MEAN_TTFT P99_TTFT MEAN_TPOT P99_TPOT MEAN_ITL P99_ITL
  local MEAN_OUT_TPS_PER_REQ P99_OUT_TPS_PER_REQ MEAN_E2EL P99_E2EL

  COMPLETED=$(jq -r '.benchmarks[0].metrics.request_totals.successful // "N/A"' "$json")
  FAILED=$(jq -r '.benchmarks[0].metrics.request_totals.errored    // "N/A"' "$json")
  DURATION=$(jq -r '.benchmarks[0].duration // "N/A"' "$json")

  TOTAL_IN_TOK=$(jq -r '.benchmarks[0].metrics.text.tokens.input.total.total_sum  // 0' "$json")
  TOTAL_OUT_TOK=$(jq -r '.benchmarks[0].metrics.text.tokens.output.total.total_sum // 0' "$json")

  # Throughputs
  if [ "$DURATION" != "N/A" ] && [ "$DURATION" != "0" ] && [ "$DURATION" != "null" ]; then
    QPS=$(awk -v c="$COMPLETED" -v d="$DURATION" \
      'BEGIN { if (d>0) printf "%.4f", c/d; else print "N/A" }')
    INPUT_TPS=$(awk -v i="$TOTAL_IN_TOK" -v d="$DURATION" \
      'BEGIN { if (d>0) printf "%.2f", i/d; else print "N/A" }')
    OUTPUT_TPS=$(awk -v o="$TOTAL_OUT_TOK" -v d="$DURATION" \
      'BEGIN { if (d>0) printf "%.2f", o/d; else print "N/A" }')
    E2E_TPS=$(awk -v i="$TOTAL_IN_TOK" -v o="$TOTAL_OUT_TOK" -v d="$DURATION" \
      'BEGIN { if (d>0) printf "%.2f", (i+o)/d; else print "N/A" }')
  else
    QPS="N/A"; INPUT_TPS="N/A"; OUTPUT_TPS="N/A"; E2E_TPS="N/A"
  fi

  # Latency metrics (GuideLLM already stores ms for these)
  MEAN_TTFT=$(jq -r '.benchmarks[0].metrics.time_to_first_token_ms.successful.mean // "N/A"' "$json")
  P99_TTFT=$(jq -r '.benchmarks[0].metrics.time_to_first_token_ms.successful.percentiles.p99 // "N/A"' "$json")
  MEAN_TPOT=$(jq -r '.benchmarks[0].metrics.time_per_output_token_ms.successful.mean // "N/A"' "$json")
  P99_TPOT=$(jq -r '.benchmarks[0].metrics.time_per_output_token_ms.successful.percentiles.p99 // "N/A"' "$json")
  MEAN_ITL=$(jq -r '.benchmarks[0].metrics.inter_token_latency_ms.successful.mean // "N/A"' "$json")
  P99_ITL=$(jq -r '.benchmarks[0].metrics.inter_token_latency_ms.successful.percentiles.p99 // "N/A"' "$json")

  # Per-request generation speed derived from TPOT
  MEAN_OUT_TPS_PER_REQ=$(awk -v p="$MEAN_TPOT" \
    'BEGIN { if (p>0) printf "%.2f", 1000/p; else print "N/A" }')
  P99_OUT_TPS_PER_REQ=$(awk -v p="$P99_TPOT" \
    'BEGIN { if (p>0) printf "%.2f", 1000/p; else print "N/A" }')

  # E2E latency: GuideLLM stores seconds -> convert to ms
  MEAN_E2EL=$(jq -r '(.benchmarks[0].metrics.request_latency.successful.mean * 1000) // "N/A"' "$json")
  P99_E2EL=$(jq -r '(.benchmarks[0].metrics.request_latency.successful.percentiles.p99 * 1000) // "N/A"' "$json")

  echo "$in_len,$out_len,$conc,$COMPLETED,$FAILED,$DURATION,$QPS,$INPUT_TPS,$OUTPUT_TPS,$MEAN_OUT_TPS_PER_REQ,$P99_OUT_TPS_PER_REQ,$E2E_TPS,$MEAN_TTFT,$P99_TTFT,$MEAN_TPOT,$P99_TPOT,$MEAN_ITL,$P99_ITL,$MEAN_E2EL,$P99_E2EL" >> "$RESULT_CSV"

  echo "Done: QPS=$QPS req/s | InTPS=$INPUT_TPS tok/s | OutTPS=$OUTPUT_TPS tok/s | MeanReqTPS=$MEAN_OUT_TPS_PER_REQ tok/s | P99ReqTPS=$P99_OUT_TPS_PER_REQ tok/s | E2ETPS=$E2E_TPS tok/s"
  echo "      TTFT=${MEAN_TTFT}/${P99_TTFT} ms, TPOT=${MEAN_TPOT}/${P99_TPOT} ms, E2EL=${MEAN_E2EL}/${P99_E2EL} ms"
}

# Run one GuideLLM invocation and record results.
run_one_bench() {
  local in_len=$1 out_len=$2 conc=$3
  local json_out="${OUT_DIR}/bench_in${in_len}_out${out_len}_c${conc}.json"

  echo "=== prompt_tokens=$in_len output_tokens=$out_len concurrency=$conc ==="

  guidellm run \
    --backend "kind=openai_http,target=${TARGET_URL},model=${MODEL_NAME}" \
    --tokenizer "kind=huggingface_auto,model=${LOCAL_MODEL_PATH}" \
    --profile "kind=concurrent" \
    --override "profile.streams" "$conc" \
    --data "kind=synthetic_text,prompt_tokens=${in_len},output_tokens=${out_len}" \
    --constraint "kind=max_duration,seconds=${MAX_DURATION_S}" \
    --output "kind=json,path=${json_out}" \
    --disable-console-interactive

  if [ ! -f "$json_out" ]; then
    echo "ERROR: JSON not generated for in=$in_len out=$out_len conc=$conc"
    append_failure_row "$in_len" "$out_len" "$conc"
    return 1
  fi

  collect_and_append_metrics "$in_len" "$out_len" "$conc" "$json_out"
}

# Sweep all concurrency levels for one (prompt_tokens, output_tokens) profile.
run_profile() {
  local in_len=$1 out_len=$2
  local conc

  echo
  echo "############################################################"
  echo "# Profile: prompt_tokens=$in_len  output_tokens=$out_len"
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