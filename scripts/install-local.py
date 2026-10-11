#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 LayoutKeeper contributors
"""Preview/install one fixed GUI entry. Never signs, grants TCC, or quits apps."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT=Path(__file__).resolve().parent.parent
LOCAL_SIGNING_FILE=ROOT/"scripts/signing.local"


def signing_expectations(environ=None,local_file=None):
    """The approved stable signing identity is personal, so it is never committed.
    Read LAYOUTKEEPER_TEAM_ID / LAYOUTKEEPER_SIGNING_IDENTITY from the environment, or KEY=VALUE lines from the
    gitignored scripts/signing.local. Returns (team, certificate) or (None, None)."""
    environ=os.environ if environ is None else environ
    values={}
    path=LOCAL_SIGNING_FILE if local_file is None else Path(local_file)
    if path.exists():
        for line in path.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key,value=line.split("=",1); values[key.strip()]=value.strip()
    team=environ.get("LAYOUTKEEPER_TEAM_ID") or values.get("LAYOUTKEEPER_TEAM_ID")
    certificate=environ.get("LAYOUTKEEPER_SIGNING_IDENTITY") or values.get("LAYOUTKEEPER_SIGNING_IDENTITY")
    return (team,certificate) if team and certificate else (None,None)


def fixed_bundle_url(home):
    return Path(home)/"Applications/LayoutKeeper.app"


def identity(bundle,require_stable=False):
    subprocess.run(["codesign","--verify","--strict",str(bundle)],check=True,capture_output=True,timeout=5)
    info=plistlib.loads((bundle/"Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier")!="local.layoutkeeper.app" or info.get("CFBundleExecutable")!="LayoutKeeper":
        raise ValueError("Unexpected bundle identity")
    result=subprocess.run(["codesign","-d","-r-",str(bundle)],check=True,capture_output=True,text=True,timeout=5)
    requirement=next(line for line in (result.stdout+result.stderr).splitlines() if "designated =>" in line).lstrip("# ").strip()
    if require_stable:
        metadata=subprocess.run(["codesign","-d","--verbose=4",str(bundle)],check=True,capture_output=True,text=True,timeout=5)
        text=metadata.stdout+metadata.stderr
        team,certificate=signing_expectations()
        if team is None:
            raise ValueError("Fixed installation requires the approved stable development signature: set LAYOUTKEEPER_TEAM_ID and LAYOUTKEEPER_SIGNING_IDENTITY (or scripts/signing.local); ad-hoc candidates are test artifacts only")
        if "Signature=adhoc" in text or f"TeamIdentifier={team}" not in text or certificate not in requirement or "anchor apple generic" not in requirement:
            raise ValueError("Fixed installation requires the approved stable development signature; ad-hoc candidates are test artifacts only")
    return requirement


def running_bundles(rows):
    result=[]
    suffix="/LayoutKeeper.app/Contents/MacOS/LayoutKeeper"
    for row in rows.splitlines():
        fields=row.strip().split(None,1)
        if len(fields)!=2: continue
        pid,executable=fields
        if executable.endswith(suffix): result.append(executable[:-len("/Contents/MacOS/LayoutKeeper")])
        elif executable=="LayoutKeeper": result.append(f"unknown path (PID {pid})")
    return result


def read_running_bundles():
    try:
        result=subprocess.run(["ps","-axo","pid=,comm="],check=True,capture_output=True,text=True,timeout=5)
    except (OSError,subprocess.SubprocessError) as error:
        raise ValueError("Cannot verify running LayoutKeeper processes; installation blocked without requesting permissions") from error
    return running_bundles(result.stdout)


def migrate_layouts(source,target):
    if not source.is_dir(): return 0
    copied=0
    for record in source.rglob("*.json"):
        if record.is_symlink() or not record.is_file(): continue
        destination=target/record.relative_to(source)
        if destination.exists(): continue
        data=record.read_bytes()
        destination.parent.mkdir(parents=True,exist_ok=True)
        try:
            with destination.open("xb") as file: file.write(data)
        except FileExistsError: continue
        copied+=1
    return copied


def promote(candidate,installed,dry_run=True,accept_identity_change=False,layout_source=None,layout_target=None):
    candidate=Path(candidate); installed=Path(installed)
    if candidate.is_symlink() or installed.is_symlink(): raise ValueError("Bundle symlinks are not installation targets")
    if candidate.resolve()==installed.resolve(): raise ValueError("Candidate is already the fixed installation")
    new=identity(candidate,require_stable=True)
    old=identity(installed) if installed.exists() else None
    changed=old is not None and new!=old
    running=read_running_bundles()
    report={"candidate":str(candidate),"installed":str(installed),"candidateRequirement":new,"installedRequirement":old,
            "identityChanged":changed,"checkOnly":dry_run,"runningBundles":running,
            "readyForInstall":not running and (not changed or accept_identity_change)}
    if dry_run: return report
    if changed and not accept_identity_change: raise ValueError("Designated identity changed; explicit acceptance required")
    if running: raise ValueError("LayoutKeeper is running; quit it normally before installation. No process was terminated")
    digest=hashlib.sha256((candidate/"Contents/MacOS/LayoutKeeper").read_bytes()).digest()
    installed.parent.mkdir(parents=True,exist_ok=True)
    stage=Path(tempfile.mkdtemp(prefix=".layoutkeeper-staging-",dir=installed.parent))
    staged=stage/"LayoutKeeper.app"
    backup=None
    try:
        shutil.copytree(candidate,staged)
        if identity(staged,require_stable=True)!=new: raise ValueError("Staged identity differs from verified candidate")
        if hashlib.sha256((staged/"Contents/MacOS/LayoutKeeper").read_bytes()).digest()!=digest or hashlib.sha256((candidate/"Contents/MacOS/LayoutKeeper").read_bytes()).digest()!=digest:
            raise ValueError("Candidate changed during staging")
        if read_running_bundles(): raise ValueError("LayoutKeeper started running during staging; installation blocked")
        migrated=migrate_layouts(Path(layout_source),Path(layout_target)) if layout_source is not None and layout_target is not None else 0
        if installed.exists():
            stamp=datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d-%H%M%SZ")+"-"+uuid.uuid4().hex
            backup=installed.parent/"LayoutKeeper-backups"/stamp/"LayoutKeeper.app"
            backup.parent.mkdir(parents=True,exist_ok=False)
            installed.rename(backup)
        try: staged.rename(installed)
        except OSError:
            if backup is not None and not installed.exists(): backup.rename(installed)
            raise
        report.update({"backup":str(backup) if backup is not None else None,"migratedLayoutCount":migrated,"installedSuccessfully":True})
        return report
    finally:
        shutil.rmtree(stage)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    mode=parser.add_mutually_exclusive_group()
    mode.add_argument("--check-only",action="store_true",help="Preview only (the default)")
    mode.add_argument("--install",action="store_true",help="Perform the already-authorized fixed-path installation")
    parser.add_argument("--candidate",type=Path,default=ROOT/"build-products/LayoutKeeper.app")
    parser.add_argument("--layout-source",type=Path,default=ROOT/"Layouts")
    parser.add_argument("--accept-identity-change",action="store_true",help="Use only after explicitly approving a changed designated identity")
    args=parser.parse_args()
    home=Path.home()
    report=promote(args.candidate,fixed_bundle_url(home),dry_run=not args.install,accept_identity_change=args.accept_identity_change,
                   layout_source=args.layout_source,layout_target=home/"Library/Application Support/LayoutKeeper/Layouts")
    print(json.dumps(report,indent=2))
    return 0


if __name__=="__main__":
    try: sys.exit(main())
    except (OSError,ValueError,subprocess.SubprocessError,StopIteration) as error:
        print("BLOCKED:",error,file=sys.stderr); sys.exit(2)
