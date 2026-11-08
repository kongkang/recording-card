#!/usr/bin/env python3
"""Prepare pinned SenseVoice ONNX test artifacts; no accounts or audio upload.

Requires explicit --accept-model-license. Weights are cached outside tracked
sources. Source, size and digest match the authorized ReAI mobile registry.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import urllib.parse
import urllib.request

COMMIT = '2365baeacb507f821a0c8120fcee3d484dba7a07'
BASE = ('https://huggingface.co/csukuangfj/'
        'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/' + COMMIT)
HOSTS = {'huggingface.co', 'us.aws.cdn.hf.co'}
ARTIFACTS = {
    'model.int8.onnx': (239233841, 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51'),
    'tokens.txt': (315894, 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc'),
}


def check_url(url):
    parsed = urllib.parse.urlparse(url)
    if (parsed.scheme != 'https' or parsed.hostname not in HOSTS
            or parsed.username or parsed.password or parsed.port not in (None, 443)):
        raise ValueError('Model download host is not in the pinned HTTPS allowlist')


class TrustedRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def verified(path, size, digest):
    if not path.is_file() or path.stat().st_size != size:
        return False
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest() == digest


def download(path, url, size=None, digest=None):
    check_url(url)
    if size is not None and verified(path, size, digest):
        print(path.name + ': verified cache', flush=True)
        return
    part = path.with_suffix(path.suffix + '.part')
    opener = urllib.request.build_opener(TrustedRedirect())
    count = 0
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'RecordingCard-model-test/1.0'})
        with opener.open(req, timeout=60) as response, part.open('wb') as stream:
            if response.status != 200:
                raise ValueError('Expected complete 200 model response')
            announced = response.headers.get('Content-Length')
            if size is not None and announced is not None and int(announced) != size:
                raise ValueError('Model Content-Length does not match pinned size')
            last_report = 0
            for block in iter(lambda: response.read(1024 * 1024), b''):
                count += len(block)
                if count > (size if size is not None else 2 * 1024 * 1024):
                    raise ValueError('Artifact exceeds allowed size')
                stream.write(block)
                if count - last_report >= 32 * 1024 * 1024:
                    print(path.name + ': ' + str(count) + ' bytes', flush=True)
                    last_report = count
        if size is not None and not verified(part, size, digest):
            raise ValueError('Pinned model size/SHA256 mismatch')
        os.replace(part, path)
        print(path.name + ': saved and verified', flush=True)
    finally:
        if part.exists():
            part.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=Path.home() / '.cache/recording-card-asr')
    parser.add_argument('--accept-model-license', action='store_true')
    parser.add_argument('--with-fixture', action='store_true', help='Download upstream non-sensitive zh.wav for local inference only')
    args = parser.parse_args()
    if not args.accept_model_license:
        parser.error('Review services/transcription/NOTICE.md and pass --accept-model-license for this test use')
    args.directory.mkdir(parents=True, exist_ok=True)
    for name, (size, digest) in ARTIFACTS.items():
        download(args.directory / name, BASE + '/' + name, size, digest)
    if args.with_fixture:
        download(args.directory / 'zh.wav', BASE + '/test_wavs/zh.wav')
    manifest = {
        'model': 'SenseVoiceSmall / sherpa ONNX int8 2024-07-17',
        'source_commit': COMMIT,
        'files': {n: {'size': s, 'sha256': d} for n, (s, d) in ARTIFACTS.items()},
        'source': BASE,
        'use': 'Local licensed fixture testing; no accounts or user audio uploaded',
    }
    (args.directory / 'verified-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('Ready: ' + str(args.directory), flush=True)


if __name__ == '__main__':
    main()
