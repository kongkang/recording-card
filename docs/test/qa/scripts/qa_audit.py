#!/usr/bin/env python3
"""Offline QA helpers. No service imports, network, BLE, login, or writes to source.

These checks validate evidence shape / known-risk source patterns, not runtime
truth. A fixture report is NEVER real-device acceptance. Source check clean means
no known patterns found, not proof of FFI safety or correct OAuth.
"""
from __future__ import annotations

import argparse
import hashlib
import html.parser
import json
import pathlib
import re
import struct
import subprocess
import xml.etree.ElementTree as ET
import zipfile
import zlib


class AuditError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise AuditError(message)


def load_json(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def sha256(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def audit_flow(data):
    """Validate v1 QA evidence (not a service DTO). Returns evidence level."""
    require(data.get("schema_version") == 1, "unknown evidence schema")
    level = data.get("evidence_kind")
    require(level in {"fixture", "automated_fake", "device"}, "missing evidence level")
    defaults = data.get("defaults", {})
    require(defaults.get("auth") == "signed_out", "default auth must fail closed")
    require(defaults.get("events_count") == 0, "production default must not load seed")
    require(defaults.get("mock_enabled") is False, "production default mock enabled")
    records = data.get("records", [])
    require(isinstance(records, list), "records must be a list")
    by_id = {}
    for record in records:
        identifier = record.get("id")
        require(isinstance(identifier, str) and identifier and identifier not in by_id,
                "missing/duplicate recording id")
        start, end = record.get("start_ms"), record.get("end_ms")
        require(type(start) is int and type(end) is int and 0 <= start < end,
                "invalid recording interval")
        require(isinstance(record.get("raw_text"), str), "original transcript missing")
        by_id[identifier] = record
    selected = data.get("selected_ids", [])
    require(isinstance(selected, list) and all(isinstance(x, str) for x in selected),
            "invalid selection")
    require(len(selected) == len(set(selected)) and set(selected) <= by_id.keys(),
            "illegal selection ids")
    summary = data.get("summary")
    if summary is not None:
        sources = summary.get("source_ids", [])
        require(isinstance(sources, list) and sources and
                all(isinstance(x, str) for x in sources), "summary without source ids")
        require(len(sources) == len(set(sources)) and set(sources) <= set(selected),
                "summary includes unselected/fabricated source")
        for point in summary.get("points", []):
            refs = point.get("refs", [])
            require(isinstance(refs, list) and refs, "point without source")
            for ref in refs:
                record = by_id.get(ref.get("event_id"))
                require(record is not None and ref.get("event_id") in sources,
                        "illegal point source")
                start, end = ref.get("start_ms"), ref.get("end_ms")
                require(type(start) is int and type(end) is int and
                        record["start_ms"] <= start < end <= record["end_ms"],
                        "point interval outside recording")
    auth = data.get("auth_attempt")
    if auth and auth.get("state") == "signed_in":
        require(auth.get("method") == "oauth_pkce", "non-OAuth login success")
        require(auth.get("pkce_method") == "S256" and auth.get("state_verified") is True,
                "unverified PKCE/state")
        require(auth.get("profile_verified") is True and auth.get("secure_storage") is True,
                "unverified identity or insecure session")
    asr = data.get("asr")
    if asr:
        require(asr.get("mode") == "local", "unapproved ASR mode")
        if not asr.get("configured"):
            require(asr.get("state") == "failed" and bool(asr.get("error")),
                    "missing ASR model must error, not succeed/empty text")
    receipts = data.get("receipts", {})
    require(isinstance(receipts, dict), "receipts must be a map")
    seen = set()
    for task in data.get("tasks", []):
        identifier = task.get("id")
        require(isinstance(identifier, str) and identifier and identifier not in seen,
                "duplicate/missing task id")
        seen.add(identifier)
        state = task.get("state")
        require(state in {"queued", "running", "succeeded", "failed", "cancelled"},
                "unknown task state")
        progress = task.get("progress")
        require(progress is None or (type(progress) in {int, float} and 0 <= progress <= 100),
                "invalid progress; unknown must be null, not invented ETA")
        if state == "failed":
            require(bool(task.get("error")), "failure without readable error")
        if state == "succeeded":
            receipt = receipts.get(task.get("outcome_ref"), {})
            require(receipt.get("confirmed") is True and receipt.get("origin") in
                    {"gateway", "repository", "model_gateway", "export_file"},
                    "success without a confirmed operation receipt")
            if level == "device":
                require(receipt.get("evidence_kind") == "device", "fake receipt claimed as device")
            if task.get("kind") == "wifi":
                require(receipt.get("connected") is True, "Wi-Fi success without connection result")
            if task.get("kind") == "ota":
                require(receipt.get("version_verified") is True,
                        "OTA success without post-reconnect version")
        if task.get("operation") == "ble_take":
            require(task.get("allow_destructive") is True or state in {"failed", "cancelled"},
                    "BLE take attempted without explicit destructive authorization")
        if task.get("kind") == "ota" and level == "device" and state in {"running", "succeeded"}:
            require(task.get("allow_hardware_write") is True,
                    "real OTA lacks precise separate authorization")
    return {"evidence_kind": level, "record_count": len(records), "task_count": len(seen),
            "meaning": "evidence structure valid; caller claims are not independently verified"}


class TextExtractor(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.text = []
        self.tags = []
        self.unsafe = False

    def handle_starttag(self, tag, attrs):
        self.tags.append(tag)
        if tag in {"script", "iframe", "object"} or any(k.startswith("on") for k, _ in attrs):
            self.unsafe = True

    def handle_data(self, data):
        self.text.append(data)


def audit_png(content):
    require(content.startswith(b"\x89PNG\r\n\x1a\n"), "bad PNG signature")
    offset, chunks, dimensions, image_data = 8, [], None, b""
    channels = None
    while offset < len(content):
        require(offset + 12 <= len(content), "truncated PNG chunk")
        size = struct.unpack(">I", content[offset:offset + 4])[0]
        kind = content[offset + 4:offset + 8]
        end = offset + 12 + size
        require(end <= len(content), "truncated PNG data")
        payload = content[offset + 8:offset + 8 + size]
        crc = struct.unpack(">I", content[offset + 8 + size:end])[0]
        require(zlib.crc32(kind + payload) & 0xffffffff == crc, "PNG CRC mismatch")
        chunks.append(kind)
        if kind == b"IHDR":
            require(size == 13, "bad PNG IHDR")
            dimensions = struct.unpack(">II", payload[:8])
            depth, color, compression, filtering, interlace = payload[8:]
            channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color)
            require(depth == 8 and channels is not None and compression == 0 and
                    filtering == 0 and interlace == 0,
                    "PNG variant unsupported: manually verify palette/interlaced/high-bit image")
        if kind == b"IDAT":
            image_data += payload
        offset = end
        if kind == b"IEND":
            break
    require(chunks and chunks[0] == b"IHDR" and chunks[-1] == b"IEND" and
            dimensions and min(dimensions) > 0 and image_data and offset == len(content),
            "PNG lacks image dimensions/data/end")
    try:
        pixels = zlib.decompress(image_data)
    except zlib.error as error:
        raise AuditError("PNG corrupt compressed image") from error
    stride = 1 + dimensions[0] * channels
    require(len(pixels) == dimensions[1] * stride, "PNG invalid pixel scanline length")
    require(all(pixels[offset] <= 4 for offset in range(0, len(pixels), stride)),
            "PNG invalid scanline filter")
    return dimensions


def audit_exports(manifest, base):
    """Structural checks + parsed content; PNG semantic content needs visual review."""
    require(manifest.get("schema_version") == 1, "unknown export schema")
    require(manifest.get("evidence_kind") in {"fixture", "automated_fake", "device"},
            "missing export evidence level")
    files = manifest.get("formats", {})
    require(set(files) == {"html", "markdown", "pdf", "png", "docx"}, "need exactly five formats")
    needles = manifest.get("required_text", [])
    require(isinstance(needles, list) and needles and all(isinstance(x, str) and x for x in needles),
            "required_text must contain known title/body/source fragments")
    result = {}
    for kind, relative in files.items():
        path = (pathlib.Path(base) / relative).resolve()
        require(path.is_file(), f"missing {kind} file")
        content = path.read_bytes()
        require(content, f"empty {kind} file")
        text = None
        if kind == "markdown":
            text = content.decode("utf-8")
            require(re.search(r"^#{1,6}\s+", text, re.M), "Markdown has no heading")
        elif kind == "html":
            parser = TextExtractor()
            parser.feed(content.decode("utf-8"))
            require("html" in parser.tags and "body" in parser.tags, "HTML is not a complete document")
            require(not parser.unsafe, "HTML has active script/event/object content")
            text = " ".join(parser.text)
        elif kind == "docx":
            try:
                with zipfile.ZipFile(path) as archive:
                    require(archive.testzip() is None, "DOCX corrupt ZIP entry")
                    require({"[Content_Types].xml", "_rels/.rels", "word/document.xml"} <=
                            set(archive.namelist()), "DOCX missing OOXML parts")
                    types = ET.fromstring(archive.read("[Content_Types].xml"))
                    require(any(node.attrib.get("PartName") == "/word/document.xml" and
                                "wordprocessingml.document.main+xml" in node.attrib.get("ContentType", "")
                                for node in types), "DOCX missing main content type")
                    relationships = ET.fromstring(archive.read("_rels/.rels"))
                    require(any(node.attrib.get("Target") == "word/document.xml" and
                                node.attrib.get("Type", "").endswith("/officeDocument")
                                for node in relationships), "DOCX missing main relationship")
                    document = ET.fromstring(archive.read("word/document.xml"))
                    require(document.tag == "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}document",
                            "DOCX root is not WordprocessingML")
                    text = " ".join(document.itertext())
            except (zipfile.BadZipFile, ET.ParseError, KeyError) as error:
                raise AuditError("invalid DOCX package") from error
        elif kind == "pdf":
            require(content.startswith(b"%PDF-") and b"%%EOF" in content[-1024:], "bad PDF signature/end")
            try:
                process = subprocess.run(["pdftotext", str(path), "-"], capture_output=True,
                                         timeout=30, check=False)
            except FileNotFoundError as error:
                raise AuditError("pdftotext missing; PDF content unverified (install Poppler on Mac)") from error
            require(process.returncode == 0, "PDF cannot be parsed by pdftotext")
            text = process.stdout.decode("utf-8")
        else:
            width, height = audit_png(content)
            result[kind] = {"bytes": len(content), "sha256": sha256(path), "width": width,
                            "height": height, "visual_content": "NOT_VERIFIED"}
            continue
        normalized = re.sub(r"\s+", "", text)
        require(all(re.sub(r"\s+", "", needle) in normalized for needle in needles),
                f"{kind} missing required text/source")
        result[kind] = {"bytes": len(content), "sha256": sha256(path), "text_content": "checked"}
    return {"evidence_kind": manifest["evidence_kind"], "files": result,
            "acceptance": "structural/text checks only; PNG visual review and native share remain required"}


def audit_models(manifest, base):
    require(manifest.get("schema_version") == 1 and manifest.get("files"), "empty model manifest")
    result = []
    for item in manifest["files"]:
        path = pathlib.Path(base) / item["path"]
        require(path.is_file(), "ASR file missing")
        require(type(item.get("size_bytes")) is int and item["size_bytes"] > 0,
                "ASR expected size missing")
        require(re.fullmatch(r"[0-9a-f]{64}", item.get("sha256", "")) is not None,
                "ASR expected checksum missing")
        require(path.stat().st_size == item["size_bytes"], "ASR size mismatch")
        require(sha256(path) == item["sha256"], "ASR checksum mismatch")
        result.append({"name": path.name, "size_bytes": path.stat().st_size})
    return {"files": result, "native_inference": "NOT_RUN"}


def strip_comments(text):
    # Narrow detector only, NOT a Dart/Rust parser. Findings need human review.
    return re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)


def audit_source(root):
    root = pathlib.Path(root)
    findings = []
    rules = [
        ("AUTH-LOCAL", "app/lib/services/auth_service.dart", r"session\s*=\s*AuthSession\(account:\s*a,", "BLOCKER", "legacy nonempty-password session assignment"),
        ("SEED-DEFAULT", "app/lib/core/store/app_store.dart", r"events\s*\?\?\s*seedEvents", "BLOCKER", "default production seed"),
        ("SEED-SUMMARY", "app/lib/core/store/app_store.dart", r"fillSummaryContent\s*\(", "BLOCKER", "seed summary result fallback"),
        ("MOCK-DEFAULT", "app/lib/core/store/device_store.dart", r"\?\?\s*const\s+MockCardGateway\(", "BLOCKER", "default mock device fallback"),
        ("FFI-TEMP", "app/rust/card_bridge/src/lib.rs", r"cb\(user_data,\s*json\.as_ptr\(\)\)", "BLOCKER", "temporary CString posted to asynchronous Dart listener"),
        ("FFI-FREE-NOOP", "app/rust/card_bridge/src/lib.rs", r"fn\s+card_bridge_free_string\([^)]*\)\s*\{\s*\}", "BLOCKER", "native string release is no-op"),
        ("SYNC-TIMER", "app/lib/core/store/device_store.dart", r"Timer\(const Duration\(milliseconds: 900\)", "BLOCKER", "known timer-driven sync success"),
        ("WIFI-TIMER", "app/lib/core/store/device_store.dart", r"wifiLast\s*=\s*(?:n|r\.name);", "REVIEW", "known local Wi-Fi completion assignment; verify native result gate"),
        ("OTA-TIMER", "app/lib/core/store/device_store.dart", r"fwDone\s*=\s*true;", "REVIEW", "OTA completion assignment; verify signed package/authorization/version gate"),
    ]
    for identifier, relative, pattern, severity, message in rules:
        path = root / relative
        if not path.is_file():
            findings.append({"id": identifier, "severity": "UNVERIFIED", "path": relative,
                             "reason": "source moved/missing; inspect new implementation"})
            continue
        if re.search(pattern, strip_comments(path.read_text())):
            findings.append({"id": identifier, "severity": severity, "path": relative, "reason": message})
    modules = ["app/lib/services/model_gateway/model_gateway.dart", "app/lib/services/recordings",
               "app/lib/services/transcription", "app/lib/services/analysis", "app/lib/services/export"]
    for relative in modules:
        if not (root / relative).exists():
            findings.append({"id": "MISSING-MODULE", "severity": "UNVERIFIED", "path": relative,
                             "reason": "not integrated; do not invent service tests/API"})
    return {"findings": findings,
            "meaning": "heuristic known-risk detector only; zero findings is NOT full acceptance"}


def audit_baseline(root, inventory, require_legacy_hash=False):
    root = pathlib.Path(root)
    for relative, expected in inventory["protected"].items():
        require(sha256(root / relative) == expected, f"read-only prototype changed: {relative}")
    count = 0
    for item in inventory["legacy_tests"]:
        path = root / item["path"]
        text = path.read_text()
        names = re.findall(r"\btest(?:Widgets)?\(\s*'([^']+)'", text)
        require(set(item["names"]) <= set(names), f"legacy test deleted/renamed: {item['path']}")
        if require_legacy_hash:
            require(sha256(path) == item["sha256"], f"legacy file changed: {item['path']}")
        count += len(item["names"])
    return {"protected_prototype": "unchanged", "legacy_names_retained": count,
            "note": "names/hash retention is not assertion quality or execution evidence"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", help="optional JSON report (never include secrets)")
    sub = parser.add_subparsers(dest="command", required=True)
    source = sub.add_parser("source")
    source.add_argument("--root", required=True)
    source.add_argument("--strict", action="store_true", help="nonzero on any finding")
    baseline = sub.add_parser("baseline")
    baseline.add_argument("--root", required=True)
    baseline.add_argument("--inventory", required=True)
    baseline.add_argument("--require-legacy-hash", action="store_true")
    for name in ["flow", "exports", "models"]:
        child = sub.add_parser(name)
        child.add_argument("manifest")
        if name != "flow":
            child.add_argument("--base", help="base for relative artifact/model paths; default manifest directory")
    args = parser.parse_args(argv)
    code = 0
    try:
        if args.command == "source":
            result = audit_source(args.root)
            code = int(args.strict and bool(result["findings"]))
        elif args.command == "baseline":
            result = audit_baseline(args.root, load_json(args.inventory), args.require_legacy_hash)
        else:
            manifest = load_json(args.manifest)
            if args.command == "flow":
                result = audit_flow(manifest)
            else:
                base = args.base or str(pathlib.Path(args.manifest).resolve().parent)
                result = {"exports": audit_exports, "models": audit_models}[args.command](manifest, base)
        report = {"tool": "qa_audit", "command": args.command, "ok": code == 0, "result": result}
    except (AuditError, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        code = 1
        # Never print malformed input content/token/paths supplied in evidence.
        report = {"tool": "qa_audit", "command": args.command, "ok": False,
                  "error": str(error) if isinstance(error, AuditError) else type(error).__name__}
    serialized = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    print(serialized, end="")
    if args.output:
        pathlib.Path(args.output).write_text(serialized, encoding="utf-8")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
