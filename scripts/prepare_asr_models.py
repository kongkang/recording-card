#!/usr/bin/env python3
"""Prepare pinned SenseVoice artifacts; no accounts or audio upload.

Requires explicit --accept-model-license. The default production registry pins
remain unchanged. The separately measured local profile is offline-only and
must be explicitly selected. Model weights must stay outside the repository.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import urllib.parse
import urllib.request

COMMIT = '2365baeacb507f821a0c8120fcee3d484dba7a07'
BASE = ('https://huggingface.co/csukuangfj/'
        'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/' + COMMIT)
HOSTS = {'huggingface.co', 'us.aws.cdn.hf.co'}
PRODUCTION_PROFILE = 'sensevoice-mobile-20240717'
LOCAL_PROFILE = 'reai-vibe-board-local-20261109'
ARTIFACTS = {
    'model.int8.onnx': (239233841, 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51'),
    'tokens.txt': (315894, 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc'),
}
LOCAL_ARTIFACTS = {
    'model.int8.onnx': (237115547, '12ca1a2ae7ecf3e0019ef2822307ee0b5cadc9196569e379b4c4026f8205276d'),
    'tokens.txt': ARTIFACTS['tokens.txt'],
    'silero_vad.onnx': (643854, '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6'),
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


def require_verified(path, size, digest):
    if not verified(path, size, digest):
        raise ValueError(f'{path}: missing or mismatched artifact; expected '
                         f'{size} bytes / SHA256 {digest}. No fallback or audio upload.')


def check_destination(path):
    root = Path(__file__).resolve().parents[1]
    if path.resolve().is_relative_to(root):
        raise ValueError('Cache model weights outside the repository; never commit weights')


def copy_verified(source, target, size, digest):
    require_verified(source, size, digest)
    check_destination(target)
    if verified(target, size, digest):
        print(target.name + ': verified cache', flush=True)
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    part = target.with_suffix(target.suffix + '.part')
    try:
        shutil.copyfile(source, part)
        require_verified(part, size, digest)
        os.replace(part, target)
        print(target.name + ': copied and verified locally', flush=True)
    finally:
        if part.exists():
            part.unlink()


def download(path, url, size=None, digest=None):
    check_url(url)
    check_destination(path)
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
        if size is not None:
            require_verified(part, size, digest)
        os.replace(part, path)
        print(path.name + ': saved' + (' and verified' if size is not None else ' bounded fixture'), flush=True)
    finally:
        if part.exists():
            part.unlink()


def make_manifest(profile, artifacts, sources):
    return {
        'schema_version': 1,
        'model': 'SenseVoiceSmall / sherpa ONNX int8',
        'artifact_profile': profile,
        'source_commit': COMMIT if profile == PRODUCTION_PROFILE else None,
        'files': {n: {'size': s, 'sha256': d, 'path': str(sources[n])}
                  for n, (s, d) in artifacts.items()},
        'source': BASE if profile == PRODUCTION_PROFILE else 'Explicit local files, measured 2026-11-09; NOT the production registry artifact',
        'runtime_defines': {
            'RC_ASR_ARTIFACT_PROFILE': profile,
            'RC_ASR_LOCAL_ARTIFACTS_APPROVED': profile == LOCAL_PROFILE,
            'RC_ASR_LICENSE_ACCEPTED': True,
            'RC_ASR_ALLOW_DOWNLOAD': False,
        },
        'use': 'Local licensed testing; no accounts or user audio uploaded',
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=Path.home() / '.cache/recording-card-asr')
    parser.add_argument('--profile', choices=[PRODUCTION_PROFILE, LOCAL_PROFILE], default=PRODUCTION_PROFILE)
    parser.add_argument('--source-directory', type=Path, help='Explicit local SenseVoice directory (never modified)')
    parser.add_argument('--vad-source', type=Path, help='Explicit local Silero VAD file (never modified)')
    parser.add_argument('--verify-only', action='store_true', help='Verify source files without copying or downloading')
    parser.add_argument('--manifest-output', type=Path, help='Write verified metadata here; contains no weights/audio')
    parser.add_argument('--accept-model-license', action='store_true')
    parser.add_argument('--with-fixture', action='store_true', help='Prepare upstream non-sensitive zh.wav for local inference only')
    args = parser.parse_args(argv)
    if not args.accept_model_license:
        parser.error('Review app/lib/services/transcription/NOTICE.md and pass --accept-model-license for this test use')
    if args.profile == LOCAL_PROFILE:
        if args.source_directory is None or args.vad_source is None:
            parser.error('Local profile requires --source-directory and --vad-source; never downloads or infers a source')
        artifacts = LOCAL_ARTIFACTS
        sources = {name: (args.vad_source if name == 'silero_vad.onnx'
                          else args.source_directory / name) for name in artifacts}
    else:
        if args.source_directory is not None or args.vad_source is not None:
            parser.error('Local sources require the explicit local profile')
        artifacts = ARTIFACTS
        sources = {name: args.directory / name for name in artifacts}
    # Check all local inputs before installing anything. Never derive trust pins
    # from observed files: a manifest is emitted only after the fixed pins match.
    if args.profile == LOCAL_PROFILE or args.verify_only:
        for name, (size, digest) in artifacts.items():
            require_verified(sources[name], size, digest)
            print(name + ': source verified against ' + args.profile, flush=True)
    if not args.verify_only:
        check_destination(args.directory)
        args.directory.mkdir(parents=True, exist_ok=True)
        for name, (size, digest) in artifacts.items():
            target = args.directory / name
            if args.profile == LOCAL_PROFILE:
                copy_verified(sources[name], target, size, digest)
            else:
                download(target, BASE + '/' + name, size, digest)
            sources[name] = target
    if args.with_fixture:
        if args.verify_only:
            parser.error('--with-fixture cannot be combined with --verify-only')
        target = args.directory / 'zh.wav'
        if args.profile == LOCAL_PROFILE:
            source = args.source_directory / 'test_wavs/zh.wav'
            if not source.is_file() or not 0 < source.stat().st_size <= 2 * 1024 * 1024:
                raise ValueError('Local upstream zh.wav fixture missing or exceeds 2 MiB')
            check_destination(target)
            if source.resolve() != target.resolve():
                shutil.copyfile(source, target)
        else:
            download(target, BASE + '/test_wavs/zh.wav')
    output = args.manifest_output or args.directory / 'verified-manifest.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(make_manifest(args.profile, artifacts, sources), indent=2) + '\n')
    print('Verified manifest: ' + str(output), flush=True)


if __name__ == '__main__':
    main()
