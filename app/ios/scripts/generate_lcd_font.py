#!/usr/bin/env python3
"""Generate RCLcdDigital-Regular.ttf — a crisp monospaced 7-segment LCD font.

First-party generated vector TrueType font (no external dependencies) for
Recording Card's Dynamic Island & Lock Screen Live Activity timer display.
All decimal digits ('0'-'9') share an identical 580/1000 UPM advance width
so timer updates never cause horizontal layout jitter.
"""

from __future__ import annotations

import os
import struct
import sys
from pathlib import Path

UPM = 1000
ASCENDER = 780
DESCENDER = -20
LINE_GAP = 0

DIGIT_ADVANCE = 580
COLON_ADVANCE = 250

# 7-segment geometry within 580x760 digit cell
L = 55
R = 525
B = 0
M = 380
T = 760
W = 80
HW = W // 2
G = 13


def _mirror_x(poly: list[tuple[int, int]]) -> list[tuple[int, int]]:
    # Mirror horizontally across x = 290 and reverse order to preserve CW winding.
    return [(DIGIT_ADVANCE - x, y) for x, y in reversed(poly)]


def _mirror_y(poly: list[tuple[int, int]]) -> list[tuple[int, int]]:
    # Mirror vertically across y = 380 and reverse order to preserve CW winding.
    return [(x, T - y) for x, y in reversed(poly)]


SEG_A = [
    (L + G + 16, T),
    (R - G - 16, T),
    (R - G, T - 16),
    (R - W - G, T - W),
    (L + W + G, T - W),
    (L + G, T - 16),
]
SEG_D = _mirror_y(SEG_A)
SEG_G = [
    (L + HW + G, M),
    (L + W + G, M + HW),
    (R - W - G, M + HW),
    (R - HW - G, M),
    (R - W - G, M - HW),
    (L + W + G, M - HW),
]
SEG_F = [
    (L, M + G + 16),
    (L, T - G - 20),
    (L + 12, T - G - 8),
    (L + W, T - W - G - 4),
    (L + W, M + HW + G),
    (L + HW, M + G),
]
SEG_B = _mirror_x(SEG_F)
SEG_E = _mirror_y(SEG_F)
SEG_C = _mirror_x(SEG_E)

SEGMENTS = {
    "A": SEG_A,
    "B": SEG_B,
    "C": SEG_C,
    "D": SEG_D,
    "E": SEG_E,
    "F": SEG_F,
    "G": SEG_G,
}


def _colon_dot(cx: int, cy: int, half: int = 38, cut: int = 8) -> list[tuple[int, int]]:
    # Chamfered square dot (CW winding in Y-up coordinates)
    return [
        (cx - half + cut, cy + half),
        (cx + half - cut, cy + half),
        (cx + half, cy + half - cut),
        (cx + half, cy - half + cut),
        (cx + half - cut, cy - half),
        (cx - half + cut, cy - half),
        (cx - half, cy - half + cut),
        (cx - half, cy + half - cut),
    ]


GLYPH_SPECS: list[tuple[str, int | None, int, list[list[tuple[int, int]]]]] = [
    (".notdef", None, DIGIT_ADVANCE, [SEG_A, SEG_B, SEG_C, SEG_D, SEG_E, SEG_F]),
    ("space", 0x0020, DIGIT_ADVANCE, []),
    ("nbspace", 0x00A0, COLON_ADVANCE, []),
    ("hyphen", 0x002D, DIGIT_ADVANCE, [SEG_G]),
    ("zero", 0x0030, DIGIT_ADVANCE, [SEGMENTS[s] for s in "ABCDEF"]),
    ("one", 0x0031, DIGIT_ADVANCE, [SEGMENTS[s] for s in "BC"]),
    ("two", 0x0032, DIGIT_ADVANCE, [SEGMENTS[s] for s in "ABGED"]),
    ("three", 0x0033, DIGIT_ADVANCE, [SEGMENTS[s] for s in "ABGCD"]),
    ("four", 0x0034, DIGIT_ADVANCE, [SEGMENTS[s] for s in "FGBC"]),
    ("five", 0x0035, DIGIT_ADVANCE, [SEGMENTS[s] for s in "AFGCD"]),
    ("six", 0x0036, DIGIT_ADVANCE, [SEGMENTS[s] for s in "AFGECD"]),
    ("seven", 0x0037, DIGIT_ADVANCE, [SEGMENTS[s] for s in "ABC"]),
    ("eight", 0x0038, DIGIT_ADVANCE, [SEGMENTS[s] for s in "ABCDEFG"]),
    ("nine", 0x0039, DIGIT_ADVANCE, [SEGMENTS[s] for s in "ABCDFG"]),
    ("colon", 0x003A, COLON_ADVANCE, [_colon_dot(125, 525), _colon_dot(125, 235)]),
    ("F", 0x0046, DIGIT_ADVANCE, [SEGMENTS[s] for s in "AFGE"]),
    ("O", 0x004F, DIGIT_ADVANCE, [SEGMENTS[s] for s in "ABCDEF"]),
]


def _encode_glyf_entry(contours: list[list[tuple[int, int]]]) -> tuple[bytes, tuple[int, int, int, int]]:
    if not contours:
        return b"", (0, 0, 0, 0)

    pts = [pt for c in contours for pt in c]
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    xmin, ymin, xmax, ymax = min(xs), min(ys), max(xs), max(ys)

    end_pts: list[int] = []
    idx = -1
    for c in contours:
        idx += len(c)
        end_pts.append(idx)

    # Simple glyph header: numberOfContours, xMin, yMin, xMax, yMax
    out = bytearray(struct.pack(">hhhhh", len(contours), xmin, ymin, xmax, ymax))
    for ep in end_pts:
        out.extend(struct.pack(">H", ep))
    out.extend(struct.pack(">H", 0))  # instructionLength = 0

    # Flags: bit 0 = on-curve (1). Coordinates stored as signed 16-bit deltas.
    out.extend(bytes([0x01] * len(pts)))

    prev_x = 0
    for x, _ in pts:
        out.extend(struct.pack(">h", x - prev_x))
        prev_x = x

    prev_y = 0
    for _, y in pts:
        out.extend(struct.pack(">h", y - prev_y))
        prev_y = y

    while len(out) % 4 != 0:
        out.append(0)
    return bytes(out), (xmin, ymin, xmax, ymax)


def _build_cmap(codepoints: dict[int, int]) -> bytes:
    # Format 4 BMP subtable (platform 0 Unicode & platform 3 Windows BMP)
    items = sorted(codepoints.items())
    segments: list[tuple[int, int, int]] = []
    for cp, gid in items:
        if segments and cp == segments[-1][1] + 1 and (gid - cp) == segments[-1][2]:
            s, _, delta = segments[-1]
            segments[-1] = (s, cp, delta)
        else:
            segments.append((cp, cp, gid - cp))
    segments.append((0xFFFF, 0xFFFF, 1))

    seg_count = len(segments)
    seg_count_x2 = seg_count * 2
    search_range = 2 * (1 << (seg_count.bit_length() - 1))
    entry_selector = seg_count.bit_length() - 1
    range_shift = seg_count_x2 - search_range

    sub = bytearray()
    sub.extend(struct.pack(">HHHH", 4, 0, 0, seg_count_x2))
    sub.extend(struct.pack(">HHH", search_range, entry_selector, range_shift))
    for _, end_c, _ in segments:
        sub.extend(struct.pack(">H", end_c))
    sub.extend(struct.pack(">H", 0))  # reservedPad
    for start_c, _, _ in segments:
        sub.extend(struct.pack(">H", start_c))
    for _, _, delta in segments:
        sub.extend(struct.pack(">h", delta))
    for _ in segments:
        sub.extend(struct.pack(">H", 0))  # idRangeOffset = 0

    struct.pack_into(">H", sub, 2, len(sub))

    # Header: version 0, 2 encoding records pointing to same format 4 subtable
    offset = 4 + 2 * 8
    cmap = bytearray(struct.pack(">HH", 0, 2))
    cmap.extend(struct.pack(">HHII", 0, 3, offset, 0)[:8])  # fix pack below
    cmap = bytearray(struct.pack(">HH", 0, 2))
    cmap.extend(struct.pack(">HHI", 0, 3, offset))  # Unicode BMP
    cmap.extend(struct.pack(">HHI", 3, 1, offset))  # Windows Unicode BMP
    cmap.extend(sub)
    return bytes(cmap)


def _build_name() -> bytes:
    records_src = [
        (1, "RC LCD Digital"),
        (2, "Regular"),
        (3, "RecordingCard: RCLcdDigital-Regular: 1.0"),
        (4, "RC LCD Digital Regular"),
        (5, "Version 1.0"),
        (6, "RCLcdDigital-Regular"),
    ]
    recs: list[tuple[int, int, int, int, bytes]] = []
    for name_id, text in records_src:
        # Macintosh Roman / Unicode & Windows UTF-16BE
        u16 = text.encode("utf-16-be")
        recs.append((0, 3, 0, name_id, u16))
        recs.append((3, 1, 0x0409, name_id, u16))

    recs.sort(key=lambda r: (r[0], r[1], r[2], r[3]))
    storage = bytearray()
    header = bytearray(struct.pack(">HHH", 0, len(recs), 6 + 12 * len(recs)))
    for pid, eid, lid, nid, data in recs:
        header.extend(struct.pack(">HHHHHH", pid, eid, lid, nid, len(data), len(storage)))
        storage.extend(data)
    return bytes(header + storage)


def _checksum(data: bytes) -> int:
    padded = data + b"\x00" * ((4 - len(data) % 4) % 4)
    total = 0
    for (val,) in struct.iter_unpack(">I", padded):
        total = (total + val) & 0xFFFFFFFF
    return total


def build_ttf() -> bytes:
    glyf_blobs: list[bytes] = []
    bboxes: list[tuple[int, int, int, int]] = []
    advances: list[int] = []
    lsbs: list[int] = []
    codepoints: dict[int, int] = {}

    for gid, (_, cp, adv, contours) in enumerate(GLYPH_SPECS):
        blob, bbox = _encode_glyf_entry(contours)
        glyf_blobs.append(blob)
        bboxes.append(bbox)
        advances.append(adv)
        lsbs.append(bbox[0] if contours else 0)
        if cp is not None:
            codepoints[cp] = gid

    num_glyphs = len(GLYPH_SPECS)
    non_empty = [b for b, (_, _, _, cs) in zip(bboxes, GLYPH_SPECS) if cs]
    xmin = min(b[0] for b in non_empty)
    ymin = min(b[1] for b in non_empty)
    xmax = max(b[2] for b in non_empty)
    ymax = max(b[3] for b in non_empty)

    glyf = bytearray()
    loca = bytearray()
    for blob in glyf_blobs:
        loca.extend(struct.pack(">I", len(glyf)))
        glyf.extend(blob)
    loca.extend(struct.pack(">I", len(glyf)))

    max_pts = max((sum(len(c) for c in cs) for _, _, _, cs in GLYPH_SPECS), default=0)
    max_contours = max((len(cs) for _, _, _, cs in GLYPH_SPECS), default=0)

    head = struct.pack(
        ">IIIIHHqqhhhhHHhhh",
        0x00010000,
        0x00010000,
        0,
        0x5F0F3CF5,
        0x000B,
        UPM,
        0,
        0,
        xmin, ymin, xmax, ymax,
        0,
        8,
        2,
        1,
        0,
    )
    assert len(head) == 54, len(head)

    max_adv = max(advances)
    min_lsb = min(lsbs)
    min_rsb = min(adv - (lsb + (bb[2] - bb[0])) for adv, lsb, bb in zip(advances, lsbs, bboxes))
    x_max_extent = max(lsb + (bb[2] - bb[0]) for lsb, bb in zip(lsbs, bboxes))

    # Exact 36-byte hhea table
    hhea = struct.pack(
        ">IhhhHhhhhhh5hH",
        0x00010000,
        ASCENDER,
        DESCENDER,
        LINE_GAP,
        max_adv,
        min_lsb,
        min_rsb,
        x_max_extent,
        1,
        0,
        0,
        0, 0, 0, 0, 0,
        num_glyphs,
    )
    assert len(hhea) == 36, len(hhea)

    hmtx = bytearray()
    for adv, lsb in zip(advances, lsbs):
        hmtx.extend(struct.pack(">Hh", adv, lsb))

    maxp = struct.pack(
        ">IH13H",
        0x00010000,
        num_glyphs,
        max_pts,
        max_contours,
        0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0,
    )
    assert len(maxp) == 32, len(maxp)

    # OS/2 version 4 (96 bytes)
    panose = bytes([2, 0, 5, 9, 0, 0, 0, 0, 0, 0])  # monospaced
    os2 = struct.pack(
        ">HhHHH11h10sIIII4sHHHhhhHHIIhhHHH",
        4,              # version
        DIGIT_ADVANCE,  # xAvgCharWidth
        500,            # usWeightClass (Medium)
        5,              # usWidthClass
        0,              # fsType (installable)
        650, 600, 0, -140,
        650, 600, 0, 480,
        50, 380,
        0,              # sFamilyClass
        panose,
        1, 0, 0, 0,     # ulUnicodeRange 1..4
        b"REAI",
        0x0040,         # fsSelection (REGULAR)
        min(codepoints),
        max(codepoints),
        ASCENDER,
        DESCENDER,
        LINE_GAP,
        ASCENDER,
        -DESCENDER,
        1, 0,           # ulCodePageRange 1..2
        500,            # sxHeight
        T,              # sCapHeight
        0,              # usDefaultChar
        0x0020,         # usBreakChar
        1,              # usMaxContext
    )
    assert len(os2) == 96, len(os2)

    post = struct.pack(
        ">IIhhIIIII",
        0x00030000,  # format 3.0 (no PostScript glyph names needed)
        0,           # italicAngle
        -100,        # underlinePosition
        50,          # underlineThickness
        1,           # isFixedPitch = 1
        0, 0, 0, 0,
    )
    assert len(post) == 32, len(post)

    tables: dict[str, bytes] = {
        "OS/2": os2,
        "cmap": _build_cmap(codepoints),
        "glyf": bytes(glyf),
        "head": head,
        "hhea": hhea,
        "hmtx": bytes(hmtx),
        "loca": bytes(loca),
        "maxp": maxp,
        "name": _build_name(),
        "post": post,
    }

    num_tables = len(tables)
    search_range = 16 * (1 << (num_tables.bit_length() - 1))
    entry_selector = num_tables.bit_length() - 1
    range_shift = num_tables * 16 - search_range

    sfnt = bytearray(struct.pack(">IHHHH", 0x00010000, num_tables, search_range, entry_selector, range_shift))
    body = bytearray()
    dir_entries: list[tuple[str, int, int, int]] = []
    base_offset = 12 + 16 * num_tables
    head_offset = 0

    for tag in sorted(tables.keys()):
        raw = tables[tag]
        csum = _checksum(raw)
        off = base_offset + len(body)
        if tag == "head":
            head_offset = off
        dir_entries.append((tag, csum, off, len(raw)))
        body.extend(raw)
        while len(body) % 4 != 0:
            body.append(0)

    for tag, csum, off, length in dir_entries:
        sfnt.extend(struct.pack(">4sIII", tag.encode("ascii"), csum, off, length))

    full = bytearray(sfnt + body)
    adj = (0xB1B0AFBA - _checksum(bytes(full))) & 0xFFFFFFFF
    struct.pack_into(">I", full, head_offset + 8, adj)
    return bytes(full)


def main() -> None:
    out_path = Path(
        sys.argv[1]
        if len(sys.argv) > 1
        else Path(__file__).resolve().parent.parent / "Shared" / "Fonts" / "RCLcdDigital-Regular.ttf"
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    ttf = build_ttf()
    out_path.write_bytes(ttf)
    print(f"Wrote {out_path} ({len(ttf)} bytes)")


if __name__ == "__main__":
    main()
