#!/bin/bash
#
# Multimodal (image) benchmark sweep:
#   4 image-resolution profiles x concurrency {1,2,4,8,16}
#
# Uses vllm bench serve with --dataset-name random-mm to drive the
# OpenAI-compatible /v1/chat/completions endpoint.
#
# Derived metrics:
#   MEAN_OUT_TPS_PER_REQ = 1000 / mean_tpot_ms
#   P99_OUT_TPS_PER_REQ  = 1000 / p99_tpot_ms
#
# Inspect a single run:
#   jq 'keys' /tmp/bench_720P_c1.json
# Check CSV:
#   column -t -s, /tmp/vllm_image_benchmark_results.csv
#

set -u

# ----------------------------- Configuration ------------------------------
RESULT_CSV="/tmp/vllm_image_benchmark_results.csv"
BASE_URL="http://localhost:8000"
MODEL_PATH="/models/Qwen3.8-27B"
SERVED_NAME="Qwen3.8-27B"
BACKEND="openai-chat"
ENDPOINT="/v1/chat/completions"
MIN_ROUNDS=1
SLEEP_BETWEEN=2

CONCURRENCIES=(1 2 4 8 16)

# Image-resolution profiles: "NAME:HEIGHT:WIDTH"
# num_frames is fixed to 1 (still image), so only H and W vary.
PROFILES=(
  "720P:720:1280"
  "1080P:1080:1920"
  "2K:1440:2560"
  "4K:2160:3840"
)

# Text prompt / output length paired with each image.
# Kept short so the measurement focuses on image handling, not long text.
TEXT_INPUT_LEN=128
TEXT_OUTPUT_LEN=1024

# Number of images attached to each request.
MM_ITEMS_PER_REQUEST=1

# >>> WARMUP: warmup configuration
WARMUP_ENABLE=1                  # 1 = enable warmup, 0 = disable
WARMUP_SERVICE_ENABLE=1          # service-level text warmup (like the curl)
WARMUP_PROFILE_ENABLE=1          # per-resolution image-encoder warmup
WARMUP_INPUT_LEN=32
WARMUP_OUTPUT_LEN=8
WARMUP_PROMPTS=2                 # requests per warmup run
WARMUP_CONCURRENCY=1

CSV_HEADER="resolution,height,width,concurrency,completed,failed,duration_s,qps_req_s,input_throughput_tps,output_throughput_tps,mean_output_tps_per_req,p99_output_tps_per_req,e2e_throughput_tps,mean_ttft_ms,p99_ttft_ms,mean_tpot_ms,p99_tpot_ms,mean_itl_ms,p99_itl_ms,mean_e2el_ms_est,p99_e2el_ms_est"

# ------------------------------- Functions --------------------------------

init_csv() {
  echo "$CSV_HEADER" > "$RESULT_CSV"
}

# Append a placeholder row (all metrics N/A) when a run fails.
append_failure_row() {
  local res=$1 h=$2 w=$3 conc=$4
  echo "$res,$h,$w,$conc,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A" >> "$RESULT_CSV"
}

# >>> WARMUP: Service-level warmup (text only).
# Confirms the model is loaded and the text path is hot.
warmup_service() {
  if [ "$WARMUP_ENABLE" -ne 1 ] || [ "$WARMUP_SERVICE_ENABLE" -ne 1 ]; then
    return 0
  fi

  echo
  echo "--- warmup: service-level (text only) ---"

  local http_code
  http_code=$(curl -s -o /tmp/warmup_service.json -w "%{http_code}" \
    "${BASE_URL}${ENDPOINT}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${SERVED_NAME}\",
      \"messages\": [{\"role\": \"user\", \"content\": \"97乘以23等于多少？\"}],
      \"max_tokens\": 8,
      \"temperature\": 0.0
    }")

  if [ "$http_code" = "200" ]; then
    echo "warmup: service OK (HTTP 200)"
  else
    echo "warmup: service FAILED (HTTP $http_code) - check model name / server"
    cat /tmp/warmup_service.json 2>/dev/null | head -c 500
    echo
  fi
}

# >>> WARMUP: Per-resolution warmup.
# Fires a couple of small random-mm requests at the exact (h, w) bucket so the
# image preprocessor / vision encoder kernels for this resolution are hot
# before we start measuring.
warmup_profile() {
  local res=$1 h=$2 w=$3

  if [ "$WARMUP_ENABLE" -ne 1 ] || [ "$WARMUP_PROFILE_ENABLE" -ne 1 ]; then
    return 0
  fi

  local bucket_config="{( ${h}, ${w}, 1): 1.0}"
  local warm_json="/tmp/warmup_${res}.json"

  echo "--- warmup: profile=$res (${w}x${h}) ---"

  vllm bench serve \
    --backend "$BACKEND" \
    --base-url "$BASE_URL" \
    --model "$MODEL_PATH" \
    --served-model-name "$SERVED_NAME" \
    --endpoint "$ENDPOINT" \
    --dataset-name random-mm \
    --random-mm-bucket-config "$bucket_config" \
    --random-mm-base-items-per-request "$MM_ITEMS_PER_REQUEST" \
    --random-mm-num-mm-items-range-ratio 0 \
    --input-len "$WARMUP_INPUT_LEN" \
    --output-len "$WARMUP_OUTPUT_LEN" \
    --num-prompts "$WARMUP_PROMPTS" \
    --max-concurrency "$WARMUP_CONCURRENCY" \
    --save-result \
    --result-filename "$warm_json" \
    >/dev/null 2>&1

  if [ -f "$warm_json" ]; then
    echo "warmup: profile=$res done"
  else
    echo "warmup: profile=$res produced no JSON (continuing anyway)"
  fi
}

# Extract metrics from the vllm JSON, compute derived values, append one CSV row.
collect_and_append_metrics() {
  local res=$1 h=$2 w=$3 conc=$4 json=$5

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

  echo "$res,$h,$w,$conc,$COMPLETED,$FAILED,$DURATION,$QPS,$INPUT_TPS,$OUTPUT_TPS,$MEAN_OUT_TPS_PER_REQ,$P99_OUT_TPS_PER_REQ,$E2E_TPS,$MEAN_TTFT,$P99_TTFT,$MEAN_TPOT,$P99_TPOT,$MEAN_ITL,$P99_ITL,$MEAN_E2EL,$P99_E2EL" >> "$RESULT_CSV"

  echo "Done: QPS=$QPS req/s | InTPS=$INPUT_TPS tok/s | OutTPS=$OUTPUT_TPS tok/s | MeanReqTPS=$MEAN_OUT_TPS_PER_REQ tok/s | P99ReqTPS=$P99_OUT_TPS_PER_REQ tok/s | E2ETPS=$E2E_TPS tok/s"
  echo "      TTFT=${MEAN_TTFT}/${P99_TTFT} ms, TPOT=${MEAN_TPOT}/${P99_TPOT} ms, E2EL(est)=${MEAN_E2EL}/${P99_E2EL} ms"
}

# Run one vllm bench serve invocation (multimodal image) and record results.
run_one_bench() {
  local res=$1 h=$2 w=$3 conc=$4

  local total_prompts=$((conc * MIN_ROUNDS))
  local json_out="/tmp/bench_${res}_c${conc}.json"

  # Lock the random-mm sampler to a single bucket: one still image at (h, w).
  local bucket_config="{( ${h}, ${w}, 1): 1.0}"

  echo "=== resolution=$res (${w}x${h}) concurrency=$conc (total prompts: $total_prompts) ==="

  vllm bench serve \
    --backend "$BACKEND" \
    --base-url "$BASE_URL" \
    --model "$MODEL_PATH" \
    --served-model-name "$SERVED_NAME" \
    --endpoint "$ENDPOINT" \
    --dataset-name random-mm \
    --random-mm-bucket-config "$bucket_config" \
    --random-mm-base-items-per-request "$MM_ITEMS_PER_REQUEST" \
    --random-mm-num-mm-items-range-ratio 0 \
    --input-len "$TEXT_INPUT_LEN" \
    --output-len "$TEXT_OUTPUT_LEN" \
    --num-prompts "$total_prompts" \
    --max-concurrency "$conc" \
    --save-result \
    --result-filename "$json_out"

  if [ ! -f "$json_out" ]; then
    echo "ERROR: JSON not generated for res=$res conc=$conc"
    append_failure_row "$res" "$h" "$w" "$conc"
    return 1
  fi

  collect_and_append_metrics "$res" "$h" "$w" "$conc" "$json_out"
}

# Sweep all concurrency levels for one image-resolution profile.
run_profile() {
  local res=$1 h=$2 w=$3
  local conc

  echo
  echo "############################################################"
  echo "# Profile: resolution=$res (${w}x${h})"
  echo "############################################################"

  # >>> WARMUP: heat the image path for this exact resolution
  warmup_profile "$res" "$h" "$w"

  for conc in "${CONCURRENCIES[@]}"; do
    run_one_bench "$res" "$h" "$w" "$conc"
    sleep "$SLEEP_BETWEEN"
  done
}

# Sweep all profiles.
run_all_profiles() {
  local profile res h w rest

  for profile in "${PROFILES[@]}"; do
    res="${profile%%:*}"
    rest="${profile#*:}"
    h="${rest%%:*}"
    w="${rest##*:}"
    run_profile "$res" "$h" "$w"
  done
}

# ---------------------------------- Main ----------------------------------

main() {
  init_csv

  # >>> WARMUP: one-time service-level warmup before the sweep
  warmup_service

  run_all_profiles

  echo
  echo "Results saved to: $RESULT_CSV"
  column -t -s, "$RESULT_CSV" 2>/dev/null || cat "$RESULT_CSV"
}

main "$@"