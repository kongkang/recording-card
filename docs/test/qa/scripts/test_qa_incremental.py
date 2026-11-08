import json
import pathlib
import unittest

from qa_audit import AuditError
from qa_incremental import audit_incremental

FIXTURE = pathlib.Path(__file__).resolve().parent.parent / "fixtures/incremental_evidence.fixture.json"


class IncrementalAuditTest(unittest.TestCase):
    def setUp(self):
        self.data = json.loads(FIXTURE.read_text())

    def rejected(self, pattern):
        with self.assertRaisesRegex(AuditError, pattern):
            audit_incremental(self.data)

    def test_abc_bcd_repeat_bcd_is_idempotent_and_remains_fixture(self):
        result = audit_incremental(self.data)
        self.assertEqual(result["stable_records"], 4)
        self.assertEqual(result["evidence_kind"], "fixture")

    def test_repeat_window_must_not_duplicate_final_records(self):
        self.data["final_record_ids"].append("B")
        self.rejected("duplicate/lost")

    def test_overlap_source_must_stay_stable(self):
        self.data["windows"][1]["source_map"]["B"] = "new-source-B"
        self.rejected("source id changed")

    def test_window_output_cannot_leak_out_of_bounds_record(self):
        self.data["windows"][1]["result_ids"].append("A")
        self.rejected("out-of-bounds")

    def test_raw_cloud_output_cannot_overwrite_original(self):
        self.data["raw_after_sha256"]["B"] = "0" * 64
        self.rejected("raw was changed")

    def test_cloud_raw_write_flag_fails_even_if_hashes_unchanged(self):
        self.data["cloud_writes_raw"] = True
        self.rejected("cloud output contaminated")

    def test_silence_stage_must_not_exceed_source(self):
        self.data["silence_stages"][0]["end_ms"] = 120001
        self.rejected("outside source")

    def test_silence_stage_must_not_overlap(self):
        self.data["silence_stages"][1]["start_ms"] = 44000
        self.rejected("overlap/out of order")

    def test_silence_cannot_be_just_timer_claim(self):
        self.data["silence_stages"][0]["boundary_basis"] = "timer"
        self.rejected("without detector evidence")

    def test_three_views_must_have_one_source(self):
        self.data["views"][0]["polished_source_id"] = "source-B"
        self.rejected("different sources")

    def test_manual_summary_must_use_selected_polished(self):
        self.data["manual_summary"]["used_polished_record_ids"] = ["A"]
        self.rejected("selected polished")

    def test_manual_summary_must_use_existing_summary(self):
        self.data["manual_summary"]["used_existing_summary_ids"] = []
        self.rejected("existing summary input")

    def test_manual_summary_cannot_label_raw_as_polished(self):
        self.data["manual_summary"]["used_raw_as_polished"] = True
        self.rejected("substituted raw")

    def test_metadata_unknown_emotion_cannot_be_invented(self):
        self.data["metadata"][0]["emotion"]["value"] = "happy"
        self.rejected("must not fabricate")

    def test_speaker_identity_cannot_be_claimed_verified(self):
        self.data["metadata"][0]["speaker"]["uncertain"] = False
        self.rejected("verified identity/fact")

    def test_time_cannot_be_model_invented(self):
        self.data["metadata"][0]["time"]["basis"] = "inferred"
        self.rejected("not backed by source")


if __name__ == "__main__":
    unittest.main(verbosity=2)
