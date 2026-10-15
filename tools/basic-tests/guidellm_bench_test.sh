#!/bin/bash
# GuideLLM benchmark sweep: 8 prompt/output-length profiles x concurrency {1,2,4,8,16}
# Uses a local tokenizer path to avoid HuggingFace network requests.
#
# Optimization notes:
#   1. Each configuration runs a fixed number of requests using the max_requests
#      constraint instead of waiting for max_duration.
#   2. max_duration is only a fallback to prevent a hung request from blocking
#      the whole sweep.
#   3. The number of requests per stream is chosen dynamically: longer outputs
#      use fewer requests per stream.
#   4. Metric extraction prefers successful requests. If successful=0, it falls
#      back to incomplete requests to avoid an entire row becoming N/A.
#   5. The CSV includes an incomplete column so data quality is easier to judge.
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

LOCAL_MODEL_PATH="${VLLM_MODEL_PATH:-}"
MODEL_NAME="${VLLM_MODEL:-}"
TARGET_URL="${VLLM_BASE_URL:-http://localhost:8000}"
OUT_DIR="/tmp/guidellm"

# max_duration is only a fallback. Normally the run exits after max_requests is
# satisfied. This value only prevents an abnormal hang.
MAX_DURATION_S=3600
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

# CSV includes an incomplete column to make data quality easier to inspect.
CSV_HEADER="input_len,output_len,concurrency,completed,incomplete,failed,duration_s,qps_req_s,input_throughput_tps,output_throughput_tps,mean_output_tps_per_req,p99_output_tps_per_req,e2e_throughput_tps,mean_ttft_ms,p99_ttft_ms,mean_tpot_ms,p99_tpot_ms,mean_itl_ms,p99_itl_ms,mean_e2el_ms,p99_e2el_ms"

# ------------------------------- Functions --------------------------------

init_csv() {
  echo "$CSV_HEADER" > "$RESULT_CSV"
  mkdir -p "$OUT_DIR"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Auto-detect model from /v1/models if not specified
detect_model() {
  local resp_file
  resp_file=$(mktemp /tmp/detect_model.XXXXXX.json)

  local http_code
  http_code=$(curl -s -o "$resp_file" -w "%{http_code}" \
    --max-time 30 "${TARGET_URL}/v1/models" 2>/dev/null)

  if [ "$http_code" = "200" ] && [ -s "$resp_file" ]; then
    local model_id
    if has_cmd jq; then
      model_id=$(jq -r '.data[0].id // empty' "$resp_file" 2>/dev/null)
    else
      model_id=$(grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' "$resp_file" 2>/dev/null \
        | head -1 | sed 's/.*:[[:space:]]*"//;s/"$//')
    fi
    rm -f "$resp_file"
    echo "$model_id"
    return
  fi

  rm -f "$resp_file"
  echo ""
}

# Append a placeholder row (all metrics N/A) when a run fails.
# The CSV now has 21 columns, so this row contains 3 metadata fields plus 18 N/A fields.
append_failure_row() {
  local in_len=$1 out_len=$2 conc=$3
  echo "$in_len,$out_len,$conc,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A" >> "$RESULT_CSV"
}

# Decide how many requests each concurrent stream should send.
# Longer outputs take more time, so fewer requests per stream are used.
requests_per_stream() {
  local out_len=$1
  if [ "$out_len" -ge 8192 ]; then
    echo 2
  elif [ "$out_len" -ge 4096 ]; then
    echo 3
  else
    echo 5
  fi
}

# Extract metrics from the GuideLLM JSON, compute derived values, append one CSV row.
collect_and_append_metrics() {
  local in_len=$1 out_len=$2 conc=$3 json=$4

  local COMPLETED INCOMPLETE FAILED DURATION TOTAL_IN_TOK TOTAL_OUT_TOK
  local QPS INPUT_TPS OUTPUT_TPS E2E_TPS
  local MEAN_TTFT P99_TTFT MEAN_TPOT P99_TPOT MEAN_ITL P99_ITL
  local MEAN_OUT_TPS_PER_REQ P99_OUT_TPS_PER_REQ MEAN_E2EL P99_E2EL
  local SCOPE

  COMPLETED=$(jq -r '.benchmarks[0].metrics.request_totals.successful // 0' "$json")
  INCOMPLETE=$(jq -r '.benchmarks[0].metrics.request_totals.incomplete // 0' "$json")
  FAILED=$(jq -r '.benchmarks[0].metrics.request_totals.errored    // 0' "$json")
  DURATION=$(jq -r '.benchmarks[0].duration // 0' "$json")

  TOTAL_IN_TOK=$(jq -r '.benchmarks[0].metrics.text.tokens.input.total.total_sum  // 0' "$json")
  TOTAL_OUT_TOK=$(jq -r '.benchmarks[0].metrics.text.tokens.output.total.total_sum // 0' "$json")

  # Prefer successful metrics. If there are no successful requests, fall back to
  # incomplete. Finally fall back to total. This avoids an all-N/A row when the
  # benchmark was stopped before any request completed successfully.
  if [ "$COMPLETED" -gt 0 ]; then
    SCOPE="successful"
  elif [ "$INCOMPLETE" -gt 0 ]; then
    SCOPE="incomplete"
  else
    SCOPE="total"
  fi

  # Throughputs
  if [ "$DURATION" != "0" ] && [ "$DURATION" != "null" ]; then
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
  MEAN_TTFT=$(jq -r ".benchmarks[0].metrics.time_to_first_token_ms.${SCOPE}.mean // \"N/A\"" "$json")
  P99_TTFT=$(jq -r ".benchmarks[0].metrics.time_to_first_token_ms.${SCOPE}.percentiles.p99 // \"N/A\"" "$json")
  MEAN_TPOT=$(jq -r ".benchmarks[0].metrics.time_per_output_token_ms.${SCOPE}.mean // \"N/A\"" "$json")
  P99_TPOT=$(jq -r ".benchmarks[0].metrics.time_per_output_token_ms.${SCOPE}.percentiles.p99 // \"N/A\"" "$json")
  MEAN_ITL=$(jq -r ".benchmarks[0].metrics.inter_token_latency_ms.${SCOPE}.mean // \"N/A\"" "$json")
  P99_ITL=$(jq -r ".benchmarks[0].metrics.inter_token_latency_ms.${SCOPE}.percentiles.p99 // \"N/A\"" "$json")

  # Per-request generation speed derived from TPOT
  MEAN_OUT_TPS_PER_REQ=$(awk -v p="$MEAN_TPOT" \
    'BEGIN { if (p>0) printf "%.2f", 1000/p; else print "N/A" }')
  P99_OUT_TPS_PER_REQ=$(awk -v p="$P99_TPOT" \
    'BEGIN { if (p>0) printf "%.2f", 1000/p; else print "N/A" }')

  # E2E latency: GuideLLM stores seconds -> convert to ms
  MEAN_E2EL=$(jq -r "(.benchmarks[0].metrics.request_latency.${SCOPE}.mean * 1000) // \"N/A\"" "$json")
  P99_E2EL=$(jq -r "(.benchmarks[0].metrics.request_latency.${SCOPE}.percentiles.p99 * 1000) // \"N/A\"" "$json")

  echo "$in_len,$out_len,$conc,$COMPLETED,$INCOMPLETE,$FAILED,$DURATION,$QPS,$INPUT_TPS,$OUTPUT_TPS,$MEAN_OUT_TPS_PER_REQ,$P99_OUT_TPS_PER_REQ,$E2E_TPS,$MEAN_TTFT,$P99_TTFT,$MEAN_TPOT,$P99_TPOT,$MEAN_ITL,$P99_ITL,$MEAN_E2EL,$P99_E2EL" >> "$RESULT_CSV"

  echo "Done: QPS=$QPS req/s | InTPS=$INPUT_TPS tok/s | OutTPS=$OUTPUT_TPS tok/s | MeanReqTPS=$MEAN_OUT_TPS_PER_REQ tok/s | P99ReqTPS=$P99_OUT_TPS_PER_REQ tok/s | E2ETPS=$E2E_TPS tok/s"
  echo "      TTFT=${MEAN_TTFT}/${P99_TTFT} ms, TPOT=${MEAN_TPOT}/${P99_TPOT} ms, E2EL=${MEAN_E2EL}/${P99_E2EL} ms"
  echo "      scope=$SCOPE, completed=$COMPLETED, incomplete=$INCOMPLETE, failed=$FAILED"
}

# Run one GuideLLM invocation and record results.
run_one_bench() {
  local in_len=$1 out_len=$2 conc=$3
  local json_out="${OUT_DIR}/bench_in${in_len}_out${out_len}_c${conc}.json"
  local rps total_requests

  # Decide requests per stream, then multiply by concurrency to get the total.
  rps=$(requests_per_stream "$out_len")
  total_requests=$((conc * rps))

  echo "=== prompt_tokens=$in_len output_tokens=$out_len concurrency=$conc total_requests=$total_requests ==="

  # Remove any old JSON so a failed run cannot accidentally reuse a previous file.
  rm -f "$json_out"

  guidellm run \
    --backend "kind=openai_http,target=${TARGET_URL},model=${MODEL_NAME}" \
    --tokenizer "kind=huggingface_auto,model=${LOCAL_MODEL_PATH}" \
    --profile "kind=concurrent" \
    --override "profile.streams" "$conc" \
    --data "kind=synthetic_text,prompt_tokens=${in_len},output_tokens=${out_len}" \
    --constraint "kind=max_requests,count=${total_requests}" \
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
  # Auto-detect model if not specified
  if [ -z "$MODEL_NAME" ]; then
    MODEL_NAME=$(detect_model)
    if [ -n "$MODEL_NAME" ]; then
      echo "Auto-detected model: $MODEL_NAME"
    else
      echo "ERROR: No model specified and auto-detection failed"
      echo "Set VLLM_MODEL environment variable or use -m option"
      exit 1
    fi
  fi
  LOCAL_MODEL_PATH="${LOCAL_MODEL_PATH:-/models/${MODEL_NAME}}"

  init_csv
  run_all_profiles

  echo
  echo "Results saved to: $RESULT_CSV"
  column -t -s, "$RESULT_CSV" 2>/dev/null || cat "$RESULT_CSV"
}

main "$@"