#!/usr/bin/env python3
"""零依赖 Android/Linux btsnoop_hci.log 解析器（支持 BLE ATT 与 Classic L2CAP/RFCOMM 分流统计）。

用途：
  - 在不依赖 Wireshark/tshark 的环境下，从 Android 导出的 `btsnoop_hci.log`
    中提取 BLE ATT（0x0004）双向读写/通知报文与经典蓝牙动态 L2CAP（>= 0x0040，含 RFCOMM/SPP）报文；
  - 汇总统计 ATT vs 非 ATT 动态通道包数，快速判定设备走 BLE GATT 还是经典蓝牙 SPP。

示例：
  python3 scripts/parse_btsnoop_hci.py --self-test
  python3 scripts/parse_btsnoop_hci.py --file btsnoop_hci.log --limit 200
  python3 scripts/parse_btsnoop_hci.py --file btsnoop_hci.log --only-att --handle 0x0025 --json att.json
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import struct
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

BTSNOOP_MAGIC = b"btsnoop\x00"
BTSNOOP_UNIX_OFFSET_US = 0x00DCDDB30F2F8000  # 1970-01-01 minus 0000-01-01 in microseconds
DATALINK_HCI_H4 = 1002
DATALINK_HCI_H1 = 1001

ATT_OPCODES: Dict[int, str] = {
    0x01: "ErrorRsp",
    0x02: "ExchangeMtuReq",
    0x03: "ExchangeMtuRsp",
    0x04: "FindInfoReq",
    0x05: "FindInfoRsp",
    0x06: "FindByTypeValReq",
    0x07: "FindByTypeValRsp",
    0x08: "ReadByTypeReq",
    0x09: "ReadByTypeRsp",
    0x0A: "ReadReq",
    0x0B: "ReadRsp",
    0x0C: "ReadBlobReq",
    0x0D: "ReadBlobRsp",
    0x10: "ReadByGroupTypeReq",
    0x11: "ReadByGroupTypeRsp",
    0x12: "WriteReq",
    0x13: "WriteRsp",
    0x16: "PrepareWriteReq",
    0x17: "PrepareWriteRsp",
    0x18: "ExecuteWriteReq",
    0x19: "ExecuteWriteRsp",
    0x1B: "HandleValueNotify",
    0x1D: "HandleValueInd",
    0x1E: "HandleValueConf",
    0x52: "WriteCmd",
    0xD2: "SignedWriteCmd",
}


def format_btsnoop_timestamp(ts_us: int) -> str:
    if ts_us < BTSNOOP_UNIX_OFFSET_US:
        return f"raw_us:{ts_us}"
    unix_us = ts_us - BTSNOOP_UNIX_OFFSET_US
    sec, rem_us = divmod(unix_us, 1_000_000)
    try:
        t = dt.datetime.fromtimestamp(sec, tz=dt.timezone.utc) + dt.timedelta(
            microseconds=rem_us
        )
        return t.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    except (OverflowError, OSError, ValueError):
        return f"unix_us:{unix_us}"


def to_hex(data: bytes, limit: Optional[int] = None) -> str:
    chunk = data if limit is None else data[:limit]
    s = " ".join(f"{b:02x}" for b in chunk)
    if limit is not None and len(data) > limit:
        s += f" ... (+{len(data) - limit}B)"
    return s


def to_ascii_preview(data: bytes, limit: Optional[int] = 48) -> str:
    chunk = data if limit is None else data[:limit]
    chars = [chr(b) if 0x20 <= b <= 0x7E else "." for b in chunk]
    out = "".join(chars)
    if limit is not None and len(data) > limit:
        out += "..."
    return out


def parse_hex_u16(raw: str) -> int:
    clean = raw.strip().lower()
    if clean.startswith("0x"):
        return int(clean, 16)
    return int(clean, 16)


def decode_att_sdu(sdu: bytes) -> Dict[str, Any]:
    if not sdu:
        return {"opcode": None, "opcodeName": "EmptyATT", "attHandle": None, "payload": b""}
    op = sdu[0]
    name = ATT_OPCODES.get(op, f"Op_0x{op:02x}")
    att_handle: Optional[int] = None
    payload = sdu[1:]
    detail: Dict[str, Any] = {}

    if op in (0x0A, 0x0C, 0x12, 0x1B, 0x1D, 0x52, 0xD2) and len(sdu) >= 3:
        att_handle = struct.unpack_from("<H", sdu, 1)[0]
        payload = sdu[3:]
    elif op == 0x01 and len(sdu) >= 5:
        att_handle = struct.unpack_from("<H", sdu, 2)[0]
        detail["reqOpcode"] = f"0x{sdu[1]:02x}"
        detail["errorCode"] = f"0x{sdu[4]:02x}"
        payload = sdu[5:]
    elif op in (0x02, 0x03) and len(sdu) >= 3:
        detail["mtu"] = struct.unpack_from("<H", sdu, 1)[0]
        payload = sdu[3:]
    elif op in (0x04, 0x08, 0x10) and len(sdu) >= 5:
        start_h, end_h = struct.unpack_from("<HH", sdu, 1)
        detail["startHandle"] = f"0x{start_h:04x}"
        detail["endHandle"] = f"0x{end_h:04x}"
        payload = sdu[5:]
    elif op in (0x0B, 0x0D, 0x13, 0x1E):
        payload = sdu[1:]

    return {
        "opcode": f"0x{op:02x}",
        "opcodeName": name,
        "attHandle": f"0x{att_handle:04x}" if att_handle is not None else None,
        "attHandleNum": att_handle,
        "payload": payload,
        "detail": detail,
    }


def parse_btsnoop_bytes(raw: bytes) -> Dict[str, Any]:
    if len(raw) < 16 or raw[:8] != BTSNOOP_MAGIC:
        raise ValueError("不是有效的 btsnoop 文件（缺少 btsnoop\\x00 文件头）")

    version, datalink = struct.unpack_from(">II", raw, 8)
    if version != 1:
        raise ValueError(f"不支持的 btsnoop 版本: {version}")
    if datalink not in (DATALINK_HCI_H4, DATALINK_HCI_H1):
        raise ValueError(f"不支持的 btsnoop 数据链路类型: {datalink}")

    offset = 16
    total_records = 0
    acl_packets = 0
    att_count = 0
    rfcomm_dyn_count = 0
    other_l2cap_count = 0
    att_handles_seen: Dict[str, int] = {}
    reassembly: Dict[Tuple[int, str], bytearray] = {}
    events: List[Dict[str, Any]] = []

    while offset + 24 <= len(raw):
        orig_len, incl_len, flags, _drops, ts_us = struct.unpack_from(">IIIIQ", raw, offset)
        offset += 24
        if offset + incl_len > len(raw):
            break
        pkt = raw[offset : offset + incl_len]
        offset += incl_len
        total_records += 1

        direction = "RX" if (flags & 0x01) else "TX"
        is_cmd_or_evt = bool(flags & 0x02)

        if datalink == DATALINK_HCI_H4:
            if not pkt:
                continue
            hci_type = pkt[0]
            body = pkt[1:]
        else:
            if is_cmd_or_evt:
                continue
            hci_type = 0x02
            body = pkt

        if hci_type != 0x02 or len(body) < 4:
            continue

        acl_packets += 1
        handle_flags, acl_len = struct.unpack_from("<HH", body, 0)
        conn_handle = handle_flags & 0x0FFF
        pb_flag = (handle_flags >> 12) & 0x03
        acl_payload = body[4 : 4 + acl_len]
        if not acl_payload:
            continue

        key = (conn_handle, direction)
        if pb_flag in (0x00, 0x02):
            reassembly[key] = bytearray(acl_payload)
        elif pb_flag == 0x01:
            if key not in reassembly:
                continue
            reassembly[key].extend(acl_payload)
        else:
            continue

        buf = reassembly[key]
        if len(buf) < 4:
            continue
        l2cap_len, cid = struct.unpack_from("<HH", buf, 0)
        if len(buf) < 4 + l2cap_len:
            continue

        sdu = bytes(buf[4 : 4 + l2cap_len])
        del reassembly[key]

        ts_str = format_btsnoop_timestamp(ts_us)
        conn_hex = f"0x{conn_handle:04x}"

        if cid == 0x0004:
            att_count += 1
            decoded = decode_att_sdu(sdu)
            ah = decoded["attHandle"]
            if ah is not None:
                att_handles_seen[ah] = att_handles_seen.get(ah, 0) + 1
            payload = decoded["payload"]
            events.append(
                {
                    "recordIndex": total_records,
                    "timestamp": ts_str,
                    "timestampUs": ts_us,
                    "direction": direction,
                    "connHandle": conn_hex,
                    "cid": "0x0004",
                    "channel": "ATT",
                    "opcode": decoded["opcode"],
                    "opcodeName": decoded["opcodeName"],
                    "attHandle": ah,
                    "detail": decoded["detail"],
                    "payloadLen": len(payload),
                    "payloadHex": to_hex(payload),
                    "asciiPreview": to_ascii_preview(payload),
                    "rawLen": len(sdu),
                    "origLen": orig_len,
                }
            )
        elif cid >= 0x0040:
            rfcomm_dyn_count += 1
            events.append(
                {
                    "recordIndex": total_records,
                    "timestamp": ts_str,
                    "timestampUs": ts_us,
                    "direction": direction,
                    "connHandle": conn_hex,
                    "cid": f"0x{cid:04x}",
                    "channel": "L2CAP_DYN/RFCOMM?",
                    "opcode": None,
                    "opcodeName": "DynamicL2CAP",
                    "attHandle": None,
                    "detail": {},
                    "payloadLen": len(sdu),
                    "payloadHex": to_hex(sdu),
                    "asciiPreview": to_ascii_preview(sdu),
                    "rawLen": len(sdu),
                    "origLen": orig_len,
                }
            )
        else:
            other_l2cap_count += 1

    if att_count > 0 and rfcomm_dyn_count == 0:
        transport_hint = "仅检测到 BLE ATT (0x0004) 通信，未见经典蓝牙动态 L2CAP/RFCOMM 数据"
    elif rfcomm_dyn_count > 0 and att_count == 0:
        transport_hint = "仅检测到经典蓝牙动态 L2CAP/RFCOMM 数据，未见 BLE ATT 业务报文"
    elif att_count > 0 and rfcomm_dyn_count > 0:
        transport_hint = "同时检测到 BLE ATT 与动态 L2CAP/RFCOMM（双通道混用，需核对音频同步落点）"
    else:
        transport_hint = "未检测到业务级 ATT 或动态 L2CAP 数据包"

    return {
        "summary": {
            "datalink": datalink,
            "totalRecords": total_records,
            "aclPackets": acl_packets,
            "attPackets": att_count,
            "rfcommDynamicPackets": rfcomm_dyn_count,
            "otherL2capPackets": other_l2cap_count,
            "uniqueAttHandles": dict(sorted(att_handles_seen.items())),
            "transportAssessment": transport_hint,
        },
        "events": events,
    }


def filter_events(
    events: List[Dict[str, Any]],
    only_att: bool = False,
    only_rfcomm: bool = False,
    handle_filter: Optional[int] = None,
    limit: Optional[int] = None,
) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    target_hex = f"0x{handle_filter:04x}" if handle_filter is not None else None
    for ev in events:
        if only_att and ev["channel"] != "ATT":
            continue
        if only_rfcomm and ev["channel"] == "ATT":
            continue
        if target_hex is not None:
            if ev["attHandle"] != target_hex and ev["connHandle"] != target_hex:
                continue
        out.append(ev)
        if limit is not None and len(out) >= limit:
            break
    return out


def build_synthetic_btsnoop_for_test() -> bytes:
    header = BTSNOOP_MAGIC + struct.pack(">II", 1, DATALINK_HCI_H4)
    base_ts = BTSNOOP_UNIX_OFFSET_US + 1_700_000_000 * 1_000_000

    def wrap_acl(conn_handle: int, cid: int, sdu: bytes, rx: bool, dt_us: int) -> bytes:
        l2cap = struct.pack("<HH", len(sdu), cid) + sdu
        pb = 0x02
        hf = (conn_handle & 0x0FFF) | ((pb & 0x03) << 12)
        acl = b"\x02" + struct.pack("<HH", hf, len(l2cap)) + l2cap
        flags = 0x01 if rx else 0x00
        rec_hdr = struct.pack(">IIIIQ", len(acl), len(acl), flags, 0, base_ts + dt_us)
        return rec_hdr + acl

    att_write_cmd = b"\x52" + struct.pack("<H", 0x0025) + b"\xaa\x55\x01OK"
    att_notify = b"\x1b" + struct.pack("<H", 0x0028) + b"BAT:88%"
    rfcomm_dyn = b"\x03\xef\x05AT+BAT"

    return (
        header
        + wrap_acl(0x0040, 0x0004, att_write_cmd, rx=False, dt_us=0)
        + wrap_acl(0x0040, 0x0004, att_notify, rx=True, dt_us=15_000)
        + wrap_acl(0x000B, 0x0041, rfcomm_dyn, rx=False, dt_us=30_000)
    )


def run_self_test() -> None:
    sample = build_synthetic_btsnoop_for_test()
    parsed = parse_btsnoop_bytes(sample)
    summary = parsed["summary"]
    events = parsed["events"]

    assert summary["totalRecords"] == 3, summary
    assert summary["aclPackets"] == 3, summary
    assert summary["attPackets"] == 2, summary
    assert summary["rfcommDynamicPackets"] == 1, summary
    assert summary["uniqueAttHandles"] == {"0x0025": 1, "0x0028": 1}, summary

    assert events[0]["channel"] == "ATT"
    assert events[0]["direction"] == "TX"
    assert events[0]["opcodeName"] == "WriteCmd"
    assert events[0]["attHandle"] == "0x0025"
    assert events[0]["payloadHex"] == "aa 55 01 4f 4b"
    assert events[0]["asciiPreview"] == ".U.OK", events[0]

    assert events[1]["channel"] == "ATT"
    assert events[1]["direction"] == "RX"
    assert events[1]["opcodeName"] == "HandleValueNotify"
    assert events[1]["attHandle"] == "0x0028"
    assert events[1]["asciiPreview"] == "BAT:88%"

    assert events[2]["channel"] == "L2CAP_DYN/RFCOMM?"
    assert events[2]["cid"] == "0x0041"
    assert events[2]["connHandle"] == "0x000b"
    assert events[2]["asciiPreview"] == "...AT+BAT"

    att_only = filter_events(events, only_att=True)
    assert len(att_only) == 2
    rfcomm_only = filter_events(events, only_rfcomm=True)
    assert len(rfcomm_only) == 1
    by_handle = filter_events(events, handle_filter=0x0028)
    assert len(by_handle) == 1 and by_handle[0]["attHandle"] == "0x0028"

    print("parse_btsnoop_hci.py self-test OK (3 records: 2 ATT + 1 L2CAP_DYN/RFCOMM?)")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="零依赖 Android btsnoop_hci.log 解析器（BLE ATT / Classic RFCOMM 分流）"
    )
    parser.add_argument("--file", help="btsnoop_hci.log 文件路径")
    parser.add_argument("--only-att", action="store_true", help="仅显示 BLE ATT (0x0004) 报文")
    parser.add_argument(
        "--only-rfcomm", action="store_true", help="仅显示动态 L2CAP/RFCOMM (>= 0x0040) 报文"
    )
    parser.add_argument("--handle", help="按 ATT Handle 或 Conn Handle (hex, 如 0x0025) 过滤")
    parser.add_argument("--limit", type=int, default=None, help="最多输出前 N 条匹配报文")
    parser.add_argument("--max-hex-bytes", type=int, default=48, help="终端每行最多展示的 Hex 字节数")
    parser.add_argument("--json", dest="json_out", help="将解析结果写入 JSON 文件")
    parser.add_argument("--self-test", action="store_true", help="运行内置合成帧自测")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return 0

    if not args.file:
        parser.error("请提供 --file <btsnoop_hci.log> 或使用 --self-test")

    if args.only_att and args.only_rfcomm:
        parser.error("--only-att 与 --only-rfcomm 不能同时指定")

    handle_val = parse_hex_u16(args.handle) if args.handle else None
    raw = Path(args.file).read_bytes()
    parsed = parse_btsnoop_bytes(raw)
    filtered = filter_events(
        parsed["events"],
        only_att=args.only_att,
        only_rfcomm=args.only_rfcomm,
        handle_filter=handle_val,
        limit=args.limit,
    )

    summary = parsed["summary"]
    print("=== btsnoop_hci.log 统计摘要 ===")
    print(f"记录总数: {summary['totalRecords']} | ACL包: {summary['aclPackets']}")
    print(
        f"BLE ATT (0x0004): {summary['attPackets']} | 动态 L2CAP/RFCOMM: {summary['rfcommDynamicPackets']} | 其他 L2CAP: {summary['otherL2capPackets']}"
    )
    print(f"通道判断: {summary['transportAssessment']}")
    if summary["uniqueAttHandles"]:
        print(f"出现的 ATT Handle: {summary['uniqueAttHandles']}")
    print(f"\n=== 报文明细（匹配 {len(filtered)} 条）===")

    for ev in filtered:
        raw_bytes = bytes.fromhex(ev["payloadHex"].replace(" ", "")) if ev["payloadHex"] else b""
        hex_preview = to_hex(raw_bytes, limit=args.max_hex_bytes)
        ah = ev["attHandle"] or "-"
        print(
            f"#{ev['recordIndex']:05d} {ev['timestamp']} {ev['direction']} "
            f"conn={ev['connHandle']} cid={ev['cid']} [{ev['channel']}] "
            f"{ev['opcodeName']} handle={ah} len={ev['payloadLen']} "
            f"hex=[{hex_preview}] ascii=\"{ev['asciiPreview']}\""
        )

    if args.json_out:
        out_payload = {"summary": summary, "events": filtered}
        out_path = Path(args.json_out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(
            json.dumps(out_payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print(f"\n已写入 JSON: {args.json_out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
