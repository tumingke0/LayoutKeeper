#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 LayoutKeeper contributors
"""Turns docs/releases/<version>.md into short, styled HTML release notes for the Sparkle update dialog.

The Markdown file has a Chinese part first and an English part after a "## English" heading. Download tables,
update instructions and the first-launch note are left out: the dialog only lists what changed.

  release-notes-html.py docs/releases/0.6.6.md --lang zh|en          # HTML fragment (for the appcast)
  release-notes-html.py docs/releases/0.6.6.md --preview OUT_DIR      # full pages (zh/en, light/dark) to look at
"""
import argparse, html, pathlib, re, sys

REPO = "https://github.com/tumingke0/LayoutKeeper"
SKIP_ZH = ("更新", "下载哪个文件？", "下载哪个文件?")
SKIP_LINE = re.compile(r"^(`\.zip`|.*right-click|.*右键|- \*\*Updating\*\*|- \*\*更新\*\*)", re.I)

def split(md: str):
    lines = md.splitlines()
    title = next((l[2:].strip() for l in lines if l.startswith("# ")), "")
    try:
        cut = next(i for i, l in enumerate(lines) if l.strip().lower() == "## english")
    except StopIteration:
        cut = len(lines)
    zh, en = lines[:cut], lines[cut + 1:]
    zh = [l for l in zh if not l.startswith("# ") and l.strip() != "---"]
    return title, zh, en

def drop_sections(lines, skip):
    out, skipping = [], False
    for l in lines:
        if l.startswith("## "):
            skipping = l[3:].strip() in skip
            if skipping: continue
        if not skipping: out.append(l)
    return out

def inline(text: str) -> str:
    t = html.escape(text, quote=False)
    t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    t = re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', t)
    return t

def to_html(lines) -> str:
    out, in_list = [], False
    for raw in lines:
        l = raw.rstrip()
        if SKIP_LINE.match(l.strip()) or l.startswith("|"):
            continue
        if l.startswith("- "):
            if not in_list: out.append("<ul>"); in_list = True
            out.append(f"<li>{inline(l[2:])}</li>")
            continue
        if in_list: out.append("</ul>"); in_list = False
        if l.startswith("## "): out.append(f"<h3>{inline(l[3:])}</h3>")
        elif l.strip(): out.append(f"<p>{inline(l.strip())}</p>")
    if in_list: out.append("</ul>")
    return "\n".join(out)

STYLE = """<style>
:root{color-scheme:light dark}
body{font:13px/1.5 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;margin:14px 18px;color:#1d1d1f;background:transparent}
h3{font-size:12px;font-weight:600;color:#6e6e73;text-transform:uppercase;letter-spacing:.02em;margin:14px 0 4px}
h3:first-child{margin-top:0}
ul{margin:0;padding-left:18px}li{margin:3px 0}
code{font:12px ui-monospace,Menlo,monospace;background:rgba(127,127,127,.15);border-radius:4px;padding:0 4px}
a{color:#0a66d8;text-decoration:none}
.more{margin-top:16px;font-size:11px;color:#86868b}
@media (prefers-color-scheme:dark){body{color:#f5f5f7}h3{color:#a1a1a6}a{color:#5aa2ff}.more{color:#8e8e93}}
</style>"""

def fragment(md: str, lang: str, version: str) -> str:
    _, zh, en = split(md)
    body = to_html(drop_sections(zh, SKIP_ZH)) if lang == "zh" else to_html(en)
    link = "在 GitHub 查看完整说明" if lang == "zh" else "Full release notes on GitHub"
    return f'{STYLE}\n{body}\n<p class="more"><a href="{REPO}/releases/tag/v{version}">{link}</a></p>'

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("md"); ap.add_argument("--lang", choices=["zh", "en"]); ap.add_argument("--preview")
    ap.add_argument("--version")
    a = ap.parse_args()
    path = pathlib.Path(a.md)
    version = a.version or path.stem
    md = path.read_text(encoding="utf-8")
    if a.preview:
        out = pathlib.Path(a.preview); out.mkdir(parents=True, exist_ok=True)
        for lang in ("zh", "en"):
            for scheme, bg in (("light", "#ffffff"), ("dark", "#1e1e1e")):
                page = (f'<!doctype html><html lang="{lang}"><head><meta charset="utf-8">'
                        f'<meta name="color-scheme" content="{scheme}"><style>html{{background:{bg};color-scheme:{scheme}}}</style>'
                        f"</head><body>{fragment(md, lang, version)}</body></html>")
                (out / f"release-notes-{version}-{lang}-{scheme}.html").write_text(page, encoding="utf-8")
        return
    if not a.lang: ap.error("--lang or --preview is required")
    frag = fragment(md, a.lang, version)
    if "]]>" in frag: sys.exit("release notes contain ]]>")
    sys.stdout.write(frag)

if __name__ == "__main__":
    main()
