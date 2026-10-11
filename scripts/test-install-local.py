#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 LayoutKeeper contributors
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

spec=importlib.util.spec_from_file_location("installer",Path(__file__).with_name("install-local.py"))
installer=importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

class FixedInstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.root=Path(self.tmp.name)
        self.candidate=self.root/"candidate/LayoutKeeper.app"
        self.installed=self.root/"Applications/LayoutKeeper.app"
        (self.candidate/"Contents/MacOS").mkdir(parents=True)
        (self.candidate/"Contents/MacOS/LayoutKeeper").write_bytes(b"new")
        (self.candidate/"Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":"local.layoutkeeper.app","CFBundleExecutable":"LayoutKeeper"}))
    def tearDown(self): self.tmp.cleanup()
    def old(self):
        (self.installed/"Contents/MacOS").mkdir(parents=True)
        (self.installed/"Contents/MacOS/LayoutKeeper").write_bytes(b"old")

    def testFixedEntryIsInUsersApplications(self):
        self.assertEqual(installer.fixed_bundle_url(self.root),self.root/"Applications/LayoutKeeper.app")

    def testRunningPathsWithSpacesArePreserved(self):
        rows="42 /Volumes/Data/My Project/build-products/LayoutKeeper.app/Contents/MacOS/LayoutKeeper\n43 /tmp/layoutkeeperctl\n"
        self.assertEqual(installer.running_bundles(rows),["/Volumes/Data/My Project/build-products/LayoutKeeper.app"])

    def testAdHocCandidateCannotBecomeFixedInstall(self):
        def response(args,**kwargs):
            if "--verify" in args: return SimpleNamespace(stdout="",stderr="",returncode=0)
            if "-r-" in args: return SimpleNamespace(stdout="",stderr='designated => cdhash H"123"',returncode=0)
            return SimpleNamespace(stdout="",stderr="Signature=adhoc\nTeamIdentifier=not set",returncode=0)
        with patch.object(installer.subprocess,"run",side_effect=response):
            with self.assertRaisesRegex(ValueError,"stable development"):
                installer.identity(self.candidate,require_stable=True)

    def testPreviewWritesNothing(self):
        with patch.object(installer,"identity",return_value="stable"),patch.object(installer,"read_running_bundles",return_value=[]):
            report=installer.promote(self.candidate,self.installed,dry_run=True)
        self.assertTrue(report["checkOnly"])
        self.assertFalse(self.installed.exists())
        self.assertEqual((self.candidate/"Contents/MacOS/LayoutKeeper").read_bytes(),b"new")

    def testSigningIdentityComesFromEnvironmentOrLocalFileNeverSource(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing=Path(tmp)/"none"
            self.assertEqual(installer.signing_expectations({},missing),(None,None))
            self.assertEqual(installer.signing_expectations({"LAYOUTKEEPER_TEAM_ID":"T"},missing),(None,None))
            local=Path(tmp)/"signing.local"
            local.write_text("# private\nLAYOUTKEEPER_TEAM_ID=TEAM1\nLAYOUTKEEPER_SIGNING_IDENTITY=Apple Development: Someone (ABC)\n")
            self.assertEqual(installer.signing_expectations({},local),("TEAM1","Apple Development: Someone (ABC)"))
            self.assertEqual(installer.signing_expectations({"LAYOUTKEEPER_TEAM_ID":"ENV","LAYOUTKEEPER_SIGNING_IDENTITY":"X"},local),("ENV","X"))

    def testAnyRunningSpacePortBlocksDeployment(self):
        self.old()
        with patch.object(installer,"identity",return_value="stable"),patch.object(installer,"read_running_bundles",return_value=["/tmp/other/LayoutKeeper.app"]):
            with self.assertRaisesRegex(ValueError,"running"):
                installer.promote(self.candidate,self.installed,dry_run=False)
        self.assertEqual((self.installed/"Contents/MacOS/LayoutKeeper").read_bytes(),b"old")

    def testChangedIdentityRequiresExplicitAcceptance(self):
        self.old()
        with patch.object(installer,"identity",side_effect=["new","old"]),patch.object(installer,"read_running_bundles",return_value=[]):
            with self.assertRaisesRegex(ValueError,"identity changed"):
                installer.promote(self.candidate,self.installed,dry_run=False)
        self.assertEqual((self.installed/"Contents/MacOS/LayoutKeeper").read_bytes(),b"old")

    def testSuccessfulPromotionKeepsRecoverablePreviousBundle(self):
        self.old()
        with patch.object(installer,"identity",return_value="stable"),patch.object(installer,"read_running_bundles",return_value=[]):
            report=installer.promote(self.candidate,self.installed,dry_run=False)
        self.assertEqual((self.installed/"Contents/MacOS/LayoutKeeper").read_bytes(),b"new")
        self.assertEqual((Path(report["backup"])/"Contents/MacOS/LayoutKeeper").read_bytes(),b"old")

    def testCopyVerificationFailureLeavesInstalledBundleUntouched(self):
        self.old()
        with patch.object(installer,"identity",side_effect=["stable","stable",ValueError("copy invalid")]),patch.object(installer,"read_running_bundles",return_value=[]):
            with self.assertRaisesRegex(ValueError,"copy invalid"):
                installer.promote(self.candidate,self.installed,dry_run=False)
        self.assertEqual((self.installed/"Contents/MacOS/LayoutKeeper").read_bytes(),b"old")

    def testProcessStartedDuringStagingBlocksReplacement(self):
        self.old()
        with patch.object(installer,"identity",return_value="stable"),patch.object(installer,"read_running_bundles",side_effect=[[],["/tmp/other/LayoutKeeper.app"]]):
            with self.assertRaisesRegex(ValueError,"running"):
                installer.promote(self.candidate,self.installed,dry_run=False)
        self.assertEqual((self.installed/"Contents/MacOS/LayoutKeeper").read_bytes(),b"old")

    def testLayoutMigrationNeverOverwritesAnExistingRecord(self):
        source=self.root/"Layouts/screens"
        target=self.root/"support/Layouts/screens"
        source.mkdir(parents=True); target.mkdir(parents=True)
        (source/"same.json").write_text("old record")
        (source/"new.json").write_text("new record")
        (target/"same.json").write_text("current record")
        self.assertEqual(installer.migrate_layouts(source.parent,target.parent),1)
        self.assertEqual((target/"same.json").read_text(),"current record")
        self.assertEqual((target/"new.json").read_text(),"new record")

if __name__=="__main__": unittest.main()
