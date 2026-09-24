#!/bin/bash
# GuideLLM benchmark script for vLLM server
# Uses a local tokenizer path to avoid HuggingFace network requests.
#
# MEAN_OUT_TPS_PER_REQ = 1000 / mean_tpot_ms
# P99_OUT_TPS_PER_REQ = 1000 / p99_tpot_ms
#
# Inspect output after first run:
#   jq 'keys' /tmp/guidellm/bench_1.json
#   jq '.benchmarks[0] | keys' /tmp/guidellm/bench_1.json
# Check CSV:
#   column -t -s, /tmp/benchmark_results.csv

RESULT_CSV="/tmp/benchmark_results.csv"
echo "concurrency,completed,failed,duration_s,qps_req_s,input_throughput_tps,output_throughput_tps,mean_output_tps_per_req,p99_output_tps_per_req,e2e_throughput_tps,mean_ttft_ms,p99_ttft_ms,mean_tpot_ms,p99_tpot_ms,mean_itl_ms,p99_itl_ms,mean_e2el_ms,p99_e2el_ms" > "$RESULT_CSV"

# ---- Offline configuration ----
export HF_ENDPOINT=https://hf-mirror.com
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1

LOCAL_MODEL_PATH="/models/Qwen3.8-27B"
MODEL_NAME="Qwen3.8-27B"
TARGET_URL="http://localhost:8000"

mkdir -p /tmp/guidellm

for CONC in 1 2 4 8 16; do
  JSON_OUT="/tmp/guidellm/bench_${CONC}.json"

  echo "=== Testing concurrency: $CONC ==="

  guidellm run \
    --backend "kind=openai_http,target=${TARGET_URL},model=${MODEL_NAME}" \
    --tokenizer "kind=huggingface_auto,model=${LOCAL_MODEL_PATH}" \
    --profile "kind=concurrent" \
    --override "profile.streams" "$CONC" \
    --data "kind=synthetic_text,prompt_tokens=4096,output_tokens=4096" \
    --constraint "kind=max_duration,seconds=120" \
    --output "kind=json,path=${JSON_OUT}" \
    --disable-console-interactive

  if [ ! -f "$JSON_OUT" ]; then
    echo "ERROR: JSON not generated for concurrency $CONC"
    echo "$CONC,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A" >> "$RESULT_CSV"
    continue
  fi

  # Extract metrics from JSON
  COMPLETED=$(jq -r '.benchmarks[0].metrics.request_totals.successful // "N/A"' "$JSON_OUT")
  FAILED=$(jq -r '.benchmarks[0].metrics.request_totals.errored // "N/A"' "$JSON_OUT")
  DURATION=$(jq -r '.benchmarks[0].duration // "N/A"' "$JSON_OUT")

  # Total input and output tokens
  TOTAL_IN_TOK=$(jq -r '.benchmarks[0].metrics.text.tokens.input.total.total_sum // 0' "$JSON_OUT")
  TOTAL_OUT_TOK=$(jq -r '.benchmarks[0].metrics.text.tokens.output.total.total_sum // 0' "$JSON_OUT")

  # Calculate throughputs
  if [ "$DURATION" != "N/A" ] && [ "$DURATION" != "0" ]; then
    QPS=$(awk -v c="$COMPLETED" -v d="$DURATION" 'BEGIN { if (d>0) printf "%.4f", c/d; else print "N/A" }')
    INPUT_TPS=$(awk -v i="$TOTAL_IN_TOK" -v d="$DURATION" 'BEGIN { if (d>0) printf "%.2f", i/d; else print "N/A" }')
    OUTPUT_TPS=$(awk -v o="$TOTAL_OUT_TOK" -v d="$DURATION" 'BEGIN { if (d>0) printf "%.2f", o/d; else print "N/A" }')
    E2E_TPS=$(awk -v i="$TOTAL_IN_TOK" -v o="$TOTAL_OUT_TOK" -v d="$DURATION" 'BEGIN { if (d>0) printf "%.2f", (i+o)/d; else print "N/A" }')
  else
    QPS="N/A"
    INPUT_TPS="N/A"
    OUTPUT_TPS="N/A"
    E2E_TPS="N/A"
  fi

  # Latency metrics
  MEAN_TTFT=$(jq -r '.benchmarks[0].metrics.time_to_first_token_ms.successful.mean // "N/A"' "$JSON_OUT")
  P99_TTFT=$(jq -r '.benchmarks[0].metrics.time_to_first_token_ms.successful.percentiles.p99 // "N/A"' "$JSON_OUT")
  MEAN_TPOT=$(jq -r '.benchmarks[0].metrics.time_per_output_token_ms.successful.mean // "N/A"' "$JSON_OUT")
  P99_TPOT=$(jq -r '.benchmarks[0].metrics.time_per_output_token_ms.successful.percentiles.p99 // "N/A"' "$JSON_OUT")
  MEAN_ITL=$(jq -r '.benchmarks[0].metrics.inter_token_latency_ms.successful.mean // "N/A"' "$JSON_OUT")
  P99_ITL=$(jq -r '.benchmarks[0].metrics.inter_token_latency_ms.successful.percentiles.p99 // "N/A"' "$JSON_OUT")

  # Per-request generation speed derived from TPOT
  MEAN_OUT_TPS_PER_REQ=$(awk -v p="$MEAN_TPOT" 'BEGIN { if (p>0) printf "%.2f", 1000/p; else print "N/A" }')
  P99_OUT_TPS_PER_REQ=$(awk -v p="$P99_TPOT" 'BEGIN { if (p>0) printf "%.2f", 1000/p; else print "N/A" }')

  # E2E latency: JSON stores seconds, convert to milliseconds
  MEAN_E2EL=$(jq -r '(.benchmarks[0].metrics.request_latency.successful.mean * 1000) // "N/A"' "$JSON_OUT")
  P99_E2EL=$(jq -r '(.benchmarks[0].metrics.request_latency.successful.percentiles.p99 * 1000) // "N/A"' "$JSON_OUT")

  echo "$CONC,$COMPLETED,$FAILED,$DURATION,$QPS,$INPUT_TPS,$OUTPUT_TPS,$MEAN_OUT_TPS_PER_REQ,$P99_OUT_TPS_PER_REQ,$E2E_TPS,$MEAN_TTFT,$P99_TTFT,$MEAN_TPOT,$P99_TPOT,$MEAN_ITL,$P99_ITL,$MEAN_E2EL,$P99_E2EL" >> "$RESULT_CSV"

  echo "Done: QPS=$QPS req/s | InTPS=$INPUT_TPS tok/s | OutTPS=$OUTPUT_TPS tok/s | MeanReqTPS=$MEAN_OUT_TPS_PER_REQ tok/s | P99ReqTPS=$P99_OUT_TPS_PER_REQ tok/s | E2ETPS=$E2E_TPS tok/s"
  echo "      TTFT=${MEAN_TTFT}/${P99_TTFT} ms, TPOT=${MEAN_TPOT}/${P99_TPOT} ms, E2EL=${MEAN_E2EL}/${P99_E2EL} ms"

  sleep 3
done

echo "Results saved to: $RESULT_CSV"
cat "$RESULT_CSV"