# wtools

LLM 基础设施运维工具集，面向华为昇腾 NPU + vLLM 推理场景。

[English](README-en.md)

---

## 工具一览

| 目录 | 用途 |
|---|---|
| `tools/basic-tests/` | 环境检查、硬件采集、vLLM API 测试与性能基准 |
| `tools/models_download/` | 从 ModelScope / HuggingFace 下载模型权重 |
| `tools/build-aria2c/` | 跨平台构建 aria2c (Linux/macOS/Windows) |
| `tools/build-wsl/` | 构建 WSL rootfs 与离线依赖包 (CentOS/Ubuntu) |
| `tools/html2article-mpwx/` | 微信公众号排版插件 & 技术栈 SVG 生成 |
| `tools/llm_bench_py/` | VLM 基准测试图片数据集生成 |
| `tools/upgrade_models-lists/` | 模型目录 JSON → Excel 转换 |

## 快速开始

### 环境检查

```bash
bash tools/basic-tests/env_check.sh            # 全量检查
bash tools/basic-tests/env_check.sh --step npu  # 仅 NPU
bash tools/basic-tests/host_info_dump.sh        # 硬件清单 → CSV
```

### 模型下载

```bash
bash tools/models_download/msd.sh <REPO_ID> --tool aria2c   # ModelScope
bash tools/models_download/hfd.sh <REPO_ID> --tool aria2c   # HuggingFace
```

### 基准测试

```bash
# vLLM 文本基准
VLLM_BASE_URL=http://localhost:8000/v1 VLLM_MODEL=Qwen2-7B \
  bash tools/basic-tests/vllm_bench_test.sh

# GuideLLM 多模态基准
bash tools/basic-tests/guidellm_image_bench_test.sh
```

### API 测试

```bash
bash tools/basic-tests/vllm_api_test.sh -u http://localhost:8000 -m Qwen2-7B --all
```

## 系统要求

- **OS**: Linux（推荐 Ubuntu/CentOS）
- **Python**: >= 3.8
- **Shell**: bash >= 4.0, curl, jq
- **可选**: aria2c, vllm, guidellm, docker, pandas, openpyxl

## CI/CD

GitHub Actions 自动构建：

- **aria2c**: Linux (x86_64/aarch64), macOS (Intel/ARM), Windows — tag `v*` 触发
- **WSL rootfs**: Ubuntu 20.04 / CentOS 7.9 / CentOS 8.5 — 任意 tag 触发
- **离线依赖包**: 三种发行版 `.run` 安装包

详细文档见 [tools/tools.md](tools/tools.md)。
