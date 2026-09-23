#!/usr/bin/env python3
"""
将 models.dev 的 models.json 转换为 Excel。
用法:
  python models-lists_update.py                     # 从网络下载，输出 models-YYYYMMDD.xlsx
  python models-lists_update.py -i local.json       # 使用本地 JSON，输出 models-YYYYMMDD.xlsx
  python models-lists_update.py -i local.json -o out.xlsx
"""

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

import pandas as pd
import requests
from openpyxl.utils import get_column_letter

DEFAULT_URL = "https://models.dev/models.json"
DEFAULT_TIMEOUT = 60
CHUNK_SIZE = 8192


def parse_args():
    parser = argparse.ArgumentParser(
        description="将 models.dev 的 models.json 转换为 Excel 表格"
    )
    parser.add_argument(
        "-i", "--input",
        help="本地 JSON 文件路径。指定后不从网络下载。",
        default=None,
    )
    parser.add_argument(
        "-o", "--output",
        help="输出 Excel 文件路径。默认按 models-YYYYMMDD.xlsx 命名。",
        default=None,
    )
    parser.add_argument(
        "-u", "--url",
        help=f"JSON 下载地址（默认: {DEFAULT_URL}）",
        default=DEFAULT_URL,
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT,
        help=f"下载超时秒数（默认: {DEFAULT_TIMEOUT}）",
    )
    return parser.parse_args()


def download_json(url: str, output_path: Path, timeout: int = DEFAULT_TIMEOUT) -> Path:
    """从网络下载 JSON 并保存到 output_path。"""
    print(f"[下载] 正在从 {url} 获取数据 ...")
    try:
        resp = requests.get(url, stream=True, timeout=timeout)
        resp.raise_for_status()
    except requests.RequestException as e:
        print(f"[错误] 下载失败: {e}", file=sys.stderr)
        sys.exit(1)

    total = 0
    with open(output_path, "wb") as f:
        for chunk in resp.iter_content(chunk_size=CHUNK_SIZE):
            if chunk:
                f.write(chunk)
                total += len(chunk)
                # 简单进度：每 512KB 打印一次
                if total % (512 * 1024) < CHUNK_SIZE:
                    print(f"  已下载 {total / 1024:.0f} KB ...", end="\r")

    print(f"\n[下载] 完成，共 {total / 1024:.0f} KB -> {output_path}")
    return output_path


def load_json(path: Path) -> dict:
    """加载本地 JSON 文件。"""
    print(f"[读取] 正在解析 {path} ...")
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(f"[错误] 无法读取 JSON: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"[读取] 共 {len(data)} 个模型")
    return data


def extract_rows(data: dict):
    """从原始 JSON 中提取模型行和 benchmark 行。"""
    model_rows = []
    bench_rows = []

    for key, m in data.items():
        model_id = m.get("id", key)
        mods = m.get("modalities") or {}
        limit = m.get("limit") or {}
        weights = m.get("weights") or []
        links = m.get("links") or []
        benchmarks = m.get("benchmarks") or []

        weights_text = " | ".join(
            f"{w.get('label', '')}: {w.get('url', '')}"
            + (f" [{w.get('quantization')}]" if w.get("quantization") else "")
            for w in weights
        )

        links_text = " | ".join(
            f"{l.get('label', '')}: {l.get('url', '')}"
            for l in links
        )

        benchmarks_text = " | ".join(
            f"{b.get('name', '')}: {b.get('score', '')} {b.get('metric', '')}".strip()
            for b in benchmarks
        )

        model_rows.append({
            "id": model_id,
            "name": m.get("name"),
            "family": m.get("family"),
            "description": m.get("description"),
            "attachment": m.get("attachment"),
            "reasoning": m.get("reasoning"),
            "tool_call": m.get("tool_call"),
            "structured_output": m.get("structured_output"),
            "temperature": m.get("temperature"),
            "knowledge": m.get("knowledge"),
            "release_date": m.get("release_date"),
            "last_updated": m.get("last_updated"),
            "open_weights": m.get("open_weights"),
            "license": m.get("license"),
            "input_modalities": "; ".join(mods.get("input") or []),
            "output_modalities": "; ".join(mods.get("output") or []),
            "context_limit": limit.get("context"),
            "input_limit": limit.get("input"),
            "output_limit": limit.get("output"),
            "weights": weights_text,
            "links": links_text,
            "benchmark_count": len(benchmarks),
            "benchmarks_summary": benchmarks_text,
        })

        for b in benchmarks:
            bench_rows.append({
                "model_id": model_id,
                "model_name": m.get("name"),
                "benchmark_name": b.get("name"),
                "score": b.get("score"),
                "metric": b.get("metric"),
                "variant": b.get("variant"),
                "version": b.get("version"),
                "harness": b.get("harness"),
                "dataset": b.get("dataset"),
                "source": b.get("source"),
                "date": b.get("date"),
            })

    return model_rows, bench_rows


def build_excel(model_rows, bench_rows, output_path: Path):
    """生成 Excel 文件。"""
    print(f"[生成] 正在构建 Excel -> {output_path}")

    df_models = pd.DataFrame(model_rows)
    df_bench = pd.DataFrame(bench_rows)

    # 这些列往往是长文本，列宽单独限制，避免整个表被拉得太宽
    narrow_cols = {"description", "benchmarks_summary", "weights", "links"}

    with pd.ExcelWriter(output_path, engine="openpyxl") as writer:
        df_models.to_excel(writer, sheet_name="模型", index=False)
        df_bench.to_excel(writer, sheet_name="Benchmarks", index=False)

        for sheet_name, df in [("模型", df_models), ("Benchmarks", df_bench)]:
            ws = writer.sheets[sheet_name]
            ws.freeze_panes = "A2"
            if not df.empty:
                ws.auto_filter.ref = ws.dimensions

            for idx, col in enumerate(df.columns, 1):
                if df.empty:
                    max_len = len(str(col))
                else:
                    # 用原生 Python 计算，避免 pandas 扩展数组对 float/NaN 的兼容问题
                    values = df[col].tolist()
                    max_len = max((len(str(v)) for v in values), default=0)
                    max_len = max(max_len, len(str(col)))

                if col in narrow_cols:
                    width = min(max_len + 2, 60)
                else:
                    width = min(max_len + 2, 80)

                ws.column_dimensions[get_column_letter(idx)].width = width

    print(f"[完成] 模型数: {len(df_models)}，benchmark 数: {len(df_bench)}")
    print(f"[完成] 文件已保存: {output_path.resolve()}")


def main():
    args = parse_args()

    # 确定输出文件名
    if args.output:
        output_path = Path(args.output)
    else:
        date_str = datetime.now().strftime("%Y%m%d")
        output_path = Path(f"models-{date_str}.xlsx")

    # 获取 JSON 数据
    if args.input:
        input_path = Path(args.input)
        if not input_path.exists():
            print(f"[错误] 文件不存在: {input_path}", file=sys.stderr)
            sys.exit(1)
        data = load_json(input_path)
    else:
        json_path = Path(f"models-{datetime.now().strftime('%Y%m%d')}.json")
        download_json(args.url, json_path, args.timeout)
        data = load_json(json_path)

    # 提取并生成
    model_rows, bench_rows = extract_rows(data)
    build_excel(model_rows, bench_rows, output_path)


if __name__ == "__main__":
    main()