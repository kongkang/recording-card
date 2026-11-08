#!/usr/bin/env python3
"""Generate QA-only format specimens, NOT production ExportService evidence."""
from __future__ import annotations

import argparse
import html
import json
import pathlib
import struct
import zipfile
import zlib
from xml.sax.saxutils import escape

TITLE = "QA ORCHID"
BODY = "Tuesday moisture check"
SOURCE = "qa-orchid 09:10-09:11"
TEXT = f"{TITLE}\n{BODY}\nSource: {SOURCE}"


def png_chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)


def make_png():
    # A small colored image used solely to exercise PNG parsing/CRC checks.
    # It intentionally does NOT claim text completeness/visual export acceptance.
    width, height = 16, 16
    data = b"".join(b"\x00" + bytes([48, 110, 78]) * width for _ in range(height))
    return b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + \
        png_chunk(b"IDAT", zlib.compress(data)) + png_chunk(b"IEND", b"")


def make_pdf():
    # Minimal valid ASCII PDF; precise offsets allow pdftotext to parse it.
    lines = TEXT.splitlines()
    commands = "BT /F1 12 Tf 50 740 Td "
    for index, line in enumerate(lines):
        escaped = line.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
        commands += ("0 -20 Td " if index else "") + f"({escaped}) Tj "
    stream = (commands + "ET\n").encode("ascii")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"endstream",
    ]
    output = b"%PDF-1.4\n"
    offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(output))
        output += f"{index} 0 obj\n".encode() + obj + b"\nendobj\n"
    xref = len(output)
    output += f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode()
    for offset in offsets[1:]:
        output += f"{offset:010d} 00000 n \n".encode()
    output += f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return output


def write_specimens(directory):
    directory = pathlib.Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "specimen.md").write_text(f"# {TITLE}\n\n{BODY}\n\nSource: {SOURCE}\n", encoding="utf-8")
    (directory / "specimen.html").write_text(
        f'<!doctype html><html><head><meta charset="utf-8"><title>{TITLE}</title></head>'
        f'<body><h1>{TITLE}</h1><p>{html.escape(BODY)}</p><p>{SOURCE}</p>'
        '<p>测试字符：&lt;材料&gt; &amp; &quot;纸张&quot;</p></body></html>\n', encoding="utf-8")
    (directory / "specimen.pdf").write_bytes(make_pdf())
    (directory / "specimen.png").write_bytes(make_png())
    namespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    document = f'<w:document xmlns:w="{namespace}"><w:body>' + ''.join(
        f"<w:p><w:r><w:t>{escape(line)}</w:t></w:r></w:p>" for line in TEXT.splitlines()) + '</w:body></w:document>'
    with zipfile.ZipFile(directory / "specimen.docx", "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
        archive.writestr("_rels/.rels", '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
        archive.writestr("word/document.xml", document)
    manifest = {"schema_version": 1, "evidence_kind": "fixture", "required_text": [TITLE, BODY, SOURCE],
                "formats": {"html": "specimen.html", "markdown": "specimen.md", "pdf": "specimen.pdf", "png": "specimen.png", "docx": "specimen.docx"},
                "note": "QA parser specimen only. PNG has no text; semantic content/native sharing NOT tested."}
    (directory / "export_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    write_specimens(args.output_dir)
    print("Generated five QA-only parser specimens; not production export acceptance.")
