#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 RGBA 的 PNG 转成不含 alpha 通道的 RGB PNG（仅用 Python 标准库）。

用途：iOS 图标（AppIcon）不允许带 alpha 通道，否则 App Store 校验会报
"Invalid Image - the app icon can't have an alpha channel"。
rsvg-convert 渲染结果固定是 RGBA，所以这里做一次无损重编码：反解 PNG 扫描行
滤波后丢弃 alpha 字节，再以 filter=0 重新压缩。

用法：python3 strip_alpha.py 输入.png 输出.png
"""
import struct
import sys
import zlib

PNG_SIG = b"\x89PNG\r\n\x1a\n"


def _chunks(data: bytes):
    """按顺序产出 (类型, 负载)。"""
    pos = 8
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        ctype = data[pos + 4 : pos + 8]
        payload = data[pos + 8 : pos + 8 + length]
        yield ctype, payload
        pos += 12 + length


def _paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def _unfilter(raw: bytes, width: int, height: int, bpp: int) -> bytearray:
    """把带滤波的行还原成原始像素字节流。"""
    stride = width * bpp
    out = bytearray(stride * height)
    prev = bytearray(stride)
    pos = 0
    for y in range(height):
        ftype = raw[pos]
        pos += 1
        line = bytearray(raw[pos : pos + stride])
        pos += stride
        if ftype == 1:  # Sub
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ftype == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:  # Average
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:  # Paeth
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                upleft = prev[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + _paeth(left, prev[i], upleft)) & 0xFF
        elif ftype != 0:
            raise ValueError("未知的 PNG 滤波类型 %d" % ftype)
        out[y * stride : (y + 1) * stride] = line
        prev = line
    return out


def _pack_chunk(ctype: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + ctype
        + payload
        + struct.pack(">I", zlib.crc32(ctype + payload) & 0xFFFFFFFF)
    )


def strip_alpha(src: str, dst: str) -> None:
    data = open(src, "rb").read()
    if not data.startswith(PNG_SIG):
        raise SystemExit("不是 PNG 文件：%s" % src)

    width = height = depth = color_type = None
    idat = bytearray()
    for ctype, payload in _chunks(data):
        if ctype == b"IHDR":
            width, height, depth, color_type = struct.unpack(">IIBB", payload[:10])
        elif ctype == b"IDAT":
            idat += payload

    if depth != 8 or color_type not in (2, 6):
        raise SystemExit("只支持 8bit RGB/RGBA，当前 depth=%s type=%s" % (depth, color_type))

    raw = zlib.decompress(bytes(idat))
    if color_type == 2:  # 已经是 RGB，直接原样搬运
        open(dst, "wb").write(data)
        return

    rgba = _unfilter(raw, width, height, 4)
    rgb = bytearray(width * height * 3)
    for i in range(width * height):
        rgb[i * 3 : i * 3 + 3] = rgba[i * 4 : i * 4 + 3]

    # 每行前置 filter=0
    stride = width * 3
    filtered = bytearray()
    for y in range(height):
        filtered.append(0)
        filtered += rgb[y * stride : (y + 1) * stride]

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    out = PNG_SIG + _pack_chunk(b"IHDR", ihdr)
    out += _pack_chunk(b"IDAT", zlib.compress(bytes(filtered), 9))
    out += _pack_chunk(b"IEND", b"")
    open(dst, "wb").write(out)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("用法：python3 strip_alpha.py 输入.png 输出.png")
    strip_alpha(sys.argv[1], sys.argv[2])
