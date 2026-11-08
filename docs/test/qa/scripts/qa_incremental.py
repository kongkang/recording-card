#!/usr/bin/env python3
"""Offline supplemental QA evidence oracle, not a production pipeline API."""
import argparse
import json
import pathlib
import re

from qa_audit import AuditError, require


def audit_incremental(data):
    require(data.get("schema_version") == 1, "unknown incremental schema")
    require(data.get("evidence_kind") in {"fixture", "automated_fake", "device"},
            "missing incremental evidence level")
    raw_before = data.get("raw_before_sha256", {})
    raw_after = data.get("raw_after_sha256", {})
    require(raw_before and raw_before == raw_after, "raw was changed/overwritten")
    require(all(re.fullmatch(r"[0-9a-f]{64}", value) for value in raw_before.values()),
            "raw integrity evidence missing")
    require(data.get("cloud_writes_raw") is False, "cloud output contaminated raw")
    known = set(raw_before)
    stable = {}
    seen = set()
    for window in data.get("windows", []):
        inputs, results = window.get("input_ids", []), window.get("result_ids", [])
        require(inputs and len(inputs) == len(set(inputs)) and set(inputs) <= known,
                "invalid window inputs")
        require(len(results) == len(set(results)) and set(results) == set(inputs),
                "window lost/duplicated/out-of-bounds record")
        source_map = window.get("source_map", {})
        require(set(source_map) == set(inputs), "window source map incomplete")
        for identifier, source in source_map.items():
            require(isinstance(source, str) and source, "source id missing")
            require(identifier not in stable or stable[identifier] == source,
                    "overlap source id changed")
            stable[identifier] = source
        seen.update(results)
    require(seen, "no window evidence")
    final = data.get("final_record_ids", [])
    require(len(final) == len(set(final)) and set(final) == seen,
            "final records duplicate/lost after repeated window")
    intervals = data.get("record_intervals", {})
    last_end = {}
    for stage in data.get("silence_stages", []):
        identifier = stage.get("record_id")
        require(identifier in known and identifier in intervals, "stage has no stable source")
        outer = intervals[identifier]
        start, end = stage.get("start_ms"), stage.get("end_ms")
        require(type(start) is int and type(end) is int and outer[0] <= start < end <= outer[1],
                "stage outside source interval")
        require(start >= last_end.get(identifier, outer[0]), "stages overlap/out of order")
        last_end[identifier] = end
        require(stage.get("boundary_basis") == "detected_silence" and
                type(stage.get("silence_ms")) is int and stage["silence_ms"] > 0,
                "stage claims silence without detector evidence")
    for view in data.get("views", []):
        identifier = view.get("record_id")
        require(identifier in stable, "view record missing")
        require(all(view.get(key) == stable[identifier] for key in
                    ["raw_source_id", "polished_source_id", "summary_source_id"]),
                "three views point to different sources")
    manual = data.get("manual_summary")
    if manual is not None:
        selected = manual.get("selected_record_ids", [])
        polished = manual.get("used_polished_record_ids", [])
        require(selected and len(selected) == len(set(selected)) and set(selected) <= known,
                "manual summary illegal selection")
        require(len(polished) == len(set(polished)) and set(polished) == set(selected),
                "manual summary must use selected polished text")
        existing = manual.get("existing_summary_ids", [])
        used = manual.get("used_existing_summary_ids", [])
        require(len(existing) == len(set(existing)) and len(used) == len(set(used)) and
                set(existing) == set(used), "manual summary lost existing summary input")
        require(manual.get("used_raw_as_polished") is False,
                "manual summary substituted raw for polished")
    for record in data.get("metadata", []):
        require(record.get("record_id") in known, "metadata source missing")
        for key in ["emotion", "speaker", "time"]:
            field = record.get(key, {})
            basis = field.get("basis")
            value = field.get("value")
            require(basis in {"unknown", "inferred", "measured", "device", "asr"},
                    "metadata provenance missing")
            if basis == "unknown":
                require(value is None, "unknown metadata must not fabricate value")
            if key in {"emotion", "speaker"} and value is not None:
                require(basis == "inferred" and field.get("uncertain") is True,
                        "speaker/emotion must not claim verified identity/fact")
            if key == "time" and value is not None:
                require(basis in {"measured", "device", "asr"}, "time is not backed by source evidence")
    return {"evidence_kind": data["evidence_kind"], "stable_records": len(seen),
            "meaning": "offline evidence shape only; raw/hash/silence/provenance claims need actual pipeline capture"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest")
    args = parser.parse_args()
    try:
        result = audit_incremental(json.loads(pathlib.Path(args.manifest).read_text()))
        print(json.dumps({"ok": True, "result": result}, ensure_ascii=False, indent=2))
    except (AuditError, OSError, ValueError, TypeError, KeyError) as error:
        print(json.dumps({"ok": False, "error": str(error) if isinstance(error, AuditError) else type(error).__name__}))
        raise SystemExit(1)
