#!/usr/bin/env python3
"""Offline tests for the QA oracles; never exercise actual auth/model/hardware."""
import copy
import hashlib
import json
import pathlib
import tempfile
import unittest
import zipfile

import qa_audit as qa
from generate_qa_specimens import write_specimens, make_png

FIXTURE = pathlib.Path(__file__).resolve().parent.parent / "fixtures/flow_evidence.fixture.json"


class FlowAuditTest(unittest.TestCase):
    def setUp(self):
        self.data = json.loads(FIXTURE.read_text())

    def rejected(self, fragment):
        with self.assertRaisesRegex(qa.AuditError, fragment):
            qa.audit_flow(self.data)

    def test_valid_fixture_label_is_preserved(self):
        self.assertEqual(qa.audit_flow(self.data)["evidence_kind"], "fixture")

    def test_empty_records_with_no_summary_are_legal(self):
        self.data.update(records=[], selected_ids=[], summary=None)
        self.assertEqual(qa.audit_flow(self.data)["record_count"], 0)

    def test_default_seed_is_rejected(self):
        self.data["defaults"]["events_count"] = 6
        self.rejected("must not load seed")

    def test_default_mock_is_rejected(self):
        self.data["defaults"]["mock_enabled"] = True
        self.rejected("default mock enabled")

    def test_default_signed_in_is_rejected(self):
        self.data["defaults"]["auth"] = "signed_in"
        self.rejected("fail closed")

    def test_password_cannot_create_session(self):
        self.data["auth_attempt"]["state"] = "signed_in"
        self.rejected("non-OAuth")

    def test_missing_state_or_pkce_is_rejected(self):
        self.data["auth_attempt"] = {"state": "signed_in", "method": "oauth_pkce", "pkce_method": "plain"}
        self.rejected("PKCE/state")

    def test_oauth_fixture_requires_verified_profile_and_storage(self):
        self.data["auth_attempt"] = {"state": "signed_in", "method": "oauth_pkce", "pkce_method": "S256", "state_verified": True}
        self.rejected("unverified identity")

    def test_approved_shape_remains_fixture_not_real_login(self):
        self.data["auth_attempt"] = {"state": "signed_in", "method": "oauth_pkce", "pkce_method": "S256", "state_verified": True, "profile_verified": True, "secure_storage": True}
        self.assertEqual(qa.audit_flow(self.data)["evidence_kind"], "fixture")

    def test_missing_model_cannot_succeed(self):
        self.data["asr"]["state"] = "succeeded"
        self.rejected("missing ASR model")

    def test_duplicate_record_id(self):
        self.data["records"].append(copy.deepcopy(self.data["records"][0]))
        self.rejected("duplicate recording")

    def test_unselected_summary_source(self):
        self.data["summary"]["source_ids"].append("qa-lantern")
        self.rejected("unselected/fabricated")

    def test_fabricated_selection(self):
        self.data["selected_ids"].append("unknown")
        self.rejected("illegal selection")

    def test_empty_summary_sources_rejected(self):
        self.data["summary"]["source_ids"] = []
        self.rejected("summary without source")

    def test_point_out_of_range(self):
        self.data["summary"]["points"][0]["refs"][0]["end_ms"] = 120001
        self.rejected("outside recording")

    def test_fabricated_point_source(self):
        self.data["summary"]["points"][0]["refs"][0]["event_id"] = "unknown"
        self.rejected("illegal point")

    def test_raw_original_required(self):
        del self.data["records"][0]["raw_text"]
        self.rejected("original transcript")

    def test_wifi_no_timer_only_success(self):
        self.data["tasks"][1].update(state="succeeded")
        self.rejected("success without")

    def test_wifi_receipt_requires_connected(self):
        self.data["tasks"][1].update(state="succeeded", outcome_ref="wifi")
        self.data["receipts"]["wifi"] = {"origin": "gateway", "confirmed": True}
        self.rejected("Wi-Fi success without connection")

    def test_ota_version_must_be_verified(self):
        self.data["tasks"][2].update(state="succeeded", outcome_ref="ota")
        self.data["receipts"]["ota"] = {"origin": "gateway", "confirmed": True}
        self.rejected("post-reconnect version")

    def test_ble_take_fails_closed(self):
        self.data["tasks"][3].update(state="running")
        self.rejected("destructive authorization")

    def test_progress_overflow_rejected(self):
        self.data["tasks"][0]["progress"] = 101
        self.rejected("invalid progress")

    def test_fake_receipt_cannot_be_claimed_as_device(self):
        self.data["evidence_kind"] = "device"
        self.rejected("fake receipt")

    def test_actual_ota_authorization_required_in_device_evidence(self):
        self.data["evidence_kind"] = "device"
        self.data["receipts"]["fixture-file"]["evidence_kind"] = "device"
        self.data["tasks"][2]["state"] = "running"
        self.rejected("separate authorization")


class ArtifactAuditTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="qa-audit-")
        self.addCleanup(self.tmp.cleanup)
        self.base = pathlib.Path(self.tmp.name)
        self.manifest = write_specimens(self.base)

    def test_five_real_parser_specimens_not_production_claim(self):
        report = qa.audit_exports(self.manifest, self.base)
        self.assertEqual(len(report["files"]), 5)
        self.assertEqual(report["evidence_kind"], "fixture")
        self.assertEqual(report["files"]["png"]["visual_content"], "NOT_VERIFIED")

    def test_missing_format_is_rejected(self):
        del self.manifest["formats"]["pdf"]
        with self.assertRaisesRegex(qa.AuditError, "exactly five"):
            qa.audit_exports(self.manifest, self.base)

    def test_renamed_text_is_not_pdf(self):
        (self.base / "specimen.pdf").write_text("not PDF")
        with self.assertRaisesRegex(qa.AuditError, "PDF signature"):
            qa.audit_exports(self.manifest, self.base)

    def test_renamed_zip_is_not_docx(self):
        with zipfile.ZipFile(self.base / "specimen.docx", "w") as archive:
            archive.writestr("text.txt", "no Word document")
        with self.assertRaisesRegex(qa.AuditError, "missing OOXML"):
            qa.audit_exports(self.manifest, self.base)

    def test_html_script_is_rejected(self):
        path = self.base / "specimen.html"
        path.write_text(path.read_text().replace("</body>", "<script>alert(1)</script></body>"))
        with self.assertRaisesRegex(qa.AuditError, "active script"):
            qa.audit_exports(self.manifest, self.base)

    def test_truncated_png_is_rejected(self):
        with self.assertRaises(qa.AuditError):
            qa.audit_png(make_png()[:-5])

    def test_png_crc_error_is_rejected(self):
        content = bytearray(make_png())
        content[29] ^= 1
        with self.assertRaisesRegex(qa.AuditError, "CRC"):
            qa.audit_png(bytes(content))

    def test_missing_source_text_is_rejected(self):
        (self.base / "specimen.md").write_text("# QA ORCHID\nTuesday moisture check\n")
        with self.assertRaisesRegex(qa.AuditError, "missing required text/source"):
            qa.audit_exports(self.manifest, self.base)

    def test_model_digest_and_size_are_both_checked(self):
        path = self.base / "test-model.bin"
        path.write_bytes(b"qa-only-placeholder")
        manifest = {"schema_version": 1, "files": [{"path": path.name, "size_bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}]}
        self.assertEqual(qa.audit_models(manifest, self.base)["native_inference"], "NOT_RUN")
        path.write_bytes(b"x" * path.stat().st_size)
        with self.assertRaisesRegex(qa.AuditError, "checksum mismatch"):
            qa.audit_models(manifest, self.base)

    def test_model_size_mismatch_is_rejected(self):
        path = self.base / "test-model.bin"
        path.write_bytes(b"tiny QA specimen")
        manifest = {"schema_version": 1, "files": [{"path": path.name, "size_bytes": path.stat().st_size + 1, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}]}
        with self.assertRaisesRegex(qa.AuditError, "size mismatch"):
            qa.audit_models(manifest, self.base)

    def test_missing_model_is_rejected(self):
        manifest = {"schema_version": 1, "files": [{"path": "missing.onnx", "size_bytes": 1, "sha256": "0" * 64}]}
        with self.assertRaisesRegex(qa.AuditError, "ASR file missing"):
            qa.audit_models(manifest, self.base)


class SourceAuditTest(unittest.TestCase):
    def test_detects_known_baseline_risks_without_executing_app(self):
        root = pathlib.Path(__file__).resolve().parents[4]
        # Portable after cherry-pick: root is the repository owning this script.
        self.assertTrue((root / "app").is_dir())
        report = qa.audit_source(root)
        self.assertIn("meaning", report)
        self.assertIsInstance(report["findings"], list)
        # Do NOT require insecure production patterns to stay present.

    def test_detector_reports_moved_sources_as_unverified(self):
        with tempfile.TemporaryDirectory() as directory:
            report = qa.audit_source(directory)
            self.assertTrue(report["findings"])
            self.assertTrue(all(item["severity"] == "UNVERIFIED" for item in report["findings"]))

    def test_baseline_detector_rejects_prototype_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / "prototype.txt"
            path.write_text("original")
            inventory = {"protected": {"prototype.txt": qa.sha256(path)}, "legacy_tests": []}
            path.write_text("changed")
            with self.assertRaisesRegex(qa.AuditError, "read-only prototype changed"):
                qa.audit_baseline(root, inventory)


if __name__ == "__main__":
    unittest.main(verbosity=2)
