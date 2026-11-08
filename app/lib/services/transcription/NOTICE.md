# Local ASR and audio decoding notices

The integration uses the `sherpa_onnx` Flutter/Dart native plugin, whose code is distributed under Apache-2.0: https://github.com/k2-fsa/sherpa-onnx . Its plugin includes the upstream license files. No fllama, keyboard-native package, or model weights are bundled by this module.

SenseVoiceSmall **model weights** have a separate license. The original model card labels them `license: other`, `license_name: model-license`, linking https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE . Review the artifact's pinned license and deployment/distribution requirements before setting `AsrModelStore.licenseAccepted`. Retain original model names, authors and source information. Upstream model: FunAudioLLM/SenseVoiceSmall, https://huggingface.co/FunAudioLLM/SenseVoiceSmall . The proposed ONNX conversion source is csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17, https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17 . A mirror must provide files that match the configured size and SHA256; public model availability is not an implicit license acceptance or completed hash verification.

Model sizes and default hashes were audited from the authorized read-only ReAI mobile `lib/services/model_manager/model_registry.dart` at source revision 7f9d13a. Native SenseVoice configuration/VAD/worker lifecycle were consulted in that project's `sherpa_stt_service.dart` and `long_audio_transcription.dart`. This module contains a new bounded file pipeline, not a wholesale copy of the reference app or its keyboard dependencies. No license assumption about the full reference mobile app is made.

The standard IMA ADPCM tables and low-nibble-first continuous decoding behavior were cross-checked with ReAI card SDK `src/audio.rs` at badbbb0b/v0.0.6. For that reused protocol/algorithm material, retain the SDK's MIT notice below.

## ReAI card SDK MIT notice

Copyright (c) 2026 ReAI

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
