#!/bin/bash
#
# MEAN_OUT_TPS_PER_REQ = 1000 / mean_tpot_ms
# P99_OUT_TPS_PER_REQ = 1000 / p99_tpot_ms
#
# Inspect output after first run:
#   jq 'keys' /tmp/bench_16.json
#   jq '.benchmarks[0] | keys' /tmp/bench_16.json
# Check CSV:
#   column -t -s, /tmp/benchmark_results.csv

RESULT_CSV="/tmp/benchmark_results.csv"
echo "concurrency,completed,failed,duration_s,qps_req_s,input_throughput_tps,output_throughput_tps,mean_output_tps_per_req,p99_output_tps_per_req,e2e_throughput_tps,mean_ttft_ms,p99_ttft_ms,mean_tpot_ms,p99_tpot_ms,mean_itl_ms,p99_itl_ms,mean_e2el_ms_est,p99_e2el_ms_est" > "$RESULT_CSV"

for CONC in 1 2 4 8 16; do
  MIN_ROUNDS=1
  TOTAL_PROMPTS=$((CONC * MIN_ROUNDS))
  JSON_OUT="/tmp/bench_${CONC}.json"

  echo "=== Testing concurrency: $CONC (total prompts: $TOTAL_PROMPTS) ==="

  vllm bench serve \
    --backend vllm \
    --base-url http://localhost:8000 \
    --model /models/Qwen3.8-27B \
    --served-model-name Qwen3.8-27B \
    --endpoint /v1/completions \
    --dataset-name random \
    --input-len 4096 \
    --output-len 4096 \
    --num-prompts $TOTAL_PROMPTS \
    --max-concurrency $CONC \
    --save-result \
    --result-filename "$JSON_OUT"

  if [ ! -f "$JSON_OUT" ]; then
    echo "ERROR: JSON not generated for concurrency $CONC"
    echo "$CONC,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A" >> "$RESULT_CSV"
    continue
  fi

  COMPLETED=$(jq -r '.completed'                  "$JSON_OUT")
  FAILED=$(jq -r '.failed'                        "$JSON_OUT")
  DURATION=$(jq -r '.duration'                    "$JSON_OUT")
  QPS=$(jq -r '.request_throughput'               "$JSON_OUT")
  MEAN_TTFT=$(jq -r '.mean_ttft_ms'               "$JSON_OUT")
  P99_TTFT=$(jq -r '.p99_ttft_ms'                 "$JSON_OUT")
  MEAN_TPOT=$(jq -r '.mean_tpot_ms'               "$JSON_OUT")
  P99_TPOT=$(jq -r '.p99_tpot_ms'                 "$JSON_OUT")
  MEAN_ITL=$(jq -r '.mean_itl_ms'                 "$JSON_OUT")
  P99_ITL=$(jq -r '.p99_itl_ms'                   "$JSON_OUT")
  TOTAL_IN_TOK=$(jq -r '.total_input_tokens'      "$JSON_OUT")
  TOTAL_OUT_TOK=$(jq -r '.total_output_tokens'    "$JSON_OUT")

  # Input throughput = total_input_tokens / duration
  INPUT_TPS=$(awk -v tot="$TOTAL_IN_TOK" -v d="$DURATION" \
    'BEGIN { if (d>0) printf "%.2f", tot/d; else print "N/A" }')

  # Output throughput (global average output token rate)
  OUTPUT_TPS=$(jq -r '.output_throughput'         "$JSON_OUT")

  # Per-request generation speed derived from TPOT
  MEAN_OUT_TPS_PER_REQ=$(awk -v p="$MEAN_TPOT" \
    'BEGIN { if (p>0) printf "%.2f", 1000/p; else print "N/A" }')
  P99_OUT_TPS_PER_REQ=$(awk -v p="$P99_TPOT" \
    'BEGIN { if (p>0) printf "%.2f", 1000/p; else print "N/A" }')

  # E2E throughput = (input + output tokens) / duration
  E2E_TPS=$(awk -v i="$TOTAL_IN_TOK" -v o="$TOTAL_OUT_TOK" -v d="$DURATION" \
    'BEGIN { if (d>0) printf "%.2f", (i+o)/d; else print "N/A" }')

  # Estimate mean E2E latency: TTFT + TPOT * (avg_output_tokens - 1)
  MEAN_E2EL=$(awk -v t="$MEAN_TTFT" -v p="$MEAN_TPOT" -v tot="$TOTAL_OUT_TOK" -v c="$COMPLETED" \
    'BEGIN { if (c>0) printf "%.2f", t + p * (tot/c - 1); else print "N/A" }')

  # Estimate P99 E2E latency using P99 TTFT and P99 TPOT
  P99_E2EL=$(awk -v t="$P99_TTFT" -v p="$P99_TPOT" -v tot="$TOTAL_OUT_TOK" -v c="$COMPLETED" \
    'BEGIN { if (c>0) printf "%.2f", t + p * (tot/c - 1); else print "N/A" }')

  echo "$CONC,$COMPLETED,$FAILED,$DURATION,$QPS,$INPUT_TPS,$OUTPUT_TPS,$MEAN_OUT_TPS_PER_REQ,$P99_OUT_TPS_PER_REQ,$E2E_TPS,$MEAN_TTFT,$P99_TTFT,$MEAN_TPOT,$P99_TPOT,$MEAN_ITL,$P99_ITL,$MEAN_E2EL,$P99_E2EL" >> "$RESULT_CSV"

  echo "Done: QPS=$QPS req/s | InTPS=$INPUT_TPS tok/s | OutTPS=$OUTPUT_TPS tok/s | MeanReqTPS=$MEAN_OUT_TPS_PER_REQ tok/s | P99ReqTPS=$P99_OUT_TPS_PER_REQ tok/s | E2ETPS=$E2E_TPS tok/s"
  echo "      TTFT=${MEAN_TTFT}/${P99_TTFT} ms, TPOT=${MEAN_TPOT}/${P99_TPOT} ms, E2EL(est)=${MEAN_E2EL}/${P99_E2EL} ms"

  sleep 2
done

echo "Results saved to: $RESULT_CSV"
cat "$RESULT_CSV"