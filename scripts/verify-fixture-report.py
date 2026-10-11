#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 LayoutKeeper contributors
"""Read-only independent validation of raw live-fixture integration evidence."""
import json
import sys


def require(condition, detail):
    if not condition:
        raise ValueError(detail)


def frame(sample, kind):
    value = sample[kind]
    if kind == "cgWindowBounds":
        return tuple(value[key] for key in ("X", "Y", "Width", "Height"))
    return tuple(value[key] for key in ("x", "y", "width", "height"))


def check_sample(sample, expected, space, window_id, with_ax=False):
    require(sample["liveWindowID"] == window_id, "Window identity changed")
    require(sample["spaceIDs"] == [space], "Space membership differs")
    for kind in ("appKitFrameAXCoordinates", "cgWindowBounds") + (("axFrame",) if with_ax else ()):
        require(all(abs(a-b) <= 3 for a, b in zip(frame(sample, kind), expected)), kind + " differs")
    if with_ax:
        require(sample["axOrdinary"] is True, "AX window is not ordinary")
        require(sample["axSpaceIDs"] == [space], "AX Space membership differs")


def verify(path):
    with open(path, encoding="utf-8") as handle:
        report = json.load(handle)
    require(report["testKind"] == "REAL macOS fixture integration", "Report is not a real integration run")
    require(report["build"] == "26A428", "Unexpected build")
    require(report["stage"] == "finished", "Run did not finish")
    require(report["generalSpaceBackendEnabled"] is False, "General Space backend was enabled")
    source, window_id = report["sourceRuntimeSpace"], report["runtimeWindowID"]
    original = frame(report["initial"], "appKitFrameAXCoordinates")
    if report["phase"] in ("all", "spaces"):
        test = report["spacesTest"]
        require(test["source"] == source and test["target"] != source, "Source and target invalid")
        require(test["sameDisplay"] is True, "Test scope is not same-display")
        check_sample(test["before"], original, source, window_id)
        check_sample(test["afterOutbound"], original, test["target"], window_id)
        check_sample(test["afterReturn"], original, source, window_id)
        print("PASS actual Space membership and AppKit/CG geometry:", source, "->", test["target"], "->", source)
    if report["phase"] in ("all", "ax"):
        require(report["accessibilityTrusted"] is True, "AX permission missing")
        test = report["axTest"]
        changed = tuple(test["requestedChange"][key] for key in ("x", "y", "width", "height"))
        require(changed != original, "No geometry change was requested")
        check_sample(test["before"], original, source, window_id, True)
        check_sample(test["afterChange"], changed, source, window_id, True)
        check_sample(test["afterRestore"], original, source, window_id, True)
        require(test["previewStatus"] == ["ready"], "Unexpected plan")
        require([row["outcome"] for row in test["restoreResults"]] == ["verified"], "Restore was not verified")
        require(test["windowServerRestoreVerified"] is True, "WindowServer settlement missing")
        print("PASS actual AX/AppKit/CG change and planned restore:", original, "->", changed, "->", original)
    check_sample(report["final"], original, source, window_id, report["phase"] in ("all", "ax"))


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("Usage: verify-fixture-report.py REPORT.json")
        verify(sys.argv[1])
    except (KeyError, TypeError, ValueError, OSError) as error:
        print("FAIL:", error, file=sys.stderr)
        sys.exit(1)
