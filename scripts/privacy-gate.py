#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 LayoutKeeper contributors
"""Privacy gate for build products.

Scans every file in the given .app bundles / files / .dmg images (binaries via `strings -a`, everything else as text)
and exits non-zero if it finds:
  - absolute home paths ("/Users/"), the current $USER and $HOME;
  - private terms from the gitignored scripts/signing.local (values) and scripts/privacy-terms.local (one per line);
  - e-mail addresses that aren't on ALLOWED_EMAILS / ALLOWED_EMAIL_DOMAINS.
Private terms are never printed; findings name the file and the kind of match only.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parent.parent
ALLOWED_EMAILS=set()
# Apple / toolchain strings that can appear in system-generated metadata.
ALLOWED_EMAIL_DOMAINS={"users.noreply.github.com"}
EMAIL=re.compile(rb"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
# Asset names such as "icon_16x16@2x.png" match the e-mail pattern; a "domain" ending in a file extension is not an address.
FILE_SUFFIXES={"png","jpg","jpeg","gif","tif","tiff","pdf","heic","svg","icns","car"}
MIN_TERM=3   # shorter $USER values would match too much

def private_terms(signing: Path,terms_file: Path,env: dict) -> list[tuple[str,bytes]]:
    terms=[("home folder path",b"/Users/")]
    for name in ("USER","HOME"):
        value=env.get(name,"").strip()
        if len(value)>=MIN_TERM and value!="/": terms.append((f"${name}",value.encode()))
    if signing.is_file():
        for line in signing.read_text(errors="replace").splitlines():
            line=line.strip()
            if line and not line.startswith("#") and "=" in line:
                value=line.split("=",1)[1].strip().strip('"').strip("'")
                if len(value)>=MIN_TERM: terms.append((f"signing.local {line.split('=',1)[0].strip()}",value.encode()))
    if terms_file.is_file():
        for line in terms_file.read_text(errors="replace").splitlines():
            line=line.strip()
            if len(line)>=MIN_TERM and not line.startswith("#"): terms.append(("privacy-terms.local entry",line.encode()))
    return terms

def file_text(path: Path) -> bytes:
    data=path.read_bytes()
    if data[:4] in (b"\xcf\xfa\xed\xfe",b"\xce\xfa\xed\xfe",b"\xca\xfe\xba\xbe",b"\xbe\xba\xfe\xca"):
        out=subprocess.run(["strings","-a","-n","4",str(path)],capture_output=True,check=True).stdout
        return out+b"\n"+data   # strings output plus raw bytes (covers short or UTF-16 fragments strings may skip)
    return data

def email_allowed(addr: bytes) -> bool:
    a=addr.decode(errors="replace").lower()
    if a.rsplit(".",1)[-1] in FILE_SUFFIXES: return True
    return a in ALLOWED_EMAILS or any(a.endswith("@"+d) or a.endswith("."+d) for d in ALLOWED_EMAIL_DOMAINS)

def scan_tree(root: Path,terms,label: str) -> list[str]:
    findings=[]
    files=[root] if root.is_file() else sorted(p for p in root.rglob("*") if p.is_file() and not p.is_symlink())
    for f in files:
        try: text=file_text(f)
        except Exception as e: findings.append(f"{label}/{f.relative_to(root) if f!=root else f.name}: unreadable ({e})"); continue
        rel=f"{label}/{f.relative_to(root)}" if f!=root else label
        low=text.lower()
        for kind,term in terms:
            if term.lower() in low: findings.append(f"{rel}: contains {kind}")
        for m in set(EMAIL.findall(text)):
            if not email_allowed(m): findings.append(f"{rel}: contains e-mail address ({m.split(b'@')[-1].decode(errors='replace')})")
    return list(dict.fromkeys(findings))

def scan_dmg(dmg: Path,terms) -> list[str]:
    mount=Path(tempfile.mkdtemp(prefix="lk-privacy-"))
    subprocess.run(["hdiutil","attach","-quiet","-nobrowse","-readonly","-mountpoint",str(mount),str(dmg)],check=True)
    try:
        return [f for item in sorted(mount.iterdir()) if not item.is_symlink() for f in scan_tree(item,terms,f"{dmg.name}:{item.name}")]
    finally:
        subprocess.run(["hdiutil","detach","-quiet",str(mount)],check=False)
        try: mount.rmdir()
        except OSError: pass

def main(argv=None) -> int:
    ap=argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("paths",nargs="+",type=Path)
    ap.add_argument("--signing-file",type=Path,default=ROOT/"scripts/signing.local")
    ap.add_argument("--terms-file",type=Path,default=ROOT/"scripts/privacy-terms.local")
    args=ap.parse_args(argv)
    terms=private_terms(args.signing_file,args.terms_file,dict(os.environ))
    findings=[]
    for p in args.paths:
        if not p.exists(): findings.append(f"{p}: does not exist"); continue
        findings+=scan_dmg(p,terms) if p.suffix==".dmg" else scan_tree(p,terms,p.name)
    if findings:
        print("PRIVACY GATE FAILED — build products contain private data:",file=sys.stderr)
        for f in findings: print(f"  - {f}",file=sys.stderr)
        print("Fix the source of the leak (e.g. strip debug symbols, remove absolute paths) and rebuild.",file=sys.stderr)
        return 1
    print(f"Privacy gate passed ({', '.join(p.name for p in args.paths)}; {len(terms)} terms + e-mail check).")
    return 0

if __name__=="__main__":
    sys.exit(main())
