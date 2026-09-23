#!/bin/bash
###############################################################################
# vllm_api_test.sh - vLLM API 增强测试脚本（纯 Shell，无 Python 依赖）
#
# 覆盖的 API 系列:
#   - 基础端点:        /health, /version, /v1/models, /v1/models/{id},
#                      /metrics, /openapi.json, /ping, /load
#   - OpenAI 兼容:     /v1/completions, /v1/chat/completions,
#                      /v1/chat/completions/batch, /v1/embeddings,
#                      /v1/responses, /v1/responses/{id},
#                      /v1/responses/{id}/cancel,
#                      /v1/audio/transcriptions, /v1/audio/translations,
#                      /v1/chat/completions/render, /v1/completions/render
#   - Anthropic 兼容:  /v1/messages, /v1/messages/count_tokens
#   - Cohere 兼容:     /v2/embed, /rerank, /v1/rerank, /v2/rerank
#   - Pooling/Score:   /score, /v1/score, /pooling
#   - Tokenize:        /tokenize, /detokenize (往返校验)
#   - LoRA:            /v1/load_lora_adapter, /v1/unload_lora_adapter
#   - Batch/File:      /v1/files, /v1/batches
#   - SageMaker:       /invocations
#   - 其他:            /generative_scoring, /inference/v1/generate,
#                      /scale_elastic_ep, /is_scaling_elastic_ep
#
# 依赖:
#   - bash 4.0+、curl
#   - 可选: jq（用于 JSON 结构校验和精确字段提取，建议安装）
#
# 使用:
#   ./vllm_api_test.sh                               # 默认配置
#   ./vllm_api_test.sh -u http://host:8000 -m model  # 指定地址和模型
#   ./vllm_api_test.sh -v                            # 打印请求与响应
#   ./vllm_api_test.sh --stream                      # 启用流式 SSE 测试
#   ./vllm_api_test.sh --errors                      # 启用错误路径测试
#   ./vllm_api_test.sh --all                         # 启用全部测试
#
# 环境变量:
#   VLLM_BASE_URL         服务地址
#   VLLM_API_KEY          API Key
#   VLLM_MODEL            模型名称
#   VERBOSE_MAX_BYTES     -v 模式下单次响应最大打印字节数（默认 4096）
###############################################################################

set -o pipefail

# ============================================================================
# 一、全局配置
# ============================================================================
BASE_URL="${VLLM_BASE_URL:-http://localhost:8000}"
API_KEY="${VLLM_API_KEY:-}"
MODEL="${VLLM_MODEL:-}"
TIMEOUT=30
VERBOSE=false
STREAM_TEST=false
ERROR_TEST=false
VERBOSE_MAX_BYTES="${VERBOSE_MAX_BYTES:-4096}"

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
# 二、通用工具
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
#   判断 404 是端点不存在，还是资源不存在
#   输出: unsupported | resource_missing
# ---------------------------------------------------------------------------
classify_404() {
    local file="$1"
    # 资源不存在：形如 {"error":{"...","code":404}}
    if grep -qE '"code"[[:space:]]*:[[:space:]]*404' "$file" 2>/dev/null; then
        echo "resource_missing"
        return
    fi
    # 端点不存在：形如 {"detail":"Not Found"}
    if grep -qE '"detail"[[:space:]]*:[[:space:]]*"Not Found"' "$file" 2>/dev/null; then
        echo "unsupported"
        return
    fi
    # 无法判断，保守归为端点不存在
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
#   从 /tokenize 响应中提取 tokens 数组的 JSON 字符串，如 [9419,1814]
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
# record_result <name> <http_code> <expected>
#   404/405 会根据响应体自动分类为「端点不存在」或「资源不存在」
# ---------------------------------------------------------------------------
record_result() {
    local name="$1" http_code="$2" expected="$3"
    if [ "$http_code" = "$expected" ]; then
        log_pass "$name (HTTP $http_code)"
        PASS=$((PASS + 1))
    elif [ "$http_code" = "000" ]; then
        log_skip "$name (连接失败)"
        SKIP=$((SKIP + 1))
        SKIPPED_TESTS+=("$name")
    elif [ "$http_code" = "404" ] || [ "$http_code" = "405" ]; then
        local kind
        kind=$(classify_404 "$RESP_FILE")
        if [ "$kind" = "resource_missing" ]; then
            log_unsupported_resource "$name (HTTP $http_code, 端点存在但资源不存在)"
            UNSUPPORTED_RESOURCE=$((UNSUPPORTED_RESOURCE + 1))
        else
            log_unsupported "$name (HTTP $http_code, 端点不存在)"
            UNSUPPORTED=$((UNSUPPORTED + 1))
        fi
    else
        log_fail "$name (HTTP $http_code, 期望 $expected)"
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
        log_skip "$name (连接失败)"
        SKIP=$((SKIP + 1))
        SKIPPED_TESTS+=("$name")
    elif [ "$http_code" = "404" ] || [ "$http_code" = "405" ]; then
        local kind
        kind=$(classify_404 "$RESP_FILE")
        if [ "$kind" = "resource_missing" ]; then
            log_unsupported_resource "$name (HTTP $http_code, 端点存在但资源不存在)"
            UNSUPPORTED_RESOURCE=$((UNSUPPORTED_RESOURCE + 1))
        else
            log_unsupported "$name (HTTP $http_code, 端点不存在)"
            UNSUPPORTED=$((UNSUPPORTED + 1))
        fi
    else
        log_fail "$name (HTTP $http_code, 期望 $* 之一)"
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
# show_response <method> <path> [json_data]
#   响应超过 VERBOSE_MAX_BYTES 时截断打印
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
#   用 printf 直接生成一个最小静音 WAV 文件
#   16kHz, 单声道, 16bit PCM, 1600 个采样（约 0.1 秒静音）
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
# 三、基础端点
# ============================================================================
test_health() {
    log_info "测试 /health ..."
    local code
    code=$(do_request GET "/health")
    record_result "GET /health" "$code" "200"
    show_response GET "/health"
}

test_version() {
    log_info "测试 /version ..."
    local code
    code=$(do_request GET "/version")
    record_result "GET /version" "$code" "200"
    show_response GET "/version"
}

test_models() {
    log_info "测试 /v1/models ..."
    local code
    code=$(do_request GET "/v1/models")
    record_result "GET /v1/models" "$code" "200"
    show_response GET "/v1/models"

    if [ "$code" = "200" ] && [ -n "$MODEL" ]; then
        log_info "测试 /v1/models/$MODEL ..."
        local model_code
        model_code=$(do_request GET "/v1/models/$MODEL")
        record_result "GET /v1/models/{id}" "$model_code" "200"
        show_response GET "/v1/models/$MODEL"
    fi
}

test_metrics() {
    log_info "测试 /metrics ..."
    local code
    code=$(do_request GET "/metrics")
    record_result "GET /metrics" "$code" "200"
    show_response GET "/metrics"
}

test_openapi() {
    log_info "测试 /openapi.json ..."
    local code
    code=$(do_request GET "/openapi.json")
    record_result "GET /openapi.json" "$code" "200"
    show_response GET "/openapi.json"
}

test_ping() {
    log_info "测试 /ping (GET) ..."
    local code
    code=$(do_request GET "/ping")
    record_result_any "GET /ping" "$code" "200" "404"
    show_response GET "/ping"

    log_info "测试 /ping (POST) ..."
    code=$(do_request POST "/ping")
    record_result_any "POST /ping" "$code" "200" "404"
    show_response POST "/ping"
}

test_load() {
    log_info "测试 /load ..."
    local code
    code=$(do_request GET "/load")
    record_result_any "GET /load" "$code" "200" "404"
    show_response GET "/load"
}

# ============================================================================
# 四、OpenAI 兼容 API
# ============================================================================
test_completions() {
    log_info "测试 /v1/completions ..."
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
    if [ "$code" = "200" ] && ! validate_json "$RESP_FILE" "choices" "usage"; then
        log_fail "POST /v1/completions 响应结构校验失败"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("POST /v1/completions (结构校验)")
    fi
    show_response POST "/v1/completions" "$data"

    if [ "$STREAM_TEST" = true ]; then
        local stream_data
        stream_data=$(printf '%s' "$data" | sed 's/}[[:space:]]*$/,"stream":true}/')
        test_stream "POST /v1/completions (stream)" "/v1/completions" "$stream_data"
    fi
}

test_chat_completions() {
    log_info "测试 /v1/chat/completions ..."
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
    if [ "$code" = "200" ] && ! validate_json "$RESP_FILE" "choices"; then
        log_fail "POST /v1/chat/completions 响应结构校验失败"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("POST /v1/chat/completions (结构校验)")
    fi
    show_response POST "/v1/chat/completions" "$data"

    if [ "$STREAM_TEST" = true ]; then
        local stream_data
        stream_data=$(printf '%s' "$data" | sed 's/}[[:space:]]*$/,"stream":true}/')
        test_stream "POST /v1/chat/completions (stream)" "/v1/chat/completions" "$stream_data"
    fi
}

test_chat_completions_batch() {
    log_info "测试 /v1/chat/completions/batch ..."
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
    log_info "测试 /v1/chat/completions/render ..."
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
    log_info "测试 /v1/completions/render ..."
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
    log_info "测试 /v1/embeddings ..."
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
    if [ "$code" = "200" ] && ! validate_json "$RESP_FILE" "data" "usage"; then
        log_fail "POST /v1/embeddings 响应结构校验失败"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("POST /v1/embeddings (结构校验)")
    fi
    show_response POST "/v1/embeddings" "$data"
}

test_responses() {
    log_info "测试 /v1/responses ..."
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
    if [ "$code" = "200" ] && ! validate_json "$RESP_FILE" "id"; then
        log_fail "POST /v1/responses 响应结构校验失败"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("POST /v1/responses (结构校验)")
    fi
    show_response POST "/v1/responses" "$data"

    if [ "$code" = "200" ]; then
        local resp_id
        resp_id=$(extract_response_id "$RESP_FILE")
        if [ -n "$resp_id" ] && [ "$resp_id" != "null" ]; then
            log_info "测试 GET /v1/responses/$resp_id ..."
            local get_code
            get_code=$(do_request GET "/v1/responses/$resp_id")
            record_result "GET /v1/responses/{id}" "$get_code" "200"
            show_response GET "/v1/responses/$resp_id"

            log_info "测试 POST /v1/responses/$resp_id/cancel ..."
            local cancel_code
            cancel_code=$(do_request POST "/v1/responses/$resp_id/cancel")
            record_result_any "POST /v1/responses/{id}/cancel" "$cancel_code" "200" "404"
            show_response POST "/v1/responses/$resp_id/cancel"
        fi
    fi
}

test_audio_transcriptions() {
    log_info "测试 /v1/audio/transcriptions ..."
    local code

    if [ ! -f "$AUDIO_FILE" ]; then
        if ! generate_silent_wav "$AUDIO_FILE"; then
            log_skip "无法生成测试音频文件，跳过"
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
    log_info "测试 /v1/audio/translations ..."
    local code

    if [ ! -f "$AUDIO_FILE" ]; then
        log_skip "测试音频文件不存在，跳过"
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
    log_info "测试 $name ..."
    local url="${BASE_URL}${path}"
    local args=(-s -N --max-time "$TIMEOUT")
    [ -n "$API_KEY" ] && args+=(-H "Authorization: Bearer $API_KEY")

    : > "$STREAM_FILE"
    curl "${args[@]}" -X POST "$url" \
        -H "Content-Type: application/json" -d "$data" 2>/dev/null \
        | head -c 4096 > "$STREAM_FILE"

    if grep -q "data:" "$STREAM_FILE"; then
        log_pass "$name (收到 SSE 数据)"
        PASS=$((PASS + 1))
    else
        log_fail "$name (未收到有效 SSE 数据)"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
}

# ============================================================================
# 五、Anthropic 兼容 API
# ============================================================================
test_anthropic_messages() {
    log_info "测试 /v1/messages (Anthropic) ..."
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
    log_info "测试 /v1/messages/count_tokens (Anthropic) ..."
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
# 六、Cohere 兼容 API
# ============================================================================
test_cohere_embed() {
    log_info "测试 /v2/embed (Cohere) ..."
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
        log_info "测试 $endpoint (Cohere alias) ..."
        code=$(do_request POST "$endpoint" "$data")
        record_result "POST $endpoint" "$code" "200"
        show_response POST "$endpoint" "$data"
    done
}

# ============================================================================
# 七、Pooling / Score API
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
        log_info "测试 $endpoint ..."
        code=$(do_request POST "$endpoint" "$data")
        record_result "POST $endpoint" "$code" "200"
        show_response POST "$endpoint" "$data"
    done
}

test_pooling() {
    log_info "测试 /pooling ..."
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
# 八、Tokenize / Detokenize（含往返校验）
# ============================================================================
test_tokenize() {
    log_info "测试 /tokenize ..."
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

# 单次 detokenize 测试（使用 /tokenize 的结果做往返校验）
test_detokenize_roundtrip() {
    log_info "测试 /detokenize（往返校验）..."

    # 第一步：tokenize
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
        log_skip "POST /detokenize（往返）：前置 /tokenize 失败 (HTTP $code)"
        SKIP=$((SKIP + 1))
        SKIPPED_TESTS+=("POST /detokenize (往返)")
        return
    fi

    local tokens
    tokens=$(extract_tokens_array "$RESP_FILE")
    if [ -z "$tokens" ] || [ "$tokens" = "[]" ]; then
        log_skip "POST /detokenize（往返）：未能提取 tokens"
        SKIP=$((SKIP + 1))
        SKIPPED_TESTS+=("POST /detokenize (往返)")
        return
    fi

    # 第二步：detokenize
    local detok_data
    detok_data="{\"model\":\"$MODEL\",\"tokens\":$tokens}"
    code=$(do_request POST "/detokenize" "$detok_data")
    record_result "POST /detokenize (往返)" "$code" "200"
    show_response POST "/detokenize" "$detok_data"

    if [ "$code" = "200" ]; then
        local prompt
        prompt=$(extract_detokenize_prompt "$RESP_FILE")
        if printf '%s' "$prompt" | grep -q "Hello"; then
            log_pass "往返校验通过：detokenize(tokenize(\"Hello world\")) 含 \"Hello\""
            PASS=$((PASS + 1))
        else
            log_fail "往返校验失败：返回 prompt=\"$prompt\"，不含 \"Hello\""
            FAIL=$((FAIL + 1))
            FAILED_TESTS+=("POST /detokenize (往返一致性)")
        fi
    fi
}

# ============================================================================
# 九、LoRA 动态加载/卸载
# ============================================================================
test_lora() {
    log_info "测试 LoRA 动态加载/卸载 ..."

    local data code
    data='{"lora_name": "test-lora", "lora_path": "/tmp/nonexistent-lora"}'
    code=$(do_request POST "/v1/load_lora_adapter" "$data")

    if [ "$code" = "404" ] || [ "$code" = "405" ]; then
        local kind
        kind=$(classify_404 "$RESP_FILE")
        if [ "$kind" = "resource_missing" ]; then
            log_unsupported_resource "POST /v1/load_lora_adapter (HTTP $code, 端点存在但资源不存在)"
            UNSUPPORTED_RESOURCE=$((UNSUPPORTED_RESOURCE + 1))
        else
            log_unsupported "POST /v1/load_lora_adapter (HTTP $code, 端点不存在)"
            UNSUPPORTED=$((UNSUPPORTED + 1))
        fi
        return
    fi
    # 400 表示端点存在但参数无效，也算通过
    record_result_any "POST /v1/load_lora_adapter" "$code" "200" "400"
    show_response POST "/v1/load_lora_adapter" "$data"
}

# ============================================================================
# 十、Batch / File API
# ============================================================================
test_batch_files() {
    log_info "测试 Batch / File API ..."

    local code kind
    code=$(do_request GET "/v1/files")
    if [ "$code" = "404" ] || [ "$code" = "405" ]; then
        kind=$(classify_404 "$RESP_FILE")
        if [ "$kind" = "resource_missing" ]; then
            log_unsupported_resource "GET /v1/files (HTTP $code, 端点存在但资源不存在)"
            UNSUPPORTED_RESOURCE=$((UNSUPPORTED_RESOURCE + 1))
        else
            log_unsupported "GET /v1/files (HTTP $code, 端点不存在)"
            UNSUPPORTED=$((UNSUPPORTED + 1))
        fi
    else
        record_result "GET /v1/files" "$code" "200"
        show_response GET "/v1/files"
    fi

    code=$(do_request GET "/v1/batches")
    if [ "$code" = "404" ] || [ "$code" = "405" ]; then
        kind=$(classify_404 "$RESP_FILE")
        if [ "$kind" = "resource_missing" ]; then
            log_unsupported_resource "GET /v1/batches (HTTP $code, 端点存在但资源不存在)"
            UNSUPPORTED_RESOURCE=$((UNSUPPORTED_RESOURCE + 1))
        else
            log_unsupported "GET /v1/batches (HTTP $code, 端点不存在)"
            UNSUPPORTED=$((UNSUPPORTED + 1))
        fi
    else
        record_result "GET /v1/batches" "$code" "200"
        show_response GET "/v1/batches"
    fi
}

# ============================================================================
# 十一、SageMaker / 其他端点
# ============================================================================
test_sagemaker_invocations() {
    log_info "测试 /invocations (SageMaker) ..."
    # 该端点对请求体格式要求依实现而异，接受 200/400/415/500
    local code
    code=$(do_request POST "/invocations" \
        "{\"model\":\"$MODEL\",\"prompt\":\"Hello\",\"max_tokens\":5}")
    record_result_any "POST /invocations" "$code" "200" "400" "404" "415" "500"
    show_response POST "/invocations"
}

test_generative_scoring() {
    log_info "测试 /generative_scoring ..."
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
    log_info "测试 /inference/v1/generate ..."
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
    log_info "测试 /is_scaling_elastic_ep ..."
    local code
    code=$(do_request POST "/is_scaling_elastic_ep")
    record_result_any "POST /is_scaling_elastic_ep" "$code" "200" "400" "404" "500"
    show_response POST "/is_scaling_elastic_ep"

    log_info "测试 /scale_elastic_ep ..."
    code=$(do_request POST "/scale_elastic_ep")
    record_result_any "POST /scale_elastic_ep" "$code" "200" "400" "404" "408" "500"
    show_response POST "/scale_elastic_ep"
}

# ============================================================================
# 十二、错误路径测试
# ============================================================================
test_error_paths() {
    [ "$ERROR_TEST" = true ] || return 0

    log_info ">>> 错误路径测试 <<<"

    local code

    # 无效模型
    code=$(do_request POST "/v1/chat/completions" \
        '{"model":"nonexistent-model-xyz","messages":[{"role":"user","content":"hi"}],"max_tokens":5}')
    if [ "$code" = "400" ] || [ "$code" = "404" ] || [ "$code" = "422" ]; then
        log_pass "无效模型返回 HTTP $code"
        PASS=$((PASS + 1))
    else
        log_fail "无效模型返回 HTTP $code (期望 400/404/422)"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("无效模型错误处理")
    fi

    # 无效参数（max_tokens 为负数）
    code=$(do_request POST "/v1/chat/completions" \
        "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":-1}")
    if [ "$code" = "400" ] || [ "$code" = "422" ]; then
        log_pass "无效参数返回 HTTP $code"
        PASS=$((PASS + 1))
    else
        log_fail "无效参数返回 HTTP $code (期望 400/422)"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("无效参数错误处理")
    fi

    # 不存在的端点
    code=$(do_request GET "/v1/nonexistent-endpoint")
    if [ "$code" = "404" ]; then
        log_pass "不存在的端点返回 HTTP 404"
        PASS=$((PASS + 1))
    else
        log_fail "不存在的端点返回 HTTP $code (期望 404)"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("404 错误处理")
    fi
}

# ============================================================================
# 十三、主流程
# ============================================================================
print_usage() {
    cat <<EOF
用法: $0 [选项]

选项:
  -u, --url URL        vLLM 服务地址 (默认: http://localhost:8000)
  -m, --model MODEL    模型名称 (默认: 自动从 /v1/models 获取)
  -k, --key KEY        API Key (可选)
  -t, --timeout SEC    请求超时秒数 (默认: 30)
  -v, --verbose        打印完整 request 和 reply（超过 VERBOSE_MAX_BYTES 截断）
      --stream         启用流式 SSE 测试
      --errors         启用错误路径测试
      --all            启用全部测试 (--stream --errors)
  -h, --help           显示帮助

环境变量:
  VLLM_BASE_URL        服务地址
  VLLM_API_KEY         API Key
  VLLM_MODEL           模型名称
  VERBOSE_MAX_BYTES    -v 模式下响应最大打印字节数（默认 4096）

示例:
  $0 -u http://192.168.1.100:8000 -m Qwen3-27B
  $0 -k sk-abc123 -v --all
  VERBOSE_MAX_BYTES=16384 $0 -v

依赖:
  bash 4.0+、curl
  可选: jq（用于 JSON 结构校验和精确字段提取，建议安装）
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
            *) echo "未知选项: $1"; print_usage ;;
        esac
    done
}

print_summary() {
    echo ""
    echo "============================================"
    echo "           测试结果汇总"
    echo "============================================"
    echo -e "  ${GREEN}通过:             $PASS${NC}"
    echo -e "  ${RED}失败:             $FAIL${NC}"
    echo -e "  ${YELLOW}跳过:             $SKIP${NC}"
    echo -e "  ${YELLOW}端点不存在:       $UNSUPPORTED${NC}"
    echo -e "  ${MAGENTA}资源不存在:       $UNSUPPORTED_RESOURCE${NC}"
    echo "--------------------------------------------"

    if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
        echo "失败的测试:"
        local t
        for t in "${FAILED_TESTS[@]}"; do
            echo -e "  ${RED}✗${NC} $t"
        done
    fi

    if [ ${#SKIPPED_TESTS[@]} -gt 0 ]; then
        echo "跳过的测试:"
        local t
        for t in "${SKIPPED_TESTS[@]}"; do
            echo -e "  ${YELLOW}⊘${NC} $t"
        done
    fi

    echo "============================================"
    if [ "$FAIL" -eq 0 ]; then
        echo -e "${GREEN}全部测试通过！${NC}"
    else
        echo -e "${RED}存在失败项，请检查。${NC}"
    fi
}

main() {
    parse_args "$@"

    # ---- 提前探测模型 ----
    local model_source
    if [ -n "$MODEL" ]; then
        model_source="手动指定"
    else
        model_source="自动检测"
        local probe_code
        probe_code=$(do_request GET "/v1/models")
        if [ "$probe_code" = "200" ]; then
            MODEL=$(extract_first_model_id "$RESP_FILE")
        fi
    fi

    echo "============================================"
    echo "  vLLM API 增强测试"
    echo "============================================"
    echo "  服务地址: $BASE_URL"
    if [ -n "$MODEL" ]; then
        echo "  模型:     $MODEL ($model_source)"
    else
        echo "  模型:     未检测到"
    fi
    echo "  超时:     ${TIMEOUT}s"
    echo "  流式测试: $([ "$STREAM_TEST" = true ] && echo '启用' || echo '禁用')"
    echo "  错误测试: $([ "$ERROR_TEST" = true ] && echo '启用' || echo '禁用')"
    if has_cmd jq; then
        echo "  jq:       已安装（启用结构校验）"
    else
        echo "  jq:       未安装（跳过 JSON 结构校验）"
    fi
    echo "  截断阈值: ${VERBOSE_MAX_BYTES} bytes"
    echo "============================================"
    echo ""

    log_info ">>> 基础端点 <<<"
    test_health
    test_version
    test_models
    test_metrics
    test_openapi
    test_ping
    test_load
    echo ""

    if [ -z "$MODEL" ]; then
        log_skip "未指定模型且无法自动检测，跳过后续 API 测试"
        print_summary
        exit 0
    fi

    log_info ">>> OpenAI 兼容 API <<<"
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

    log_info ">>> Anthropic 兼容 API <<<"
    test_anthropic_messages
    test_anthropic_count_tokens
    echo ""

    log_info ">>> Cohere 兼容 API <<<"
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

    log_info ">>> LoRA 动态加载/卸载 <<<"
    test_lora
    echo ""

    log_info ">>> Batch / File API <<<"
    test_batch_files
    echo ""

    log_info ">>> SageMaker / 其他端点 <<<"
    test_sagemaker_invocations
    test_generative_scoring
    test_inference_generate
    test_scale_elastic_ep
    echo ""

    if [ "$ERROR_TEST" = true ]; then
        test_error_paths
        echo ""
    fi

    print_summary
}

main "$@"