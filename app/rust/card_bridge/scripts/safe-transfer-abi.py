#!/usr/bin/env python3
"""Pure ctypes host smoke test. No DeviceManager, Bluetooth or network calls."""
import ctypes
import json
import pathlib
import queue
import sys
import tempfile

library = pathlib.Path(sys.argv[1]).resolve()
lib = ctypes.CDLL(str(library))
Callback = ctypes.CFUNCTYPE(None, ctypes.c_size_t, ctypes.c_void_p)
lib.card_bridge_version.argtypes = []
lib.card_bridge_version.restype = ctypes.c_char_p
lib.card_bridge_request.argtypes = [ctypes.c_char_p, Callback, ctypes.c_size_t]
lib.card_bridge_request.restype = None
lib.card_bridge_free_string.argtypes = [ctypes.c_void_p]
lib.card_bridge_free_string.restype = None
lib.card_bridge_set_event_callback.argtypes = [ctypes.c_void_p]
lib.card_bridge_set_event_callback.restype = None
received = queue.Queue()

@Callback
def callback(ticket, ptr):
    try:
        value = json.loads(ctypes.string_at(ptr).decode("utf-8"))
        received.put((ticket, value))
    finally:
        lib.card_bridge_free_string(ptr)

serial = 0

def call(request):
    global serial
    serial += 1
    lib.card_bridge_request(json.dumps(request).encode("utf-8"), callback, serial)
    while True:
        ticket, response = received.get(timeout=10)
        assert ticket == serial
        if "event" not in response:
            return response

assert b"card_bridge/" in lib.card_bridge_version()
lib.card_bridge_set_event_callback(ctypes.cast(callback, ctypes.c_void_p))
lib.card_bridge_set_event_callback(None)
for _ in range(100):
    assert call({"op": "status"})["code"] == "disconnected"
capabilities = call({"op": "fileTransferCapabilities"})
assert capabilities["ok"]
assert capabilities["data"]["safeBleDownload"] is False
assert capabilities["data"]["keepProtocolImplemented"] is True
assert capabilities["data"]["atomicConditionalDelete"] is False
assert capabilities["data"]["verifiedMainVersionCode"] is None
assert call({"op": "confirmDeleteFile", "downloadId": "untrusted"})["code"] == "confirmation"
assert call({"op": "confirmDeleteFile", "downloadId": "untrusted", "repositoryCommitted": True})["code"] == "receipt"
assert call({"op": "cancelFileTransfer", "transferTicket": 987654})["data"]["cancelSignalled"] is False
with tempfile.TemporaryDirectory(prefix="card-abi-safe-") as directory:
    root = pathlib.Path(directory)
    source = root / "sample.pcm"
    source.write_bytes(b"\x00\x00\x01\x00\xff\xff")
    result = call({"op": "convertAudio", "source": str(source), "destination": str(root / "sample.wav"), "format": "pcm"})
    assert result["ok"] and result["data"]["samples"] == 3
    assert (root / "sample.wav").read_bytes()[:4] == b"RIFF"
assert call({"op": "disconnect"})["data"]["disconnected"] is True
print("PASS: four ABI signatures, 100 owned/free envelopes, honest keep capability, commit/receipt/cancel guards, real local PCM-to-WAV; no physical/network operations")
