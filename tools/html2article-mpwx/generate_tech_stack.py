#!/usr/bin/env python3
"""Generate a floating tech-stack SVG from ALL skillicons.dev icons.

The icon list is resolved dynamically from the skillicons.dev upstream repo
(tandpfun/skill-icons), so every icon the site supports is supported here —
no hard-coded list.

Usage:
    python generate_tech_stack.py > tech-stack.svg
    python generate_tech_stack.py --icons vuejs,react,python --theme dark -o out.svg
    python generate_tech_stack.py --max-width 900 -o tech-stack.svg
    python generate_tech_stack.py --list        # print all available icon names

Icons are laid out as a centered grid that fits within --max-width (default 980px,
about the GitHub README content width); each row, including a trailing partial row,
is centered like a phone home screen.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = "tandpfun/skill-icons"  # upstream of https://skillicons.dev/
TREE_URL = f"https://api.github.com/repos/{REPO}/git/trees/HEAD?recursive=1"
RAW_URL = f"https://raw.githubusercontent.com/{REPO}/HEAD/icons/{{name}}"
SVG_NS = "http://www.w3.org/2000/svg"
VARIANT_RE = re.compile(r"^(?P<base>.+?)(?:-(?P<variant>Dark|Light))?\.svg$")

# Preferred file variants per theme: None = suffix-less base file.
THEME_PRIORITY = {
    "auto": (None, "Light", "Dark"),
    "light": (None, "Light", "Dark"),
    "dark": ("Dark", None, "Light"),
}

ET.register_namespace("", SVG_NS)
ET.register_namespace("xlink", "http://www.w3.org/1999/xlink")


def http_get(url: str, timeout: int = 30, retries: int = 3) -> bytes:
    last: Exception | None = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": "tech-stack-svg/2.0", "Accept": "*/*"}
            )
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except Exception as e:  # flaky network: retry with backoff
            last = e
            time.sleep(0.5 * (attempt + 1))
    raise last


def list_icon_files() -> dict[str, dict]:
    """Return {base_name: {variant_or_None: filename}} for every repo icon."""
    tree = json.loads(http_get(TREE_URL))
    files: dict[str, dict] = {}
    for entry in tree.get("tree", []):
        path = entry["path"]
        if not path.startswith("icons/"):
            continue
        m = VARIANT_RE.match(Path(path).name)
        if not m:
            continue
        files.setdefault(m["base"], {})[m["variant"]] = Path(path).name
    return files


def pick_variant(variants: dict, theme: str):
    for wanted in THEME_PRIORITY[theme]:
        if wanted in variants:
            return variants[wanted]
    return None


def compute_per_row(max_width: int, size: int, gap: int, margin: int) -> int:
    """Largest per-row count whose row width stays within max_width."""
    per_row = (max_width - 2 * margin + gap) // (size + gap)
    return max(1, per_row)


def parse_icon(svg_bytes: bytes):
    """Return (viewBox, root_attrs, inner_xml) for a single icon SVG."""
    root = ET.fromstring(svg_bytes)
    if root.get("viewBox") is None:
        raise ValueError("missing viewBox")
    vx, vy, vw, vh = (float(v) for v in root.get("viewBox").split())
    root_attrs = {
        k: root.get(k) for k in ("fill", "stroke", "fill-rule") if root.get(k)
    }
    inner = "\n".join(ET.tostring(child, encoding="unicode") for child in root)
    return (vx, vy, vw, vh), root_attrs, inner


def fetch_icon(base: str, filename: str):
    """Download and parse one icon. Returns (base, viewBox, attrs, inner) or None."""
    try:
        box, attrs, inner = parse_icon(http_get(RAW_URL.format(name=filename)))
    except Exception as e:
        print(f"[warn] fetch {base}: {e}", file=sys.stderr)
        return None
    return base, box, attrs, inner


def render_svg(icons, per_row: int, size: int, gap: int, margin: int) -> str:
    """Compose the final animated SVG. icons: [(name, viewBox, attrs, inner)].

    Rows are centered horizontally, so a trailing partial row (like the last row
    of a phone home screen) sits in the middle instead of hugging the left edge.
    """
    rows = (len(icons) + per_row - 1) // per_row
    cell = size + gap
    inner_width = per_row * size + (per_row - 1) * gap  # width of a full row
    width = inner_width + 2 * margin
    height = rows * cell - gap + 2 * margin

    out = [
        f'<svg xmlns="{SVG_NS}" viewBox="0 0 {width} {height}" '
        f'width="{width}" height="{height}" role="img" aria-label="Tech stack">',
        "  <style>",
        "    @keyframes ts-float {",
        "      0%, 100% { transform: translateY(0); }",
        "      50%      { transform: translateY(-3px); }",
        "    }",
        "    .ts-icon { animation: ts-float 3s ease-in-out infinite; }",
        "  </style>",
    ]

    for row in range(rows):
        start = row * per_row
        count = min(per_row, len(icons) - start)
        x_offset = (inner_width - (count * size + (count - 1) * gap)) // 2
        for col in range(count):
            name, (vx, vy, vw, vh), attrs, inner = icons[start + col]
            x = margin + x_offset + col * cell
            y = margin + row * cell
            scale = size / max(vw, vh)
            ox = (size - vw * scale) / 2
            oy = (size - vh * scale) / 2
            delay = col * 0.1 + row * 0.05  # staggered wave
            attr_xml = (" " + " ".join(f'{k}="{v}"' for k, v in attrs.items())) if attrs else ""

            out.append(f'  <g transform="translate({x:.2f},{y:.2f})">')
            out.append(f'    <g class="ts-icon" style="animation-delay: {delay:.2f}s">')
            out.append(
                f'      <g transform="translate({ox:.4f},{oy:.4f}) '
                f'scale({scale:.6f}) translate({-vx:.2f},{-vy:.2f})"{attr_xml}>'
            )
            out.append(f'        <title>{name}</title>')
            out.append(f"        {inner}")
            out.append("      </g>")
            out.append("    </g>")
            out.append("  </g>")

    out.append("</svg>")
    return "\n".join(out) + "\n"


def normalize(name: str) -> str:
    return re.sub(r"[^a-z0-9]", "", name.lower())


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Compose an animated tech-stack SVG from all skillicons.dev icons."
    )
    parser.add_argument("--icons", help="comma-separated icon names (default: all)")
    parser.add_argument(
        "--theme", choices=sorted(THEME_PRIORITY), default="auto",
        help="icon variant to prefer (default: auto)",
    )
    parser.add_argument(
        "--per-row", type=int, default=None,
        help="icons per row (default: auto, fit as many as possible within --max-width)",
    )
    parser.add_argument(
        "--max-width", type=int, default=980,
        help="target row width in px, about the GitHub README content width (default: 980)",
    )
    parser.add_argument("--size", type=int, default=64, help="icon cell size in px")
    parser.add_argument("--gap", type=int, default=20, help="gap between cells in px")
    parser.add_argument("--margin", type=int, default=10)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("-o", "--output", help="write to file instead of stdout")
    parser.add_argument("--list", action="store_true", help="list available names and exit")
    args = parser.parse_args(argv)

    files = list_icon_files()
    names = sorted(files)
    if args.list:
        print("\n".join(names))
        return 0

    if args.icons:
        wanted = [normalize(n) for n in args.icons.split(",") if n.strip()]
        by_norm = {normalize(n): n for n in names}
        selected = [by_norm[w] for w in wanted if w in by_norm]
        for w in wanted:
            if w not in by_norm:
                print(f"[warn] unknown icon: {w}", file=sys.stderr)
        if not selected:
            print("[error] no matching icons, try --list", file=sys.stderr)
            return 1
    else:
        selected = names

    tasks = [(n, pick_variant(files[n], args.theme)) for n in selected]
    tasks = [(n, f) for n, f in tasks if f]
    print(f"[info] fetching {len(tasks)} icons from {REPO} (theme={args.theme})", file=sys.stderr)

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        results = list(pool.map(lambda t: fetch_icon(*t), tasks))

    icons, failed = [], []
    for (name, _), result in zip(tasks, results):
        if result is None:
            failed.append(name)
        else:
            icons.append(result)

    if failed:
        print(f"[warn] failed: {', '.join(failed)}", file=sys.stderr)
    if not icons:
        print("[error] no icons fetched", file=sys.stderr)
        return 1

    per_row = args.per_row
    if per_row is None:
        per_row = compute_per_row(args.max_width, args.size, args.gap, args.margin)
        print(f"[info] auto per-row={per_row} (max-width={args.max_width}px)", file=sys.stderr)
    elif per_row * args.size + (per_row - 1) * args.gap + 2 * args.margin > args.max_width:
        print(f"[warn] per-row={per_row} exceeds max-width={args.max_width}px", file=sys.stderr)

    svg = render_svg(icons, per_row, args.size, args.gap, args.margin)
    if args.output:
        Path(args.output).write_text(svg, encoding="utf-8")
        print(f"[info] wrote {args.output} ({len(icons)} icons)", file=sys.stderr)
    else:
        sys.stdout.write(svg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
