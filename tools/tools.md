# 工具使用方法

## 模型权重下载

```sh
cd models_download

# https://github.com/Rorschach331/aria2c-aarch64-build.git
# https://gist.github.com/697678ab8e528b85a2a7bddafea1fa4f.git
wget https://hf-mirror.com/hfd/hfd.sh   # msd.sh 基于此脚本改写

# 临时生效（仅当前终端会话）
export PATH="$(pwd)/aarch64/bin:$PATH"
# 安装证书并aria2c 验证，容器内需要操作export SSL_CERT_FILE
yum install -y ca-certificates
update-ca-trust
export SSL_CERT_FILE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
aria2c --check-certificate=true https://www.modelscope.cn

# 从 ModelScope 下载（msd.sh，默认分支 master；受限仓库加 --token 或 export MODELSCOPE_API_TOKEN=xxx）
# 重跑同一命令 = resume：本地大小一致的文件跳过、.aria2 未完成文件断点续传、大小不符的删除重下，
# 全部完成则显示 "Up to date." 立即退出
# -x/-j 上限为 10（nproc>10 的机器上 -x $(nproc) 会报错）
# Flash-Next-w8a8-mtp 与 27B-w8a8-mxfp8 仓库的 tokenizer.json 是坏的，排除以免 resume 时覆盖手工修复版
bash msd.sh Eco-Tech/Qwen3.8-Flash-Next-w8a8-mtp -x $(nproc) --local-dir /models/Qwen3.8-Flash-Next-w8a8-mtp --exclude 'tokenizer.json'

# Qwen3.8-27B
bash msd.sh Qwen/Qwen3.8-27B -x $(nproc) --local-dir /models/Qwen3.8-27B

# Qwen3.8-27B-w8a8
bash msd.sh Eco-Tech/Qwen3.8-27B-w8a8 -x $(nproc) --local-dir /models/Qwen3.8-27B-w8a8

# Qwen3.8-27B-w8a8-mxfp8（仓库 tokenizer.json 是坏的，排除以免覆盖手工修复版）
bash msd.sh Eco-Tech/Qwen3.8-27B-w8a8-mxfp8 -x $(nproc) --local-dir /models/Qwen3.8-27B-w8a8-mxfp8 --exclude 'tokenizer.json'

# Qwen3.8-Flash-Next
bash msd.sh Qwen/Qwen3.8-Flash-Next -x $(nproc) --local-dir /models/Qwen3.8-Flash-Next

# Qwen3.5-35B-A3B-w8a8-mtp
bash msd.sh Eco-Tech/Qwen3.5-35B-A3B-w8a8-mtp -x $(nproc) --local-dir /models/Qwen3.5-35B-A3B-w8a8-mtp

# MiniMax-H3 FL2VA/Ref2VA
bash msd.sh MiniMax/MiniMax-H3 \
  --include 'model_index.json' 'modular_model_index.json' '.gitattributes' 'LICENSE' 'README.md' \
            'assets/*' 'audio_scheduler/*' 'audio_vae/*' 'processor/*' 'scheduler/*' \
            'text_encoder/*' 'tokenizer/*' 'transformer/*' 'vae/*' \
            'FL2VA/video_vae/*' 'FL2VA/model_index.json' 'FL2VA/processor/*' 'FL2VA/tokenizer/*' \
  --exclude 'Ref2VA/*' 'transformer_ref/*' 'FL2VA/text_encoder/*' 'FL2VA/transformer/*' 'FL2VA/audio_vae/*' \
  --local-dir /models/MinimaxH3 -x $(nproc)
```

## 模型调研

```sh
# 创建、激活、退出虚拟环境
python3 -m venv .venv
source .venv/bin/activate
# deactivate 

# 安装依赖
pip install pandas openpyxl requests

# 使用
cd upgrade_models-lists
python models-lists_update.py                     # 从网络下载，输出 models-YYYYMMDD.xlsx
python models-lists_update.py -i local.json       # 使用本地 JSON，输出 models-YYYYMMDD.xlsx
```

## dockers调研

```sh
# Ubuntu/Debian
sudo apt install skopeo 

# 以 openEuler/CentOS/RHEL 为例
sudo dnf install -y skopeo

# vllm-ascend
skopeo list-tags docker://quay.io/ascend/vllm-ascend
skopeo list-tags docker://quay.io/atlas-ci/vllm-atlas-temp
skopeo list-tags docker://quay.io/ascend/sglang
skopeo list-tags docker://quay.io/ascend/vllm-omni

# 暂不可用
curl -s "https://harbor.baai.ac.cn/api/v2.0/projects/flagrelease-public/repositories?page_size=100" | jq -r '.[].name'
```

## llm-test

1. 脚本工具

```sh
# 不同模型的测试脚本及测试方法
# 根据其目录下的README.md文档实施

# 通用软件环境检查（检查项在 CHECK_LIST 列表维护，可自由增删；--step 单项执行）
bash env_check.sh
bash env_check.sh --step python,lmcache
bash env_check.sh --import      # Python 包追加真实 import 校验（默认只查 pip 元数据，快）
```

2. 量化指南

```sh
# 方法1--todo...
cd /workspace
git clone https://gitcode.com/Ascend/msmodelslim.git
cd msmodelslim
python3 -m venv --system-site-packages .venv
source .venv/bin/activate
pip install --upgrade pip
# 先查看 requirements.txt，确认是否包含 torch/torch_npu
cat requirements.txt
# 若包含，使用 --no-deps 只安装必要包，跳过 torch 相关依赖
pip install -r requirements.txt --no-deps

# 方法2--todo...
# 独立容器
cd /workspace
git clone https://gitcode.com/Ascend/msmodelslim.git
cd msmodelslim
pip install --upgrade pip
pip install -r requirements.txt

# 执行量化
```

3. 测试指南

```sh
# 创建独立虚拟环境（推荐，避免依赖冲突）
python3 -m venv guidellm-env
source guidellm-env/bin/activate

# 安装 GuideLLM 及推荐依赖
pip install "guidellm[recommended]"

# 验证安装
guidellm --version
```

