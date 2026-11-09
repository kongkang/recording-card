# Local ASR integration

The production service is `TranscriptionService`, defaulting to `SherpaTranscriptionBackend`. Tests inject `TranscriptionBackend`. Production never returns a transcript when models are missing or unverified. The module contains no weights and makes no automatic cloud request.

## Dependencies and iOS compatibility

The integration owner must add:

```yaml
dependencies:
  crypto: ^3.0.6
  sherpa_onnx: 1.13.3
  sherpa_onnx_ios: 1.13.3 # EXACT pin required for the 1.13.3 Dart loader
```

This module commit intentionally does not contain pubspec/lock or platform changes. `sherpa_onnx: 1.13.3` alone uses `^1.13.3` platform dependencies and resolves to 1.13.8. The installed 1.13.8 iOS package uses `SherpaOnnxC.framework`, but the 1.13.3 Dart loader opens `sherpa_onnx.framework/sherpa_onnx`. The exact iOS 1.13.3 package uses `sherpa_onnx.xcframework`/`sherpa_onnx.framework`, matching the loader. Do not remove this pin without upgrading and validating Dart/native packages together. Pin other native platform packages to the same version when validating their C ABI; they have not been exercised here.

The iOS 1.13.3 podspec requires iOS13.0 and bundles device-arm64 and simulator slices. The Mac integration owner must run `flutter pub get`, `cd ios && pod install`, `flutter build ios --no-codesign`, then authorized iPhone testing with a fixed licensed audio fixture. Linux tests are not an iOS build or device proof. Do not use an unverified framework rename workaround.

## Models

Use application-support storage owned by the app, not an assumed repository asset. `AsrModelStore(directory: ..., licenseAccepted: true)` validates the configured exact artifact sizes and SHA256 before every file task. The default artifacts are SenseVoice-small int8 `model.int8.onnx` and `tokens.txt`, approximately 228.45 MiB total. See `NOTICE.md` for model/code license separation and attribution.

Local files do not require a network endpoint. Downloads require all of: explicit `allowDownload: true`, `ModelArtifact.downloadUri`, HTTPS host allowlist including every redirect host, and model license acceptance. Defaults permit no download. Source URLs, hashes and file names may be overridden via artifact configuration for an audited mirror. Wrong hashes, missing models, or unaccepted license throw readable errors. Never set these flags merely to hide a missing model.

`RuntimeConfig` selects `sensevoice-mobile-20240717` by default, retaining the original exact production pins. For the explicitly approved Mac development artifact only, set `RC_ASR_ARTIFACT_PROFILE=reai-vibe-board-local-20261109`, `RC_ASR_LOCAL_ARTIFACTS_APPROVED=true`, `RC_ASR_LICENSE_ACCEPTED=true`, and `RC_ASR_ALLOW_DOWNLOAD=false`. The local model is **237115547 bytes / SHA256 12ca1a2ae7ecf3e0019ef2822307ee0b5cadc9196569e379b4c4026f8205276d**, not the default registry's 239233841-byte model. Neither digest is implicitly accepted as an alternative. The local profile has no download URIs/hosts and ignores the default registry URL overrides; it never falls back to downloading other weights. Approval does not imply license acceptance. Unknown/unapproved profiles fail explicitly.

`scripts/prepare_asr_models.py --profile reai-vibe-board-local-20261109 --source-directory /approved/sensevoice-int8 --vad-source /approved/silero_vad.onnx --verify-only --manifest-output /chosen/verified-manifest.json --accept-model-license` checks all three fixed pins without copying or downloading. Omit `--verify-only` and use `--directory` outside the repository to atomically copy verified local files. Metadata records the distinct profile, exact size/hash/path, and runtime defines; it is audit metadata, not a runtime remote manifest loader. No SenseVoice weights belong in Git.

Runtime configuration uses the bundled MIT Silero VAD artifact, also checked for exact size/hash. Standalone `AsrModelStore` callers can omit VAD, in which case bounded fixed-size chunks retain a boundary uncertainty and do **not** prove silence. No speaker model is installed. Missing/corrupt/unlicensed models produce `waitingForModel` progress with `errorCode`/`message`, then throw; the service does not persist source recordings or queue state itself. The repository/pipeline owner must retain the recording, present the reason and retry it after installation.

## File and continuous stream entry points

```dart
final asr = TranscriptionService(models: modelStore);
final transcript = await asr.transcribeFile(
  recordingPath, format: AudioFileFormat.adpcm,
  cancellation: token, onProgress: reportActualStage,
);
final event = recordEventFromTranscription(
  id: originalRecordId, title: recordingTitle,
  startedAt: actualRecordingStart, transcript: transcript,
);
```

The helper lives in `services/analysis/processed_transcript.dart`; persist `TranscriptionResult.toJson()` separately from the C-owned `RecordEvent`, preserving native metadata. `TranscriptionResult.fromJson` restores it. `RecordEvent.raw/dialog` only project text and clock ranges, not complete acoustic metadata.

For B's continuous BLE frames, create one `StreamingAudioSlicer` per uninterrupted recording. Call `addAdpcm` or `addPcm16`, never both. PCM may split across half-samples; ADPCM state persists across frames and output slices. The slicer returns immutable `PcmAudioSlice` with stable sequence, exact sample-based session offsets, and copied PCM16 bytes. Persist source slices through C first. Then call `transcribePcmBytes(slice.pcm16, temporaryDirectory: ..., sampleRate: slice.sampleRate)` or `transcribeFile` on C's persisted path. The memory entry creates only a private inference copy and deletes only that copy after completion; source slices are not deleted. `flush()` finishes a recording without invented padding and refuses truncated half-samples. A disconnect/new recording must create a new slicer and explicit session identity; never reset the ADPCM predictor on each frame.

Each file/PCM job currently creates a worker and reloads its model. This is functional but continuous-session load latency/power has not been measured, and a persistent warm recognizer optimization remains separate work. B/C/E own actual BLE subscriptions, file persistence, backpressure, record IDs and foreground/background policy. The D module does not subscribe to hardware itself.

## Resource and cancellation behavior

Defaults: mono8k/16k input or PCM16 stereo WAV downmix, maximum30 minutes and64 MiB input per file, maximum15-second recognition blocks,2 native threads,4 queued/active ASR jobs. WAV parsing respects arbitrary RIFF chunk positions and odd padding; compressed/float WAV and other sample rates are rejected explicitly.

Both SenseVoice and VAD explicitly use the CPU provider. The fixed Silero ONNX requires **16kHz**, despite the reference Dart service configuring 8kHz/256-sample windows for 8k input. That native configuration exits the process with `Expected sample rate 16000`. Before native inference, `AudioDecoder.forLocalModels` linearly upsamples 8k input to 16k (exact 2:1 sample count; duration/relative offsets unchanged), without modifying the source. VAD uses 512-sample windows. A VAD-verified empty speech plan returns empty text/ranges without allocating the ASR recognizer; ASR emptiness alone is never a silence claim.

Full-file decoded Float32 at the maximum30min/16k length alone occupies about109.86 MiB, in addition to source/PCM/model/native buffers. Encoder inputs are bounded per chunk, but whole-file decode is not constant-memory. Streaming15-second PCM slices are480000 bytes and bound the per-file audio cost. No iPhone peak RSS, real-time factor or power claim has been measured.

Cancellation/timeout is cooperative between native chunks. Native pointers never cross isolates, every stream/VAD/recognizer is released in `finally`, terminal result/error/exit use one mailbox, and the service serial lane waits for native cleanup. A native decode that itself hangs is not safely interruptible; `close()` may wait. No force-kill is used to pretend native resources were released. Cloud adapters also cannot guarantee server-side cancellation through A's plain `complete` API; cancelled responses are not applied, and no automatic retry spends additional requests.

## Model metadata limitations

Raw text is decoded with SenseVoice ITN disabled. Native `tokens`, token CTC `timestamps`, `lang`, `emotion` and `event` are copied verbatim when actually present. `TranscriptSegment.start/end` are input chunk offsets. `tokenTimestamps` are per-token time points relative to that chunk, not guaranteed word `[start,end]` boundaries. Emotion/audio-event tags are predictions for that chunk, not per-word emotion. Missing metadata stays empty/null. SenseVoiceSmall does not output speaker embeddings or recognized human identity; no fake A/B voice identity exists.

## Tests

```bash
export PATH=/home/ubuntu/flutter/bin:$HOME/.cargo/bin:$PATH
cd app
dart analyze lib/services/analysis lib/services/transcription lib/core/models/summary.dart test/services
flutter test test/services
```

The native inference test is explicitly opt-in and skipped without model+audio+license configuration:

```bash
ASR_LOCAL_TEST_MODEL_DIR=/approved/local-model-directory \
ASR_LOCAL_TEST_WAV=/approved/non-sensitive-fixture.wav \
ASR_LOCAL_ARTIFACTS_APPROVED=true \
ASR_MODEL_LICENSE_ACCEPTED=true \
ASR_NATIVE_LIBRARY_DIR=/directory/containing/libsherpa-onnx-c-api.dylib \
flutter --suppress-analytics test --no-pub test/services/local_models_native_opt_in_test.dart
```

The optional native library setting is a **directory**, not the file path: on macOS it contains the dylib, on iOS it is the framework root. On 2026-11-09 this opt-in test passed actual Mac CPU recognition of upstream `test_wavs/zh.wav` plus generated 8k/16k silence. This is not an iPhone/device validation, accuracy benchmark or user-recording test. No audio was uploaded and no cloud ASR was invoked.
