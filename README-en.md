# wtools

A collection of operational tools for LLM infrastructure on Huawei Ascend NPU with vLLM inference.

[中文](README.md)

---

## Tools Overview

| Dir | Purpose |
|---|---|
| `tools/basic-tests/` | Environment check, host info, vLLM API test & benchmarks |
| `tools/models_download/` | Download model weights from ModelScope / HuggingFace |
| `tools/build-aria2c/` | Cross-platform aria2c builder (Linux/macOS/Windows) |
| `tools/build-wsl/` | WSL rootfs & offline package builder (CentOS/Ubuntu) |
| `tools/html2article-mpwx/` | WeChat article formatter & tech-stack SVG generator |
| `tools/llm_bench_py/` | VLM benchmark image dataset generator |
| `tools/upgrade_models-lists/` | Model catalog JSON → Excel converter |

## Quick Start

### Environment Check

```bash
bash tools/basic-tests/env_check.sh            # full check
bash tools/basic-tests/env_check.sh --step npu  # NPU only
bash tools/basic-tests/host_info_dump.sh        # hardware inventory → CSV
```

### Model Download

```bash
bash tools/models_download/msd.sh <REPO_ID> --tool aria2c   # ModelScope
bash tools/models_download/hfd.sh <REPO_ID> --tool aria2c   # HuggingFace
```

### Benchmarking

```bash
# vLLM text benchmark
VLLM_BASE_URL=http://localhost:8000/v1 VLLM_MODEL=Qwen2-7B \
  bash tools/basic-tests/vllm_bench_test.sh

# GuideLLM VLM benchmark
bash tools/basic-tests/guidellm_image_bench_test.sh
```

### API Test

```bash
bash tools/basic-tests/vllm_api_test.sh -u http://localhost:8000 -m Qwen2-7B --all
```

## Requirements

- **OS**: Linux (Ubuntu/CentOS recommended)
- **Python**: >= 3.8
- **Shell**: bash >= 4.0, curl, jq
- **Optional**: aria2c, vllm, guidellm, docker, pandas, openpyxl

## CI/CD

GitHub Actions workflows:

- **aria2c**: Linux (x86_64/aarch64), macOS (Intel/ARM), Windows — triggered by tag `v*`
- **WSL rootfs**: Ubuntu 20.04 / CentOS 7.9 / CentOS 8.5 — triggered by any tag
- **Offline packages**: `.run` installers for all three distros

See [tools/tools.md](tools/tools.md) for detailed documentation.
