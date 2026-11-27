from __future__ import annotations
import json, sys, tempfile, unittest, zipfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from skin_package_engine import SkinPackageError, prepare_package, verify_operation, restore_original, repair_operation
class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.workspace = self.root / "work"
        self.package = self.root / "sample.zip"
        with zipfile.ZipFile(self.package, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("Sample/hero.unity3d", b"UnityFS\x00sample data")
            z.writestr("Sample/recipe.properties", "name=sample\n")
            z.writestr("Sample/metadata.json", json.dumps({"name":"sample"}))
    def tearDown(self): self.tmp.cleanup()
    def test_prepare_and_verify(self):
        r = prepare_package(self.package, self.workspace)
        self.assertEqual(r["report"]["unityBundleCount"], 1)
        self.assertTrue(verify_operation(r["operationId"], self.workspace)["ok"])
    def test_restore_exact_original(self):
        r = prepare_package(self.package, self.workspace)
        out = self.root / "restore.zip"
        restore_original(r["operationId"], self.workspace, out)
        self.assertEqual(out.read_bytes(), self.package.read_bytes())
    def test_repair_from_backup(self):
        r = prepare_package(self.package, self.workspace)
        bad = Path(r["operationPath"]) / "source" / "Sample" / "recipe.properties"
        bad.write_text("damaged")
        self.assertFalse(verify_operation(r["operationId"], self.workspace)["ok"])
        repair_operation(r["operationId"], self.workspace)
        self.assertTrue(verify_operation(r["operationId"], self.workspace)["ok"])
    def test_zip_traversal_refused(self):
        bad = self.root / "bad.zip"
        with zipfile.ZipFile(bad, "w") as z: z.writestr("../bad.txt", "x")
        with self.assertRaises(SkinPackageError): prepare_package(bad, self.workspace)
        self.assertFalse((self.root / "bad.txt").exists())
    def test_case_collision_refused(self):
        bad = self.root / "case.zip"
        with zipfile.ZipFile(bad, "w") as z:
            z.writestr("Skin/A.unity3d", b"UnityFS\x00a")
            z.writestr("skin/a.unity3d", b"UnityFS\x00b")
        with self.assertRaises(SkinPackageError): prepare_package(bad, self.workspace)
    def test_zip_without_unity_refused(self):
        bad = self.root / "plain.zip"
        with zipfile.ZipFile(bad, "w") as z: z.writestr("readme.txt", "no assets")
        with self.assertRaises(SkinPackageError): prepare_package(bad, self.workspace)
if __name__ == "__main__": unittest.main(verbosity=2)
