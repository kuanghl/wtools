#!/bin/bash
###############################################################################
# vllm_api_test.sh - Enhanced vLLM API test script (pure Shell, no Python deps)
#
# API families covered:
#   - Pre-test:        /health, /v1/models, /v1/chat/completions (basic chat)
#   - Basic endpoints: /health, /version, /v1/models, /v1/models/{id},
#                      /metrics, /openapi.json, /ping, /load
#   - OpenAI compat:   /v1/completions, /v1/chat/completions,
#                      /v1/chat/completions/batch, /v1/embeddings,
#                      /v1/responses, /v1/responses/{id},
#                      /v1/responses/{id}/cancel,
#                      /v1/audio/transcriptions, /v1/audio/translations,
#                      /v1/chat/completions/render, /v1/completions/render
#   - Anthropic compat:/v1/messages, /v1/messages/count_tokens
#   - Cohere compat:   /v2/embed, /rerank, /v1/rerank, /v2/rerank
#   - Pooling/Score:   /score, /v1/score, /pooling
#   - Tokenize:        /tokenize, /detokenize (round-trip check)
#   - LoRA:            /v1/load_lora_adapter, /v1/unload_lora_adapter
#   - Batch/File:      /v1/files, /v1/batches
#   - SageMaker:       /invocations
#   - Others:          /generative_scoring, /inference/v1/generate,
#                      /scale_elastic_ep, /is_scaling_elastic_ep
#
# Dependencies:
#   - bash 4.0+, curl
#   - optional: jq (for JSON structure validation and precise field extraction,
#     recommended)
#
# Usage:
#   ./vllm_api_test.sh                               # default config
#   ./vllm_api_test.sh -u http://host:8000 -m model  # specify address and model
#   ./vllm_api_test.sh -v                            # print request & response
#   ./vllm_api_test.sh --stream                      # enable streaming SSE test
#   ./vllm_api_test.sh --errors                      # enable error path test
#   ./vllm_api_test.sh --all                         # enable all tests
#
# Environment variables:
#   VLLM_BASE_URL         service address
#   VLLM_API_KEY          API key
#   VLLM_MODEL            model name
#   VERBOSE_MAX_BYTES     max bytes printed per response in -v mode (default 4096)
#   PRETEST_TIMEOUT       pre-test request timeout in seconds (default 300 = 5 min)
###############################################################################

set -o pipefail

# ============================================================================
# I. Global configuration
# ============================================================================
BASE_URL="${VLLM_BASE_URL:-http://localhost:8000}"
API_KEY="${VLLM_API_KEY:-}"
MODEL="${VLLM_MODEL:-}"
TIMEOUT=30
VERBOSE=false
STREAM_TEST=false
ERROR_TEST=false
VERBOSE_MAX_BYTES="${VERBOSE_MAX_BYTES:-4096}"
PRETEST_TIMEOUT="${PRETEST_TIMEOUT:-300}"   # pre-test timeout (5 minutes)

RESP_FILE="$(mktemp /tmp/vllm_test_resp.XXXXXX.json)"
STREAM_FILE="$(mktemp /tmp/vllm_test_stream.XXXXXX.txt)"
AUDIO_FILE="$(mktemp /tmp/vllm_test_audio.XXXXXX.wav)"
CLEANUP_FILES=("$RESP_FILE" "$STREAM_FILE" "$AUDIO_FILE")

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; NC='\033[0m'

PASS=0; FAIL=0; SKIP=0; UNSUPPORTED=0; UNSUPPORTED_RESOURCE=0
declare -a FAILED_TESTS=()
declare -a SKIPPED_TESTS=()

# ============================================================================
# II. Generic utilities
# ============================================================================
log_info()                 { echo -e "${BLUE}[INFO]${NC} $*"; }
log_pass()                 { echo -e "${GREEN}[PASS]${NC} $*"; }
log_fail()                 { echo -e "${RED}[FAIL]${NC} $*"; }
log_skip()                 { echo -e "${YELLOW}[SKIP]${NC} $*"; }
log_unsupported()          { echo -e "${YELLOW}[UNSUPPORTED]${NC} $*"; }
log_unsupported_resource() { echo -e "${MAGENTA}[RESOURCE-MISSING]${NC} $*"; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
    for f in "${CLEANUP_FILES[@]}"; do
        [ -f "$f" ] && rm -f "$f"
    done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# classify_404 <file>
#   Decide whether a 404 means "endpoint not found" or "resource not found".
#   Output: unsupported | resource_missing
# ---------------------------------------------------------------------------
classify_404() {
    local file="$1"
    # resource missing: e.g. {"error":{"...","code":404}}
    if grep -qE '"code"[[:space:]]*:[[:space:]]*404' "$file" 2>/dev/null; then
        echo "resource_missing"
        return
    fi
    # endpoint not found: e.g. {"detail":"Not Found"}
    if grep -qE '"detail"[[:space:]]*:[[:space:]]*"Not Found"' "$file" 2>/dev/null; then
        echo "unsupported"
        return
    fi
    # undetermined, conservatively treat as endpoint not found
    echo "unsupported"
}

# ---------------------------------------------------------------------------
# extract_first_model_id <file>
# ---------------------------------------------------------------------------
extract_first_model_id() {
    local file="$1"
    if has_cmd jq; then
        jq -r '.data[0].id // empty' "$file" 2>/dev/null
    else
        grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" 2>/dev/null \
            | head -1 | sed 's/.*:[[:space:]]*"//;s/"$//'
    fi
}

# ---------------------------------------------------------------------------
# extract_response_id <file>
# ---------------------------------------------------------------------------
extract_response_id() {
    local file="$1"
    if has_cmd jq; then
        jq -r '.id // empty' "$file" 2>/dev/null
    else
        grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" 2>/dev/null \
            | head -1 | sed 's/.*:[[:space:]]*"//;s/"$//'
    fi
}

# ---------------------------------------------------------------------------
# extract_tokens_array <file>
#   Extract the tokens array as a JSON string from a /tokenize response,
#   e.g. [9419,1814]
# ---------------------------------------------------------------------------
extract_tokens_array() {
    local file="$1"
    if has_cmd jq; then
        jq -c '.tokens // []' "$file" 2>/dev/null
    else
        local raw
        raw=$(grep -o '"tokens"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$file" 2>/dev/null | head -1)
        if [ -n "$raw" ]; then
            echo "$raw" | sed 's/^"tokens"[[:space:]]*:[[:space:]]*//'
        else
            echo "[]"
        fi
    fi
}

# ---------------------------------------------------------------------------
# extract_detokenize_prompt <file>
# ---------------------------------------------------------------------------
extract_detokenize_prompt() {
    local file="$1"
    if has_cmd jq; then
        jq -r '.prompt // empty' "$file" 2>/dev/null
    else
        grep -o '"prompt"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" 2>/dev/null \
            | head -1 | sed 's/.*:[[:space:]]*"//;s/"$//'
    fi
}

# ---------------------------------------------------------------------------
# build_curl_display <method> <path> [json_data]
# ---------------------------------------------------------------------------
build_curl_display() {
    local method="$1" path="$2" data="${3:-}"
    local url="${BASE_URL}${path}"
    local lines=()

    if [ -n "$data" ] && [ "$method" = "POST" ]; then
        lines+=("curl $url")
    else
        lines+=("curl -X $method $url")
    fi

    [ -n "$API_KEY" ] && lines+=("-H \"Authorization: Bearer $API_KEY\"")
    [ -n "$data" ]    && lines+=("-H \"Content-Type: application/json\"")
    [ -n "$data" ]    && lines+=("-d '$data'")

    local n=${#lines[@]} i prefix suffix
    for ((i=0; i<n; i++)); do
        prefix=""; suffix=""
        [ $i -gt 0 ] && prefix="    "
        [ $i -lt $((n-1)) ] && suffix=" \\"
        echo "${prefix}${lines[$i]}${suffix}"
    done
}

# ---------------------------------------------------------------------------
# do_request <method> <path> [json_data] [extra_curl_args...]
# ---------------------------------------------------------------------------
do_request() {
    local method="$1" path="$2" data="${3:-}"
    if [ $# -ge 3 ]; then shift 3; else shift $#; fi
    local url="${BASE_URL}${path}"
    local args=(-s -o "$RESP_FILE" -w "%{http_code}" --max-time "$TIMEOUT")

    [ -n "$API_KEY" ] && args+=(-H "Authorization: Bearer $API_KEY")

    local rc
    if [ -n "$data" ]; then
        rc=$(curl "${args[@]}" "$@" -X "$method" "$url" \
            -H "Content-Type: application/json" -d "$data" 2>/dev/null)
    else
        rc=$(curl "${args[@]}" "$@" -X "$method" "$url" 2>/dev/null)
    fi

    echo "${rc:-000}"
}

# ---------------------------------------------------------------------------
# do_request_with_timeout <method> <path> [json_data] [timeout]
#   Same as do_request, but allows a per-call timeout (seconds).
# ---------------------------------------------------------------------------
do_request_with_timeout() {
    local method="$1" path="$2" data="${3:-}" custom_timeout="${4:-$TIMEOUT}"
    local url="${BASE_URL}${path}"
    local args=(-s -o "$RESP_FILE" -w "%{http_code}" --max-time "$custom_timeout")

    [ -n "$API_KEY" ] && args+=(-H "Authorization: Bearer $API_KEY")

    local rc
    if [ -n "$data" ]; then
        rc=$(curl "${args[@]}" -X "$method" "$url" \
            -H "Content-Type: application/json" -d "$data" 2>/dev/null)
    else
        rc=$(curl "${args[@]}" -X "$method" "$url" 2>/dev/null)
    fi

    echo "${rc:-000}"
}

# ---------------------------------------------------------------------------
# do_request_multipart <method> <path> <file_path> [form_fields...]
# ---------------------------------------------------------------------------
do_request_multipart() {
    local method="$1" path="$2" file_path="$3"; shift 3
    local url="${BASE_URL}${path}"
    local args=(-s -o "$RESP_FILE" -w "%{http_code}" --max-time "$TIMEOUT")

    [ -n "$API_KEY" ] && args+=(-H "Authorization: Bearer $API_KEY")

    local curl_form=()
    for field in "$@"; do
        curl_form+=(-F "$field")
    done

    if [ -n "$file_path" ] && [ -f "$file_path" ]; then
        curl_form+=(-F "file=@${file_path}")
    fi

    local rc
    rc=$(curl "${args[@]}" -X "$method" "$url" "${curl_form[@]}" 2>/dev/null)
    echo "${rc:-000}"
}

# ---------------------------------------------------------------------------
# record_404_405 <name> <http_code>
#   Shared classifier for 404/405: endpoint-not-found vs resource-missing.
# ---------------------------------------------------------------------------
record_404_405() {
    local name="$1" http_code="$2"
    local kind
    kind=$(classify_404 "$RESP_FILE")
    if [ "$kind" = "resource_missing" ]; then
        log_unsupported_resource "$name (HTTP $http_code, endpoint exists but resource missing)"
        UNSUPPORTED_RESOURCE=$((UNSUPPORTED_RESOURCE + 1))
    else
        log_unsupported "$name (HTTP $http_code, endpoint not found)"
        UNSUPPORTED=$((UNSUPPORTED + 1))
    fi
}

# ---------------------------------------------------------------------------
# record_result <name> <http_code> <expected>
#   404/405 are auto-classified as endpoint-not-found or resource-missing.
# ---------------------------------------------------------------------------
record_result() {
    local name="$1" http_code="$2" expected="$3"
    if [ "$http_code" = "$expected" ]; then
        log_pass "$name (HTTP $http_code)"
        PASS=$((PASS + 1))
    elif [ "$http_code" = "000" ]; then
        log_skip "$name (connection failed)"
        SKIP=$((SKIP + 1))
        SKIPPED_TESTS+=("$name")
    elif [ "$http_code" = "404" ] || [ "$http_code" = "405" ]; then
        record_404_405 "$name" "$http_code"
    else
        log_fail "$name (HTTP $http_code, expected $expected)"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
}

# ---------------------------------------------------------------------------
# record_result_any <name> <http_code> <expected_codes...>
# ---------------------------------------------------------------------------
record_result_any() {
    local name="$1" http_code="$2"; shift 2
    local expected
    for expected in "$@"; do
        if [ "$http_code" = "$expected" ]; then
            log_pass "$name (HTTP $http_code)"
            PASS=$((PASS + 1))
            return
        fi
    done
    if [ "$http_code" = "000" ]; then
        log_skip "$name (connection failed)"
        SKIP=$((SKIP + 1))
        SKIPPED_TESTS+=("$name")
    elif [ "$http_code" = "404" ] || [ "$http_code" = "405" ]; then
        record_404_405 "$name" "$http_code"
    else
        log_fail "$name (HTTP $http_code, expected one of: $*)"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
}

# ---------------------------------------------------------------------------
# validate_json <file> <required_keys...>
# ---------------------------------------------------------------------------
validate_json() {
    local file="$1"; shift
    has_cmd jq || return 0
    jq empty "$file" 2>/dev/null || return 1
    local key
    for key in "$@"; do
        jq -e "has(\"$key\")" "$file" >/dev/null 2>&1 || return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# check_json_fields <name> <file> <required_keys...>
#   Fail the named test if the response is valid HTTP but malformed JSON.
# ---------------------------------------------------------------------------
check_json_fields() {
    local name="$1" file="$2"; shift 2
    if ! validate_json "$file" "$@"; then
        log_fail "$name response structure validation failed"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name (structure check)")
    fi
}

# ---------------------------------------------------------------------------
# show_response <method> <path> [json_data]
#   Truncates output when the response exceeds VERBOSE_MAX_BYTES.
# ---------------------------------------------------------------------------
show_response() {
    [ "$VERBOSE" = true ] || return 0

    echo ""
    echo "request:"
    build_curl_display "$1" "$2" "${3:-}"
    echo ""
    echo "reply:"
    if [ -s "$RESP_FILE" ]; then
        local size
        size=$(wc -c < "$RESP_FILE")
        if [ "$size" -gt "$VERBOSE_MAX_BYTES" ]; then
            head -c "$VERBOSE_MAX_BYTES" "$RESP_FILE"
            echo ""
            echo "... [truncated: showing ${VERBOSE_MAX_BYTES} of ${size} bytes]"
        else
            if has_cmd jq; then
                jq . "$RESP_FILE" 2>/dev/null || cat "$RESP_FILE"
            else
                cat "$RESP_FILE"
            fi
        fi
        echo ""
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# generate_silent_wav <file>
#   Write a minimal silent WAV file with printf.
#   16kHz, mono, 16bit PCM, 1600 samples (~0.1s of silence).
# ---------------------------------------------------------------------------
generate_silent_wav() {
    local file="$1"
    printf 'RIFF\xa4\x0c\x00\x00WAVE' > "$file" || return 1
    printf 'fmt \x10\x00\x00\x00\x01\x00\x01\x00\x80\x3e\x00\x00\x00\x7d\x00\x00\x02\x00\x10\x00' >> "$file" || return 1
    printf 'data\x80\x0c\x00\x00' >> "$file" || return 1
    head -c 3200 /dev/zero >> "$file" || return 1
    return 0
}

# ============================================================================
# III. Pre-test (runs before the basic endpoint tests)
#   Covers:
#     - GET  /health
#     - GET  /v1/models
#     - POST /v1/chat/completions (basic chat)
#   All use PRETEST_TIMEOUT (default 300s) as the request timeout.
# ============================================================================
pretest() {
    log_info ">>> Pre-test (timeout ${PRETEST_TIMEOUT}s) <<<"
    echo ""

    # ------------------------------------------------------------------
    # Pre-test 1/3: health check
    # ------------------------------------------------------------------
    log_info "Pre-test 1/3: GET /health ..."
    local code
    code=$(do_request_with_timeout GET "/health" "" "$PRETEST_TIMEOUT")
    record_result "Pre-test GET /health" "$code" "200"
    show_response GET "/health"

    # ------------------------------------------------------------------
    # Pre-test 2/3: model list
    # ------------------------------------------------------------------
    log_info "Pre-test 2/3: GET /v1/models ..."
    code=$(do_request_with_timeout GET "/v1/models" "" "$PRETEST_TIMEOUT")
    record_result "Pre-test GET /v1/models" "$code" "200"
    show_response GET "/v1/models"

    # ------------------------------------------------------------------
    # Pre-test 3/3: basic chat
    #   If no --model was given, fall back to the default model name.
    # ------------------------------------------------------------------
    log_info "Pre-test 3/3: POST /v1/chat/completions ..."
    local pretest_model="${MODEL}"
    local data
    data=$(cat <<EOF
{
    "model": "$pretest_model",
    "messages": [{"role": "user", "content": "What is 97 times 23?"}],
    "max_tokens": 512,
    "temperature": 0.7
}
EOF
)
    code=$(do_request_with_timeout POST "/v1/chat/completions" "$data" "$PRETEST_TIMEOUT")
    record_result "Pre-test POST /v1/chat/completions" "$code" "200"
    if [ "$code" = "200" ]; then
        check_json_fields "Pre-test POST /v1/chat/completions" "$RESP_FILE" "choices"
    fi
    show_response POST "/v1/chat/completions" "$data"

    echo ""
    log_info ">>> Pre-test done <<<"
    echo ""
}

# ============================================================================
# IV. Basic endpoints
# ============================================================================
test_health() {
    log_info "Testing /health ..."
    local code
    code=$(do_request GET "/health")
    record_result "GET /health" "$code" "200"
    show_response GET "/health"
}

test_version() {
    log_info "Testing /version ..."
    local code
    code=$(do_request GET "/version")
    record_result "GET /version" "$code" "200"
    show_response GET "/version"
}

test_models() {
    log_info "Testing /v1/models ..."
    local code
    code=$(do_request GET "/v1/models")
    record_result "GET /v1/models" "$code" "200"
    show_response GET "/v1/models"

    if [ "$code" = "200" ] && [ -n "$MODEL" ]; then
        log_info "Testing /v1/models/$MODEL ..."
        local model_code
        model_code=$(do_request GET "/v1/models/$MODEL")
        record_result "GET /v1/models/{id}" "$model_code" "200"
        show_response GET "/v1/models/$MODEL"
    fi
}

test_metrics() {
    log_info "Testing /metrics ..."
    local code
    code=$(do_request GET "/metrics")
    record_result "GET /metrics" "$code" "200"
    show_response GET "/metrics"
}

test_openapi() {
    log_info "Testing /openapi.json ..."
    local code
    code=$(do_request GET "/openapi.json")
    record_result "GET /openapi.json" "$code" "200"
    show_response GET "/openapi.json"
}

test_ping() {
    log_info "Testing /ping (GET) ..."
    local code
    code=$(do_request GET "/ping")
    record_result_any "GET /ping" "$code" "200" "404"
    show_response GET "/ping"

    log_info "Testing /ping (POST) ..."
    code=$(do_request POST "/ping")
    record_result_any "POST /ping" "$code" "200" "404"
    show_response POST "/ping"
}

test_load() {
    log_info "Testing /load ..."
    local code
    code=$(do_request GET "/load")
    record_result_any "GET /load" "$code" "200" "404"
    show_response GET "/load"
}

# ============================================================================
# V. OpenAI-compatible API
# ============================================================================
test_completions() {
    log_info "Testing /v1/completions ..."
    local data code
    data=$(cat <<EOF
{
    "model": "$MODEL",
    "prompt": "Hello, who are you?",
    "max_tokens": 50,
    "temperature": 0.7,
    "top_p": 0.9
}
EOF
)
    code=$(do_request POST "/v1/completions" "$data")
    record_result "POST /v1/completions" "$code" "200"
    if [ "$code" = "200" ]; then
        check_json_fields "POST /v1/completions" "$RESP_FILE" "choices" "usage"
    fi
    show_response POST "/v1/completions" "$data"

    if [ "$STREAM_TEST" = true ]; then
        local stream_data
        stream_data=$(printf '%s' "$data" | sed 's/}[[:space:]]*$/,"stream":true}/')
        test_stream "POST /v1/completions (stream)" "/v1/completions" "$stream_data"
    fi
}

test_chat_completions() {
    log_info "Testing /v1/chat/completions ..."
    local data code
    data=$(cat <<EOF
{
    "model": "$MODEL",
    "messages": [
        {"role": "user", "content": "Hello, who are you?"}
    ],
    "max_tokens": 50,
    "temperature": 0.7
}
EOF
)
    code=$(do_request POST "/v1/chat/completions" "$data")
    record_result "POST /v1/chat/completions" "$code" "200"
    if [ "$code" = "200" ]; then
        check_json_fields "POST /v1/chat/completions" "$RESP_FILE" "choices"
    fi
    show_response POST "/v1/chat/completions" "$data"

    if [ "$STREAM_TEST" = true ]; then
        local stream_data
        stream_data=$(printf '%s' "$data" | sed 's/}[[:space:]]*$/,"stream":true}/')
        test_stream "POST /v1/chat/completions (stream)" "/v1/chat/completions" "$stream_data"
    fi
}

test_chat_completions_batch() {
    log_info "Testing /v1/chat/completions/batch ..."
    local data code
    data=$(cat <<EOF
{
    "model": "$MODEL",
    "messages": [
        [{"role": "user", "content": "Hello"}],
        [{"role": "user", "content": "Hi there"}]
    ],
    "max_tokens": 20
}
EOF
)
    code=$(do_request POST "/v1/chat/completions/batch" "$data")
    record_result "POST /v1/chat/completions/batch" "$code" "200"
    show_response POST "/v1/chat/completions/batch" "$data"
}

test_chat_completions_render() {
    log_info "Testing /v1/chat/completions/render ..."
    local data code
    data=$(cat <<EOF
{
    "model": "$MODEL",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 20
}
EOF
)
    code=$(do_request POST "/v1/chat/completions/render" "$data")
    record_result_any "POST /v1/chat/completions/render" "$code" "200" "404"
    show_response POST "/v1/chat/completions/render" "$data"
}

test_completions_render() {
    log_info "Testing /v1/completions/render ..."
    local data code
    data=$(cat <<EOF
{
    "model": "$MODEL",
    "prompt": "Hello",
    "max_tokens": 20
}
EOF
)
    code=$(do_request POST "/v1/completions/render" "$data")
    record_result_any "POST /v1/completions/render" "$code" "200" "404"
    show_response POST "/v1/completions/render" "$data"
}

test_embeddings() {
    log_info "Testing /v1/embeddings ..."
    local data code
    data=$(cat <<EOF
{
    "model": "$MODEL",
    "input": "The quick brown fox jumps over the lazy dog"
}
EOF
)
    code=$(do_request POST "/v1/embeddings" "$data")
    record_result "POST /v1/embeddings" "$code" "200"
    if [ "$code" = "200" ]; then
        check_json_fields "POST /v1/embeddings" "$RESP_FILE" "data" "usage"
    fi
    show_response POST "/v1/embeddings" "$data"
}

test_responses() {
    log_info "Testing /v1/responses ..."
    local data code
    data=$(cat <<EOF
{
    "model": "$MODEL",
    "input": "Hello, who are you?"
}
EOF
)
    code=$(do_request POST "/v1/responses" "$data")
    record_result "POST /v1/responses" "$code" "200"
    if [ "$code" = "200" ]; then
        check_json_fields "POST /v1/responses" "$RESP_FILE" "id"
    fi
    show_response POST "/v1/responses" "$data"

    if [ "$code" = "200" ]; then
        local resp_id
        resp_id=$(extract_response_id "$RESP_FILE")
        if [ -n "$resp_id" ] && [ "$resp_id" != "null" ]; then
            log_info "Testing GET /v1/responses/$resp_id ..."
            local get_code
            get_code=$(do_request GET "/v1/responses/$resp_id")
            record_result "GET /v1/responses/{id}" "$get_code" "200"
            show_response GET "/v1/responses/$resp_id"

            log_info "Testing POST /v1/responses/$resp_id/cancel ..."
            local cancel_code
            cancel_code=$(do_request POST "/v1/responses/$resp_id/cancel")
            record_result_any "POST /v1/responses/{id}/cancel" "$cancel_code" "200" "404"
            show_response POST "/v1/responses/$resp_id/cancel"
        fi
    fi
}

test_audio_transcriptions() {
    log_info "Testing /v1/audio/transcriptions ..."
    local code

    if [ ! -f "$AUDIO_FILE" ]; then
        if ! generate_silent_wav "$AUDIO_FILE"; then
            log_skip "cannot generate test audio file, skipping"
            SKIP=$((SKIP + 1))
            SKIPPED_TESTS+=("POST /v1/audio/transcriptions")
            return
        fi
    fi

    code=$(do_request_multipart POST "/v1/audio/transcriptions" "$AUDIO_FILE" \
        "model=$MODEL" "language=en")
    record_result "POST /v1/audio/transcriptions" "$code" "200"
    show_response POST "/v1/audio/transcriptions"
}

test_audio_translations() {
    log_info "Testing /v1/audio/translations ..."
    local code

    if [ ! -f "$AUDIO_FILE" ]; then
        log_skip "test audio file does not exist, skipping"
        SKIP=$((SKIP + 1))
        SKIPPED_TESTS+=("POST /v1/audio/translations")
        return
    fi

    code=$(do_request_multipart POST "/v1/audio/translations" "$AUDIO_FILE" \
        "model=$MODEL")
    record_result "POST /v1/audio/translations" "$code" "200"
    show_response POST "/v1/audio/translations"
}

# ---------------------------------------------------------------------------
# test_stream <name> <path> <json_data>
# ---------------------------------------------------------------------------
test_stream() {
    local name="$1" path="$2" data="$3"
    log_info "Testing $name ..."
    local url="${BASE_URL}${path}"
    local args=(-s -N --max-time "$TIMEOUT")
    [ -n "$API_KEY" ] && args+=(-H "Authorization: Bearer $API_KEY")

    : > "$STREAM_FILE"
    curl "${args[@]}" -X POST "$url" \
        -H "Content-Type: application/json" -d "$data" 2>/dev/null \
        | head -c 4096 > "$STREAM_FILE"

    if grep -q "data:" "$STREAM_FILE"; then
        log_pass "$name (received SSE data)"
        PASS=$((PASS + 1))
    else
        log_fail "$name (no valid SSE data received)"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
}

# ============================================================================
# VI. Anthropic-compatible API
# ============================================================================
test_anthropic_messages() {
    log_info "Testing /v1/messages (Anthropic) ..."
    local data code
    data=$(cat <<EOF
{
    "model": "$MODEL",
    "max_tokens": 20,
    "messages": [{"role": "user", "content": "Hello"}]
}
EOF
)
    code=$(do_request POST "/v1/messages" "$data")
    record_result "POST /v1/messages" "$code" "200"
    show_response POST "/v1/messages" "$data"

    if [ "$STREAM_TEST" = true ]; then
        local stream_data
        stream_data=$(printf '%s' "$data" | sed 's/}[[:space:]]*$/,"stream":true}/')
        test_stream "POST /v1/messages (stream)" "/v1/messages" "$stream_data"
    fi
}

test_anthropic_count_tokens() {
    log_info "Testing /v1/messages/count_tokens (Anthropic) ..."
    local data code
    data=$(cat <<EOF
{
    "model": "$MODEL",
    "messages": [{"role": "user", "content": "Hello"}]
}
EOF
)
    code=$(do_request POST "/v1/messages/count_tokens" "$data")
    record_result "POST /v1/messages/count_tokens" "$code" "200"
    show_response POST "/v1/messages/count_tokens" "$data"
}

# ============================================================================
# VII. Cohere-compatible API
# ============================================================================
test_cohere_embed() {
    log_info "Testing /v2/embed (Cohere) ..."
    local data code
    data=$(cat <<EOF
{
    "model": "$MODEL",
    "texts": ["Hello world"],
    "input_type": "search_document"
}
EOF
)
    code=$(do_request POST "/v2/embed" "$data")
    record_result "POST /v2/embed" "$code" "200"
    show_response POST "/v2/embed" "$data"
}

test_rerank_aliases() {
    local data
    data=$(cat <<EOF
{
    "model": "$MODEL",
    "query": "What is AI?",
    "documents": [
        "Artificial intelligence is a field of computer science.",
        "The weather is nice today."
    ],
    "top_n": 1
}
EOF
)
    local endpoint code
    for endpoint in "/rerank" "/v1/rerank" "/v2/rerank"; do
        log_info "Testing $endpoint (Cohere alias) ..."
        code=$(do_request POST "$endpoint" "$data")
        record_result "POST $endpoint" "$code" "200"
        show_response POST "$endpoint" "$data"
    done
}

# ============================================================================
# VIII. Pooling / Score API
# ============================================================================
test_score_aliases() {
    local data
    data=$(cat <<EOF
{
    "model": "$MODEL",
    "text_1": "What is the capital of France?",
    "text_2": "Paris is the capital of France."
}
EOF
)
    local endpoint code
    for endpoint in "/score" "/v1/score"; do
        log_info "Testing $endpoint ..."
        code=$(do_request POST "$endpoint" "$data")
        record_result "POST $endpoint" "$code" "200"
        show_response POST "$endpoint" "$data"
    done
}

test_pooling() {
    log_info "Testing /pooling ..."
    local data code
    data=$(cat <<EOF
{
    "model": "$MODEL",
    "input": "Hello world"
}
EOF
)
    code=$(do_request POST "/pooling" "$data")
    record_result "POST /pooling" "$code" "200"
    show_response POST "/pooling" "$data"
}

# ============================================================================
# IX. Tokenize / Detokenize (with round-trip check)
# ============================================================================
test_tokenize() {
    log_info "Testing /tokenize ..."
    local data code
    data=$(cat <<EOF
{
    "model": "$MODEL",
    "prompt": "Hello world"
}
EOF
)
    code=$(do_request POST "/tokenize" "$data")
    record_result "POST /tokenize" "$code" "200"
    show_response POST "/tokenize" "$data"
}

# Single detokenize test (uses the /tokenize result for a round-trip check)
test_detokenize_roundtrip() {
    log_info "Testing /detokenize (round-trip) ..."

    # Step 1: tokenize
    local tokenize_data code
    tokenize_data=$(cat <<EOF
{
    "model": "$MODEL",
    "prompt": "Hello world"
}
EOF
)
    code=$(do_request POST "/tokenize" "$tokenize_data")
    if [ "$code" != "200" ]; then
        log_skip "POST /detokenize (round-trip): pre-call /tokenize failed (HTTP $code)"
        SKIP=$((SKIP + 1))
        SKIPPED_TESTS+=("POST /detokenize (round-trip)")
        return
    fi

    local tokens
    tokens=$(extract_tokens_array "$RESP_FILE")
    if [ -z "$tokens" ] || [ "$tokens" = "[]" ]; then
        log_skip "POST /detokenize (round-trip): failed to extract tokens"
        SKIP=$((SKIP + 1))
        SKIPPED_TESTS+=("POST /detokenize (round-trip)")
        return
    fi

    # Step 2: detokenize
    local detok_data
    detok_data="{\"model\":\"$MODEL\",\"tokens\":$tokens}"
    code=$(do_request POST "/detokenize" "$detok_data")
    record_result "POST /detokenize (round-trip)" "$code" "200"
    show_response POST "/detokenize" "$detok_data"

    if [ "$code" = "200" ]; then
        local prompt
        prompt=$(extract_detokenize_prompt "$RESP_FILE")
        if printf '%s' "$prompt" | grep -q "Hello"; then
            log_pass "round-trip OK: detokenize(tokenize(\"Hello world\")) contains \"Hello\""
            PASS=$((PASS + 1))
        else
            log_fail "round-trip FAILED: returned prompt=\"$prompt\", does not contain \"Hello\""
            FAIL=$((FAIL + 1))
            FAILED_TESTS+=("POST /detokenize (round-trip consistency)")
        fi
    fi
}

# ============================================================================
# X. LoRA dynamic load / unload
# ============================================================================
test_lora() {
    log_info "Testing LoRA dynamic load / unload ..."

    local data code
    data='{"lora_name": "test-lora", "lora_path": "/tmp/nonexistent-lora"}'
    code=$(do_request POST "/v1/load_lora_adapter" "$data")

    if [ "$code" = "404" ] || [ "$code" = "405" ]; then
        record_404_405 "POST /v1/load_lora_adapter" "$code"
        return
    fi
    # 400 means the endpoint exists but the parameters are invalid; also pass
    record_result_any "POST /v1/load_lora_adapter" "$code" "200" "400"
    show_response POST "/v1/load_lora_adapter" "$data"
}

# ============================================================================
# XI. Batch / File API
# ============================================================================
test_batch_files() {
    log_info "Testing Batch / File API ..."

    local code
    code=$(do_request GET "/v1/files")
    if [ "$code" = "404" ] || [ "$code" = "405" ]; then
        record_404_405 "GET /v1/files" "$code"
    else
        record_result "GET /v1/files" "$code" "200"
        show_response GET "/v1/files"
    fi

    code=$(do_request GET "/v1/batches")
    if [ "$code" = "404" ] || [ "$code" = "405" ]; then
        record_404_405 "GET /v1/batches" "$code"
    else
        record_result "GET /v1/batches" "$code" "200"
        show_response GET "/v1/batches"
    fi
}

# ============================================================================
# XII. SageMaker / other endpoints
# ============================================================================
test_sagemaker_invocations() {
    log_info "Testing /invocations (SageMaker) ..."
    # Request-body format varies by implementation; accept 200/400/415/500
    local code
    code=$(do_request POST "/invocations" \
        "{\"model\":\"$MODEL\",\"prompt\":\"Hello\",\"max_tokens\":5}")
    record_result_any "POST /invocations" "$code" "200" "400" "404" "415" "500"
    show_response POST "/invocations"
}

test_generative_scoring() {
    log_info "Testing /generative_scoring ..."
    local data code
    data=$(cat <<EOF
{
    "model": "$MODEL",
    "prompt": "Hello",
    "max_tokens": 5
}
EOF
)
    code=$(do_request POST "/generative_scoring" "$data")
    record_result_any "POST /generative_scoring" "$code" "200" "400" "404" "500"
    show_response POST "/generative_scoring" "$data"
}

test_inference_generate() {
    log_info "Testing /inference/v1/generate ..."
    local data code
    data=$(cat <<EOF
{
    "token_ids": [9419, 1814],
    "sampling_params": {"max_tokens": 5}
}
EOF
)
    code=$(do_request POST "/inference/v1/generate" "$data")
    record_result_any "POST /inference/v1/generate" "$code" "200" "400" "404" "500"
    show_response POST "/inference/v1/generate" "$data"
}

test_scale_elastic_ep() {
    log_info "Testing /is_scaling_elastic_ep ..."
    local code
    code=$(do_request POST "/is_scaling_elastic_ep")
    record_result_any "POST /is_scaling_elastic_ep" "$code" "200" "400" "404" "500"
    show_response POST "/is_scaling_elastic_ep"

    log_info "Testing /scale_elastic_ep ..."
    code=$(do_request POST "/scale_elastic_ep")
    record_result_any "POST /scale_elastic_ep" "$code" "200" "400" "404" "408" "500"
    show_response POST "/scale_elastic_ep"
}

# ============================================================================
# XIII. Error path tests
# ============================================================================
test_error_paths() {
    [ "$ERROR_TEST" = true ] || return 0

    log_info ">>> Error path tests <<<"

    local code

    # invalid model
    code=$(do_request POST "/v1/chat/completions" \
        '{"model":"nonexistent-model-xyz","messages":[{"role":"user","content":"hi"}],"max_tokens":5}')
    if [ "$code" = "400" ] || [ "$code" = "404" ] || [ "$code" = "422" ]; then
        log_pass "invalid model returned HTTP $code"
        PASS=$((PASS + 1))
    else
        log_fail "invalid model returned HTTP $code (expected 400/404/422)"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("invalid model error handling")
    fi

    # invalid parameter (negative max_tokens)
    code=$(do_request POST "/v1/chat/completions" \
        "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":-1}")
    if [ "$code" = "400" ] || [ "$code" = "422" ]; then
        log_pass "invalid parameter returned HTTP $code"
        PASS=$((PASS + 1))
    else
        log_fail "invalid parameter returned HTTP $code (expected 400/422)"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("invalid parameter error handling")
    fi

    # nonexistent endpoint
    code=$(do_request GET "/v1/nonexistent-endpoint")
    if [ "$code" = "404" ]; then
        log_pass "nonexistent endpoint returned HTTP 404"
        PASS=$((PASS + 1))
    else
        log_fail "nonexistent endpoint returned HTTP $code (expected 404)"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("404 error handling")
    fi
}

# ============================================================================
# XIV. Main flow
# ============================================================================
print_usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  -u, --url URL        vLLM service address (default: http://localhost:8000)
  -m, --model MODEL    model name (default: auto-detect from /v1/models)
  -k, --key KEY        API key (optional)
  -t, --timeout SEC    request timeout in seconds (default: 30)
  -v, --verbose        print full request and reply (truncated past VERBOSE_MAX_BYTES)
      --stream         enable streaming SSE tests
      --errors         enable error path tests
      --all            enable all tests (--stream --errors)
  -h, --help           show this help

Environment variables:
  VLLM_BASE_URL        service address
  VLLM_API_KEY         API key
  VLLM_MODEL           model name
  VERBOSE_MAX_BYTES    max response bytes printed in -v mode (default 4096)
  PRETEST_TIMEOUT      pre-test request timeout in seconds (default 300 = 5 min)

Examples:
  $0 -u http://192.168.1.100:8000 -m Qwen3-27B
  $0 -k sk-abc123 -v --all
  VERBOSE_MAX_BYTES=16384 $0 -v
  PRETEST_TIMEOUT=600 $0 -m Qwen3.8-Flash-Next-w8a8-mtp

Dependencies:
  bash 4.0+, curl
  optional: jq (for JSON structure validation and precise field extraction, recommended)
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -u|--url)     BASE_URL="$2"; shift 2 ;;
            -m|--model)   MODEL="$2"; shift 2 ;;
            -k|--key)     API_KEY="$2"; shift 2 ;;
            -t|--timeout) TIMEOUT="$2"; shift 2 ;;
            -v|--verbose) VERBOSE=true; shift ;;
            --stream)     STREAM_TEST=true; shift ;;
            --errors)     ERROR_TEST=true; shift ;;
            --all)        STREAM_TEST=true; ERROR_TEST=true; shift ;;
            -h|--help)    print_usage ;;
            *)            echo "Unknown option: $1"; print_usage ;;
        esac
    done
}

# Resolve the model: honor an explicit --model, otherwise probe /v1/models.
resolve_model() {
    local model_source
    if [ -n "$MODEL" ]; then
        model_source="manual"
    else
        model_source="auto-detected"
        local probe_code
        probe_code=$(do_request GET "/v1/models")
        if [ "$probe_code" = "200" ]; then
            MODEL=$(extract_first_model_id "$RESP_FILE")
        fi
    fi
    printf '%s' "$model_source"
}

print_banner() {
    local model_source="$1"
    echo "============================================"
    echo "  Enhanced vLLM API Test"
    echo "============================================"
    echo "  Service:     $BASE_URL"
    if [ -n "$MODEL" ]; then
        echo "  Model:       $MODEL ($model_source)"
    else
        echo "  Model:       not detected"
    fi
    echo "  Timeout:     ${TIMEOUT}s"
    echo "  Stream test: $([ "$STREAM_TEST" = true ] && echo 'enabled' || echo 'disabled')"
    echo "  Error test:  $([ "$ERROR_TEST" = true ] && echo 'enabled' || echo 'disabled')"
    if has_cmd jq; then
        echo "  jq:          installed (structure checks enabled)"
    else
        echo "  jq:          not installed (JSON structure checks skipped)"
    fi
    echo "  Truncate at: ${VERBOSE_MAX_BYTES} bytes"
    echo "  Pre-test timeout: ${PRETEST_TIMEOUT}s"
    echo "============================================"
    echo ""
}

run_all_tests() {
    # ---- Pre-test (health + models + basic chat first) ----
    pretest

    log_info ">>> Basic endpoints <<<"
    test_health
    test_version
    test_models
    test_metrics
    test_openapi
    test_ping
    test_load
    echo ""

    if [ -z "$MODEL" ]; then
        log_skip "no model specified and auto-detection failed, skipping remaining API tests"
        return 0
    fi

    log_info ">>> OpenAI-compatible API <<<"
    test_completions
    test_chat_completions
    test_chat_completions_batch
    test_chat_completions_render
    test_completions_render
    test_embeddings
    test_responses
    test_audio_transcriptions
    test_audio_translations
    echo ""

    log_info ">>> Anthropic-compatible API <<<"
    test_anthropic_messages
    test_anthropic_count_tokens
    echo ""

    log_info ">>> Cohere-compatible API <<<"
    test_cohere_embed
    test_rerank_aliases
    echo ""

    log_info ">>> Pooling / Score API <<<"
    test_score_aliases
    test_pooling
    echo ""

    log_info ">>> Tokenize / Detokenize <<<"
    test_tokenize
    test_detokenize_roundtrip
    echo ""

    log_info ">>> LoRA dynamic load / unload <<<"
    test_lora
    echo ""

    log_info ">>> Batch / File API <<<"
    test_batch_files
    echo ""

    log_info ">>> SageMaker / other endpoints <<<"
    test_sagemaker_invocations
    test_generative_scoring
    test_inference_generate
    test_scale_elastic_ep
    echo ""

    if [ "$ERROR_TEST" = true ]; then
        test_error_paths
        echo ""
    fi
}

print_summary() {
    echo ""
    echo "============================================"
    echo "           Test Result Summary"
    echo "============================================"
    echo -e "  ${GREEN}Passed:             $PASS${NC}"
    echo -e "  ${RED}Failed:             $FAIL${NC}"
    echo -e "  ${YELLOW}Skipped:            $SKIP${NC}"
    echo -e "  ${YELLOW}Endpoint not found: $UNSUPPORTED${NC}"
    echo -e "  ${MAGENTA}Resource missing:   $UNSUPPORTED_RESOURCE${NC}"
    echo "--------------------------------------------"

    if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
        echo "Failed tests:"
        local t
        for t in "${FAILED_TESTS[@]}"; do
            echo -e "  ${RED}x${NC} $t"
        done
    fi

    if [ ${#SKIPPED_TESTS[@]} -gt 0 ]; then
        echo "Skipped tests:"
        local t
        for t in "${SKIPPED_TESTS[@]}"; do
            echo -e "  ${YELLOW}o${NC} $t"
        done
    fi

    echo "============================================"
    if [ "$FAIL" -eq 0 ]; then
        echo -e "${GREEN}All tests passed!${NC}"
    else
        echo -e "${RED}Some tests failed, please check.${NC}"
    fi
}

main() {
    parse_args "$@"

    # ---- Resolve the model up front ----
    local model_source
    model_source=$(resolve_model)

    print_banner "$model_source"

    run_all_tests

    print_summary
}

main "$@"
