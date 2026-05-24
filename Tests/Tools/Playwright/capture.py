"""
Minimal Playwright capture helper for the windows-gui-tests W-06 phase.

Renders one or more local HTML report files in headless Chromium and saves
full-page PNG screenshots to an output directory.

Usage:
    python capture.py <html-path> [<html-path>...] \
        --output-dir <dir> \
        --prefix <name> \
        [--full-page] \
        [--width 1280] [--height 800] \
        [--scroll-captures] [--scroll-step 800]

Each HTML file produces:
    <output-dir>/<prefix>-<basename>.png     (full-page if --full-page)

With --scroll-captures, additional partial captures are written:
    <output-dir>/<prefix>-<basename>-scroll-<N>.png
"""
from __future__ import annotations
import argparse
import os
import sys
from pathlib import Path
from urllib.parse import quote
from playwright.sync_api import sync_playwright


def file_url(p: Path) -> str:
    return "file:///" + quote(str(p.resolve()).replace("\\", "/"))


def capture_one(page, html_path: Path, out_dir: Path, prefix: str,
                full_page: bool, scroll_captures: bool, scroll_step: int) -> list[Path]:
    written: list[Path] = []
    page.goto(file_url(html_path), wait_until="load")
    # Some reports render with on-load JS expansion (e.g. campaign-audit-combined
    # auto-expands the Revoked section). Give the browser a beat to settle.
    page.wait_for_timeout(700)

    base = html_path.stem
    if prefix:
        base = f"{prefix}-{base}"
    main_png = out_dir / f"{base}.png"
    page.screenshot(path=str(main_png), full_page=full_page)
    written.append(main_png)

    if scroll_captures:
        total_height = page.evaluate("document.documentElement.scrollHeight")
        viewport = page.viewport_size or {"width": 1280, "height": 800}
        h = viewport["height"]
        n = 0
        y = 0
        while y < total_height:
            page.evaluate(f"window.scrollTo(0, {y});")
            page.wait_for_timeout(150)
            shot = out_dir / f"{base}-scroll-{n:02d}.png"
            page.screenshot(path=str(shot), full_page=False)
            written.append(shot)
            n += 1
            y += scroll_step
    return written


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Playwright capture helper for HTML reports.")
    ap.add_argument("html_paths", nargs="+", help="HTML files to capture")
    ap.add_argument("--output-dir", required=True)
    ap.add_argument("--prefix", default="")
    ap.add_argument("--full-page", action="store_true")
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=800)
    ap.add_argument("--scroll-captures", action="store_true")
    ap.add_argument("--scroll-step", type=int, default=800)
    args = ap.parse_args(argv)

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    targets: list[Path] = []
    for s in args.html_paths:
        p = Path(s)
        if not p.exists():
            print(f"WARN: skipping missing path: {p}", file=sys.stderr)
            continue
        targets.append(p)

    if not targets:
        print("ERROR: no HTML paths provided that exist on disk.", file=sys.stderr)
        return 2

    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        try:
            ctx = browser.new_context(viewport={"width": args.width, "height": args.height})
            page = ctx.new_page()
            for t in targets:
                paths = capture_one(
                    page, t, out_dir, args.prefix,
                    full_page=args.full_page,
                    scroll_captures=args.scroll_captures,
                    scroll_step=args.scroll_step,
                )
                for p in paths:
                    print(str(p))
        finally:
            browser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
