#!/usr/bin/env python3
"""生成符合 App Store Connect 规范的 24-bit RGB（无透明通道）1024x1024 应用图标。"""

from __future__ import annotations

import json
import math
import pathlib
import struct
import zlib


def _png_chunk(tag: bytes, payload: bytes) -> bytes:
    crc = zlib.crc32(tag + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + tag + payload + struct.pack(">I", crc)


def render_icon_png(path: pathlib.Path, size: int = 1024, accent_ring: tuple[int, int, int] = (242, 62, 54)) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    cx = (size - 1) / 2.0
    cy = (size - 1) / 2.0
    outer_r = size * 0.34
    outer_w = size * 0.032
    dot_r = size * 0.175
    halo_r = size * 0.245

    raw = bytearray()
    for y in range(size):
        raw.append(0)  # filter type 0
        dy = y - cy
        for x in range(size):
            dx = x - cx
            dist = math.hypot(dx, dy)

            # 深炭黑柔和渐变底色（无 Alpha，Color Type 2）
            grad = (y / size) * 14.0
            r = 18.0 + grad * 0.4
            g = 20.0 + grad * 0.45
            b = 25.0 + grad * 0.6

            # 外圈柔和录音指示环
            ring_delta = abs(dist - outer_r)
            if ring_delta < outer_w:
                t = max(0.0, 1.0 - ring_delta / outer_w)
                alpha = t * t * 0.28
                r = r * (1.0 - alpha) + 235.0 * alpha
                g = g * (1.0 - alpha) + 238.0 * alpha
                b = b * (1.0 - alpha) + 245.0 * alpha

            # 内圈微光晕
            if dist < halo_r:
                t = max(0.0, 1.0 - dist / halo_r)
                alpha = (t ** 1.8) * 0.26
                r = r * (1.0 - alpha) + accent_ring[0] * alpha
                g = g * (1.0 - alpha) + accent_ring[1] * alpha
                b = b * (1.0 - alpha) + accent_ring[2] * alpha

            # 核心录音红点（带边缘 2px 抗锯齿）
            if dist <= dot_r + 1.5:
                cov = min(1.0, max(0.0, (dot_r + 1.5 - dist) / 2.0))
                # 顶部轻微高光
                shine = max(0.0, 1.0 - math.hypot(dx + dot_r * 0.22, dy + dot_r * 0.25) / (dot_r * 1.1))
                cr = min(255.0, accent_ring[0] + shine * 28.0)
                cg = min(255.0, accent_ring[1] + shine * 34.0)
                cb = min(255.0, accent_ring[2] + shine * 34.0)
                r = r * (1.0 - cov) + cr * cov
                g = g * (1.0 - cov) + cg * cov
                b = b * (1.0 - cov) + cb * cov

            raw.extend((int(r) & 0xFF, int(g) & 0xFF, int(b) & 0xFF))

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    idat = zlib.compress(bytes(raw), level=6)
    png = b"\x89PNG\r\n\x1a\n" + _png_chunk(b"IHDR", ihdr) + _png_chunk(b"IDAT", idat) + _png_chunk(b"IEND", b"")
    path.write_bytes(png)


def write_asset_catalog(asset_root: pathlib.Path, platform: str) -> None:
    asset_root.mkdir(parents=True, exist_ok=True)
    (asset_root / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )
    appicon_dir = asset_root / "AppIcon.appiconset"
    render_icon_png(appicon_dir / "AppIcon-1024.png", size=1024)
    contents = {
        "images": [
            {
                "filename": "AppIcon-1024.png",
                "idiom": "universal",
                "platform": platform,
                "size": "1024x1024",
            }
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (appicon_dir / "Contents.json").write_text(
        json.dumps(contents, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    watch_dir = pathlib.Path(__file__).resolve().parent.parent
    write_asset_catalog(watch_dir / "CompanionApp" / "Assets.xcassets", "ios")
    write_asset_catalog(watch_dir / "WatchApp" / "Assets.xcassets", "watchos")
    print("Generated iOS & watchOS 1024x1024 RGB AppIcons.")


if __name__ == "__main__":
    main()
