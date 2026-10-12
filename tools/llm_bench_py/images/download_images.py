#!/usr/bin/env python3
"""
python3 -m venv .venv
source .venv/bin/activate
pip3 install huggingface_hub Pillow requests
deactivate

从HuggingFace精准下载少量图片，并生成 720p / 1080p / 2K / 4K 各5张。
总下载量约36MB，适合小样本验证。

对话数据集:
https://www.modelscope.cn/datasets/ZhipuAI/LongWriter-6k

图片数据集:
https://huggingface.co/datasets/eugenesiow/Set5/resolve/main/data/Set5_HR.tar.gz                                    720P
https://huggingface.co/datasets/Zarxrax/ModernAnimation1080_v3/tree/main/sample.zip                                 1080P
https://github.com/Benjamin-Wegener/DIV2K/tree/main/DIV2K_valid_HR/0801.jpeg                                        2K
https://huggingface.co/datasets/zhang0jhon/Aesthetic-4K/resolve/main/eval/size_4096/images/4450574274095877124.jpeg 4K

用法:
    python download_images.py
    python download_images.py --out ./test_images --num 5

    # 下载后自动为每个分辨率生成 GuideLLM 可直接读取的 JSONL 数据集：
    #   <out>/guidellm_datasets/guidellm_720P.jsonl
    #   <out>/guidellm_datasets/guidellm_1080P.jsonl
    #   <out>/guidellm_datasets/guidellm_2K.jsonl
    #   <out>/guidellm_datasets/guidellm_4K.jsonl
    #
    # 每个 JSONL 每行一条记录（image 为相对于该 JSONL 所在目录的路径）：
    #   {"image": "../2K/2K_01.jpeg", "text": "Please describe this image in detail."}
    #
    # GuideLLM 侧调用示例：
    #   guidellm run ... --data "kind=json_file,path=<jsonl路径>"

    # 若只想生成数据集，不重新下载：
    python download_images.py --out ./ --skip-download
"""
import argparse
import json
import os
import sys
import tarfile
import urllib.request
import zipfile
from pathlib import Path

os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")

try:
    from huggingface_hub import hf_hub_download
    import requests
except ImportError:
    print("请先安装依赖: pip install huggingface_hub requests")
    sys.exit(1)

IMG_EXT = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}

# 分辨率标签 -> 图片目录名（与 bash 脚本 IMAGE_PROFILES 保持一致）
RESOLUTION_PROFILES = {
    "720P": "720p",
    "1080P": "1080p",
    "2K": "2K",
    "4K": "4K",
}

# 默认伴随每张图片的文本 prompt
DEFAULT_PROMPT = "Please describe this image in detail."

# GuideLLM JSONL 输出子目录名（图片根目录下的固定位置）
GUIDELLM_DIRNAME = "guidellm_datasets"


# ---------- 工具函数 ----------

def safe_extract_tar(tar_path, dest):
    dest = Path(dest); dest.mkdir(parents=True, exist_ok=True)
    with tarfile.open(tar_path, "r:*") as t:
        members = [m for m in t.getmembers()
                   if not Path(m.name).is_absolute() and ".." not in Path(m.name).parts]
        t.extractall(dest, members=members)


def safe_extract_zip(zip_path, dest):
    dest = Path(dest); dest.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            if Path(info.filename).is_absolute() or ".." in Path(info.filename).parts:
                continue
            z.extract(info, dest)


def find_images(d):
    d = Path(d)
    return sorted(p for p in d.rglob("*") if p.is_file() and p.suffix.lower() in IMG_EXT)


def save_n(images, out_dir, n, tag):
    out_dir = Path(out_dir); out_dir.mkdir(parents=True, exist_ok=True)
    saved = 0
    for i, img in enumerate(images[:n], 1):
        dst = out_dir / f"{tag}_{i:02d}{img.suffix.lower()}"
        dst.write_bytes(img.read_bytes())
        print(f"   保存 {dst.name}")
        saved += 1
    return saved


def http_get(url, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


# ---------- 各分辨率下载 ----------

def download_720p(cache, out, n):
    print("\n[720p] Set5")
    try:
        tar = hf_hub_download("eugenesiow/Set5", "data/Set5_HR.tar.gz",
                              repo_type="dataset", cache_dir=str(cache))
        ext = cache / "set5"
        safe_extract_tar(tar, ext)
        return save_n(find_images(ext), out, n, "720p")
    except Exception as e:
        print(f"  失败: {e}")
        return 0


def download_1080p(cache, out, n):
    print("\n[1080p] ModernAnimation1080")
    for repo in ["Zarxrax/ModernAnimation1080_v3", "Zarxrax/ModernAnimation1080_v2"]:
        try:
            print(f"  尝试 {repo} ...")
            z = hf_hub_download(repo, "sample.zip", repo_type="dataset", cache_dir=str(cache))
            ext = cache / f"anim_{repo.split('_')[-1]}"
            safe_extract_zip(z, ext)
            imgs = find_images(ext)
            if imgs:
                return save_n(imgs, out, n, "1080p")
        except Exception as e:
            print(f"  失败: {e}")
    return 0


def download_2k(cache, out, n):
    print("\n[2K] DIV2K (GitHub Benjamin-Wegener/DIV2K)")
    api = "https://api.github.com/repos/Benjamin-Wegener/DIV2K/contents/DIV2K_valid_HR"
    try:
        data = json.loads(http_get(api).decode())
    except Exception as e:
        print(f"  GitHub API 失败: {e}")
        return 0

    files = [x for x in data if x.get("name", "").lower().endswith(tuple(IMG_EXT))]
    files.sort(key=lambda x: x["name"])
    if not files:
        print("  未找到图片文件")
        return 0

    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    saved = 0
    for i, f in enumerate(files[:n], 1):
        try:
            content = http_get(f["download_url"])
            dst = out / f"2K_{i:02d}{Path(f['name']).suffix.lower()}"
            dst.write_bytes(content)
            print(f"   保存 {dst.name}  ({f['name']})")
            saved += 1
        except Exception as e:
            print(f"   {f['name']} 失败: {e}")
    return saved


def download_4k(cache, out, n):
    """4K: 直接走 hf-mirror.com 的 API，避免 huggingface.co 网络不可达"""
    print("\n[4K] Aesthetic-4K")
    repo = "zhang0jhon/Aesthetic-4K"
    prefix = "eval/size_4096/images"

    api_url = f"https://hf-mirror.com/api/datasets/{repo}/tree/main/{prefix}"
    try:
        print(f"  列目录: {api_url}")
        resp = requests.get(api_url, timeout=60)
        resp.raise_for_status()
        items = resp.json()
    except Exception as e:
        print(f"  列目录失败: {e}")
        return 0

    imgs = sorted(
        item["path"] for item in items
        if item.get("type") == "file"
        and item["path"].lower().endswith(tuple(IMG_EXT))
    )
    if not imgs:
        print("  未找到图片文件")
        return 0

    print(f"  找到 {len(imgs)} 个文件，选择前 {n} 个")
    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    saved = 0
    for i, fname in enumerate(imgs[:n], 1):
        try:
            url = f"https://hf-mirror.com/datasets/{repo}/resolve/main/{fname}"
            print(f"  下载 {url}")
            r = requests.get(url, timeout=120)
            r.raise_for_status()
            dst = out / f"4K_{i:02d}{Path(fname).suffix.lower()}"
            dst.write_bytes(r.content)
            print(f"   保存 {dst.name}  ({Path(fname).name})")
            saved += 1
        except Exception as e:
            print(f"   {fname} 失败: {e}")
    return saved


# ---------- GuideLLM 数据集导出 ----------

def export_guidellm_dataset_per_resolution(root_dir, out_dir=None,
                                            prompt=DEFAULT_PROMPT,
                                            profiles=None,
                                            abs_path=False):
    """
    为每个分辨率生成一个 GuideLLM 可直接读取的 JSONL 数据集。

    JSONL 每行一条记录：
        {"image": "../2K/2K_01.jpeg", "text": "<prompt>"}
    或（abs_path=True 时）：
        {"image": "/abs/path/to/2K/2K_01.jpeg", "text": "<prompt>"}

    默认使用相对路径（相对于该 JSONL 文件自身所在目录），这样整棵
    images/ 目录树可整体迁移而无需重写 JSONL。

    GuideLLM 侧通过列名自动映射：
        --data "kind=json_file,path=<jsonl路径>"
    "image" 列会被识别为 image_column，"text" 列会被识别为 text_column。

    目录布局（与 download_images.py 的默认输出一致）：
        <root_dir>/
        ├── 720p/  1080p/  2K/  4K/       ← 图片子目录
        └── guidellm_datasets/            ← 默认 JSONL 输出目录
            ├── guidellm_720P.jsonl
            ├── guidellm_1080P.jsonl
            ├── guidellm_2K.jsonl
            └── guidellm_4K.jsonl

    参数:
        root_dir : 图片根目录，内部应有 720p/1080p/2K/4K 子目录
        out_dir  : JSONL 输出目录。
                   默认 None -> 使用 <root_dir>/guidellm_datasets，
                   与 download_images.py 的目录布局保持一致。
        prompt   : 每条记录携带的文本 prompt
        profiles : {标签: 子目录名} 映射，默认使用 RESOLUTION_PROFILES
        abs_path : 为 True 时写入绝对路径；默认 False，写入相对路径
                   （相对于 JSONL 文件所在目录）。

    返回:
        dict: {标签: (jsonl路径, 记录数)}，跳过或空目录的项不会出现
    """
    root = Path(root_dir)
    # 默认与目录树一致：图片根目录下、与各分辨率目录同级的 guidellm_datasets/
    out_dir = Path(out_dir) if out_dir is not None else (root / GUIDELLM_DIRNAME)
    out_dir.mkdir(parents=True, exist_ok=True)
    profiles = profiles or RESOLUTION_PROFILES

    results = {}

    print("\n" + "=" * 55)
    print("生成 GuideLLM JSONL 数据集")
    print("=" * 55)
    print(f"图片根目录 : {root.resolve()}")
    print(f"输出目录   : {out_dir.resolve()}")
    print(f"路径模式   : {'绝对路径' if abs_path else '相对路径（相对 JSONL 所在目录）'}")

    # 计算路径时，以 JSONL 文件所在目录为基准
    jsonl_base = out_dir.resolve()

    for label, folder in profiles.items():
        img_dir = root / folder
        if not img_dir.is_dir():
            print(f"  [{label}] 跳过：目录不存在 {img_dir}")
            continue

        images = sorted(
            p for p in img_dir.iterdir()
            if p.is_file() and p.suffix.lower() in IMG_EXT
        )
        if not images:
            print(f"  [{label}] 跳过：目录中无图片 {img_dir}")
            continue

        jsonl_path = out_dir / f"guidellm_{label}.jsonl"
        with open(jsonl_path, "w", encoding="utf-8") as f:
            for img in images:
                if abs_path:
                    image_ref = str(img.resolve())
                else:
                    # 相对于 JSONL 文件所在目录，跨平台使用 '/' 分隔
                    image_ref = Path(
                        os.path.relpath(img.resolve(), jsonl_base)
                    ).as_posix()
                record = {
                    "image": image_ref,
                    "text":  prompt,
                }
                f.write(json.dumps(record, ensure_ascii=False) + "\n")

        results[label] = (jsonl_path, len(images))
        print(f"  [{label}] {len(images)} 张 -> {jsonl_path}")

    if not results:
        print("  未生成任何 JSONL 文件（没有找到可用图片）")
    else:
        print(f"\n共生成 {len(results)} 个 JSONL 数据集")

    return results


# ---------- 主流程 ----------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=".", help="输出目录")
    ap.add_argument("--num", type=int, default=5, help="每个分辨率下载几张")
    ap.add_argument("--cache", default="./_cache", help="缓存目录")
    ap.add_argument("--skip-download", action="store_true",
                    help="跳过下载，仅生成 GuideLLM JSONL 数据集")
    ap.add_argument("--prompt", default=DEFAULT_PROMPT,
                    help="写入 JSONL 的文本 prompt")
    ap.add_argument("--guidellm-out", default=None,
                    help="GuideLLM JSONL 输出目录"
                         "（默认 <out>/guidellm_datasets）")
    ap.add_argument("--abs-path", action="store_true",
                    help="JSONL 中写入绝对路径（默认为相对 JSONL 所在目录的相对路径）")
    args = ap.parse_args()

    out = Path(args.out); out.mkdir(parents=True, exist_ok=True)
    cache = Path(args.cache); cache.mkdir(parents=True, exist_ok=True)

    results = {}

    if not args.skip_download:
        print("=" * 55)
        print(f"下载各分辨率图片，每类 {args.num} 张")
        print("=" * 55)

        results["720p"]  = download_720p(cache, out / "720p", args.num)
        results["1080p"] = download_1080p(cache, out / "1080p", args.num)
        results["2K"]    = download_2k(cache, out / "2K", args.num)
        results["4K"]    = download_4k(cache, out / "4K", args.num)

        print("\n" + "=" * 55)
        for k, v in results.items():
            print(f"  {k:6s}: {v} 张")
        print(f"  输出目录: {out.resolve()}")
        print("=" * 55)
    else:
        print("已跳过下载步骤 (--skip-download)")

    # ---- 导出 GuideLLM 数据集 ----
    # 默认 None -> 由函数内部回退到 <out>/guidellm_datasets
    guidellm_dir = Path(args.guidellm_out) if args.guidellm_out else None
    ds_results = export_guidellm_dataset_per_resolution(
        root_dir=out,
        out_dir=guidellm_dir,
        prompt=args.prompt,
        abs_path=args.abs_path,
    )

    # ---- 最终汇总 ----
    print("\n" + "=" * 55)
    print("汇总")
    print("=" * 55)
    if results:
        print("下载结果：")
        for k, v in results.items():
            print(f"  {k:6s}: {v} 张")
    if ds_results:
        print("\nGuideLLM JSONL：")
        for label, (path, cnt) in ds_results.items():
            print(f"  {label:6s}: {cnt} 条 -> {path}")
        print("\n在 bash benchmark 脚本中使用：")
        print("  --data \"kind=json_file,path=<上面任一 JSONL 路径>\"")
    print(f"\n输出目录: {out.resolve()}")
    print("=" * 55)


if __name__ == "__main__":
    main()