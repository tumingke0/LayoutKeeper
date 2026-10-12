#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 LayoutKeeper contributors
import importlib.util
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec=importlib.util.spec_from_file_location("gate",Path(__file__).with_name("privacy-gate.py"))
gate=importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

ENV={"USER":"fakeuser","HOME":"/home/fakeuser"}

class PrivacyGateTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.root=Path(self.tmp.name)
        self.app=self.root/"Fixture.app"
        (self.app/"Contents/MacOS").mkdir(parents=True); (self.app/"Contents/Resources").mkdir()
        (self.app/"Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":"local.fixture","NSHumanReadableCopyright":"GPL-3.0-only"}))
        (self.app/"Contents/Resources/readme.txt").write_text("hello, contact 1+someone@users.noreply.github.com\n")
        self.terms=self.root/"privacy-terms.local"; self.terms.write_text("# comment\nsecretword\nexample-mail.test\n")
        self.signing=self.root/"signing.local"; self.signing.write_text("# private\nLAYOUTKEEPER_TEAM_ID=TEAM123456\n")
    def tearDown(self): self.tmp.cleanup()
    def run_gate(self,*paths):
        with patch.dict("os.environ",ENV,clear=True):
            return gate.main([*map(str,paths),"--terms-file",str(self.terms),"--signing-file",str(self.signing)])
    def leak(self,rel,content: bytes):
        p=self.app/rel; p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes(content)

    def testCleanBundlePasses(self): self.assertEqual(self.run_gate(self.app),0)
    def testHomePathFails(self):
        self.leak("Contents/Resources/a.txt",b"/Users/somebody/project/main.swift"); self.assertEqual(self.run_gate(self.app),1)
    def testCurrentUserAndHomeFail(self):
        self.leak("Contents/Resources/a.txt",b"built by FakeUser"); self.assertEqual(self.run_gate(self.app),1)
        self.leak("Contents/Resources/a.txt",b"/home/fakeuser/x"); self.assertEqual(self.run_gate(self.app),1)
    def testPrivateTermsAndSigningValuesFail(self):
        self.leak("Contents/Resources/a.txt",b"..SecretWord.."); self.assertEqual(self.run_gate(self.app),1)
        self.leak("Contents/Resources/a.txt",b"team TEAM123456"); self.assertEqual(self.run_gate(self.app),1)
    def testUnlistedEmailFailsInPlist(self):
        (self.app/"Contents/Info.plist").write_bytes(plistlib.dumps({"Author":"me@example-mail.org"})); self.assertEqual(self.run_gate(self.app),1)
    def testAssetScaleNamesAreNotEmails(self):
        self.leak("Contents/Resources/Assets.car",b"icon_16x16@2x.png icon_512x512@2x.png"); self.assertEqual(self.run_gate(self.app),0)
    def testLeakInsideMachOBinaryFails(self):
        if not shutil.which("cc"): self.skipTest("no C compiler")
        src=self.root/"leak.c"; src.write_text('const char *p="/Users/somebody/leak"; int main(void){return p[0];}\n')
        subprocess.run(["cc","-o",str(self.app/"Contents/MacOS/Fixture"),str(src)],check=True)
        self.assertEqual(self.run_gate(self.app),1)
        src.write_text('int main(void){return 0;}\n')
        subprocess.run(["cc","-o",str(self.app/"Contents/MacOS/Fixture"),str(src)],check=True)
        subprocess.run(["strip","-S",str(self.app/"Contents/MacOS/Fixture")],check=True)
        self.assertEqual(self.run_gate(self.app),0)
    def testFindingsNeverPrintPrivateTerms(self):
        self.leak("Contents/Resources/a.txt",b"secretword TEAM123456")
        with patch("sys.stderr") as err: self.assertEqual(self.run_gate(self.app),1)
        printed="".join(c.args[0] for c in err.write.call_args_list)
        self.assertIn("a.txt",printed); self.assertNotIn("secretword",printed.lower()); self.assertNotIn("TEAM123456",printed)
    def testDmgContentsAreScanned(self):
        if not shutil.which("hdiutil"): self.skipTest("no hdiutil")
        self.leak("Contents/Resources/a.txt",b"/Users/somebody")
        dmg=self.root/"f.dmg"
        subprocess.run(["hdiutil","create","-quiet","-srcfolder",str(self.app),"-format","UDZO",str(dmg)],check=True)
        self.assertEqual(self.run_gate(dmg),1)

if __name__=="__main__":
    unittest.main()
