import Darwin
import Flutter
import Foundation
import UIKit

#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(llama)
import llama
#endif

/// 端侧大小模型原生推理桥：
/// - `com.reai.recordingcard/local_llm`：能力探测、加载/卸载、取消与退后台 Metal 排空；
/// - `com.reai.recordingcard/local_llm_stream`：流式增量 token 推送（delta / done / error）。
///
/// 工程约束：
/// - 在 `UIApplication.willResignActiveNotification` 与内存警告第一时间置取消位、排空 GPU 并卸载模型，
///   防止 iOS 后台提交 Metal 命令触发 `SIGABRT` 或 Jetsam 杀进程；
/// - 未链接 `llama.xcframework` 时 `llamaRuntimeLinked = false`，调用 `loadModel(llama_gguf)` 明确报错，绝不返回假文本。
final class LocalLlmBridge: NSObject, FlutterStreamHandler {
  static let shared = LocalLlmBridge()

  private let methodChannelName = "com.reai.recordingcard/local_llm"
  private let eventChannelName = "com.reai.recordingcard/local_llm_stream"
  private let workerQueue = DispatchQueue(
    label: "com.reai.recordingcard.localllm.worker",
    qos: .userInitiated
  )
  private let stateLock = NSLock()

  private var methodChannel: FlutterMethodChannel?
  private var eventChannel: FlutterEventChannel?
  private var eventSink: FlutterEventSink?

  private var activeEngine: String?
  private var activeModelPath: String?
  private var cancelledRequestIds = Set<String>()
  private var currentRequestId: String?
  private var isBackgroundDraining = false

  #if canImport(llama)
  private var llamaModel: OpaquePointer?
  private var llamaCtx: OpaquePointer?
  #endif

  #if canImport(FoundationModels)
  private var foundationTask: Task<Void, Never>?
  #endif

  private override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleMemoryWarning),
      name: UIApplication.didReceiveMemoryWarningNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func register(with messenger: FlutterBinaryMessenger) {
    let mCh = FlutterMethodChannel(
      name: methodChannelName,
      binaryMessenger: messenger
    )
    mCh.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    methodChannel = mCh

    let eCh = FlutterEventChannel(
      name: eventChannelName,
      binaryMessenger: messenger
    )
    eCh.setStreamHandler(self)
    eventChannel = eCh
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    stateLock.lock()
    eventSink = events
    stateLock.unlock()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stateLock.lock()
    eventSink = nil
    stateLock.unlock()
    return nil
  }

  @objc private func handleWillResignActive() {
    pauseAndDrainSync()
  }

  @objc private func handleMemoryWarning() {
    pauseAndDrainSync()
    unloadSync()
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "capabilities":
      result(buildCapabilitiesPayload())

    case "loadModel":
      guard let args = call.arguments as? [String: Any],
            let engine = args["engine"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "缺少 engine 参数", details: nil))
        return
      }
      let modelPath = args["modelPath"] as? String
      let nCtx = (args["nCtx"] as? NSNumber)?.intValue ?? 1024
      let useMetal = (args["useMetal"] as? Bool) ?? true
      let quantizeKvQ8 = (args["quantizeKvQ8"] as? Bool) ?? true
      workerQueue.async { [weak self] in
        guard let self else { return }
        let err = self.loadModelSync(
          engine: engine,
          modelPath: modelPath,
          nCtx: nCtx,
          useMetal: useMetal,
          quantizeKvQ8: quantizeKvQ8
        )
        DispatchQueue.main.async {
          if let err {
            result(err)
          } else {
            result(nil)
          }
        }
      }

    case "unloadModel":
      workerQueue.async { [weak self] in
        self?.unloadSync()
        DispatchQueue.main.async { result(nil) }
      }

    case "pauseAndDrain":
      pauseAndDrainSync()
      workerQueue.async { [weak self] in
        self?.unloadSync()
        DispatchQueue.main.async { result(nil) }
      }

    case "startGenerate":
      guard let args = call.arguments as? [String: Any],
            let requestId = args["requestId"] as? String,
            let systemPrompt = args["systemPrompt"] as? String,
            let userPrompt = args["userPrompt"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "缺少生成参数", details: nil))
        return
      }
      let maxTokens = (args["maxTokens"] as? NSNumber)?.intValue ?? 1024
      let temperature = (args["temperature"] as? NSNumber)?.doubleValue ?? 0.2
      result(nil)
      workerQueue.async { [weak self] in
        self?.runGenerate(
          requestId: requestId,
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          maxTokens: maxTokens,
          temperature: temperature
        )
      }

    case "cancelGenerate":
      let args = call.arguments as? [String: Any]
      let requestId = args?["requestId"] as? String
      markCancelled(requestId)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func buildCapabilitiesPayload() -> [String: Any] {
    let physical = UInt64(ProcessInfo.processInfo.physicalMemory)
    let available = UInt64(os_proc_available_memory())
    let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    let machine = Self.machineIdentifier()
    let thermal = Self.thermalLabel(ProcessInfo.processInfo.thermalState)

    var supportsFoundation = false
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      supportsFoundation = SystemLanguageModel.default.isAvailable
    }
    #endif

    var llamaLinked = false
    #if canImport(llama)
    llamaLinked = true
    #endif

    return [
      "platform": "ios",
      "physicalMemoryBytes": NSNumber(value: physical),
      "availableMemoryBytes": NSNumber(value: available),
      "osMajorVersion": osMajor,
      "machineModel": machine,
      "supportsFoundationModels": supportsFoundation,
      "llamaRuntimeLinked": llamaLinked,
      "thermalState": thermal,
    ]
  }

  private func loadModelSync(
    engine: String,
    modelPath: String?,
    nCtx: Int,
    useMetal: Bool,
    quantizeKvQ8: Bool
  ) -> FlutterError? {
    stateLock.lock()
    isBackgroundDraining = false
    stateLock.unlock()

    if engine == "apple_foundation" {
      #if canImport(FoundationModels)
      if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
        unloadSync()
        stateLock.lock()
        activeEngine = engine
        activeModelPath = nil
        stateLock.unlock()
        return nil
      }
      #endif
      return FlutterError(
        code: "FOUNDATION_MODELS_UNAVAILABLE",
        message: "当前系统版本或机型不支持 Apple Foundation Models",
        details: nil
      )
    }

    guard let path = modelPath, !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
      return FlutterError(
        code: "MODEL_NOT_INSTALLED",
        message: "本地 GGUF 模型文件不存在：\(modelPath ?? "")",
        details: nil
      )
    }

    #if canImport(llama)
    unloadSync()
    llama_backend_init()
    var mparams = llama_model_default_params()
    mparams.n_gpu_layers = useMetal ? 99 : 0
    guard let model = llama_model_load_from_file(path, mparams) else {
      return FlutterError(
        code: "LLAMA_LOAD_FAILED",
        message: "无法加载 GGUF 模型文件",
        details: nil
      )
    }
    var cparams = llama_context_default_params()
    cparams.n_ctx = UInt32(max(512, nCtx))
    cparams.n_batch = 256
    if quantizeKvQ8 {
      cparams.type_k = GGML_TYPE_Q8_0
      cparams.type_v = GGML_TYPE_Q8_0
    }
    guard let ctx = llama_init_from_model(model, cparams) else {
      llama_model_free(model)
      return FlutterError(
        code: "LLAMA_CTX_FAILED",
        message: "初始化 llama 上下文失败（内存可能不足）",
        details: nil
      )
    }
    stateLock.lock()
    llamaModel = model
    llamaCtx = ctx
    activeEngine = engine
    activeModelPath = path
    stateLock.unlock()
    return nil
    #else
    return FlutterError(
      code: "LOCAL_LLM_RUNTIME_UNAVAILABLE",
      message: "当前安装包未链接 llama.xcframework，无法运行 GGUF 端侧模型（请按 PR 文档接入 XCFramework 或走云端/iOS 26 系统模型）",
      details: ["nCtx": nCtx, "useMetal": useMetal, "quantizeKvQ8": quantizeKvQ8]
    )
    #endif
  }

  private func pauseAndDrainSync() {
    stateLock.lock()
    isBackgroundDraining = true
    if let req = currentRequestId {
      cancelledRequestIds.insert(req)
    }
    stateLock.unlock()

    #if canImport(FoundationModels)
    foundationTask?.cancel()
    foundationTask = nil
    #endif

    #if canImport(llama)
    if let ctx = llamaCtx {
      llama_synchronize(ctx)
    }
    #endif
  }

  private func unloadSync() {
    #if canImport(FoundationModels)
    foundationTask?.cancel()
    foundationTask = nil
    #endif

    #if canImport(llama)
    stateLock.lock()
    let ctx = llamaCtx
    let model = llamaModel
    llamaCtx = nil
    llamaModel = nil
    activeEngine = nil
    activeModelPath = nil
    stateLock.unlock()
    if let ctx {
      llama_synchronize(ctx)
      llama_free(ctx)
    }
    if let model {
      llama_model_free(model)
    }
    #else
    stateLock.lock()
    activeEngine = nil
    activeModelPath = nil
    stateLock.unlock()
    #endif

    malloc_zone_pressure_relief(nil, 0)
  }

  private func markCancelled(_ requestId: String?) {
    stateLock.lock()
    if let id = requestId, !id.isEmpty {
      cancelledRequestIds.insert(id)
    } else if let cur = currentRequestId {
      cancelledRequestIds.insert(cur)
    }
    stateLock.unlock()
  }

  private func isCancelled(_ requestId: String) -> Bool {
    stateLock.lock()
    let cancelled = isBackgroundDraining || cancelledRequestIds.contains(requestId)
    stateLock.unlock()
    return cancelled
  }

  private func runGenerate(
    requestId: String,
    systemPrompt: String,
    userPrompt: String,
    maxTokens: Int,
    temperature: Double
  ) {
    stateLock.lock()
    currentRequestId = requestId
    let engine = activeEngine
    stateLock.unlock()

    defer {
      stateLock.lock()
      if currentRequestId == requestId {
        currentRequestId = nil
      }
      cancelledRequestIds.remove(requestId)
      stateLock.unlock()
    }

    if engine == "apple_foundation" {
      #if canImport(FoundationModels)
      if #available(iOS 26.0, *) {
        let sem = DispatchSemaphore(value: 0)
        foundationTask = Task {
          do {
            let session = LanguageModelSession(instructions: systemPrompt)
            var lastText = ""
            let stream = session.streamResponse(to: userPrompt)
            for try await partial in stream {
              if self.isCancelled(requestId) { break }
              let current = partial.content
              if current.count > lastText.count, current.hasPrefix(lastText) {
                let delta = String(current.dropFirst(lastText.count))
                lastText = current
                self.emitEvent([
                  "requestId": requestId,
                  "kind": "delta",
                  "text": delta,
                ])
              }
            }
            self.emitEvent(["requestId": requestId, "kind": "done"])
          } catch {
            self.emitEvent([
              "requestId": requestId,
              "kind": "error",
              "code": "FOUNDATION_GENERATE_FAILED",
              "message": error.localizedDescription,
            ])
          }
          sem.signal()
        }
        sem.wait()
        return
      }
      #endif
      emitEvent([
        "requestId": requestId,
        "kind": "error",
        "code": "FOUNDATION_MODELS_UNAVAILABLE",
        "message": "系统内置模型不可用",
      ])
      return
    }

    #if canImport(llama)
    stateLock.lock()
    let ctx = llamaCtx
    let model = llamaModel
    stateLock.unlock()
    guard let ctx, let model else {
      emitEvent([
        "requestId": requestId,
        "kind": "error",
        "code": "MODEL_NOT_LOADED",
        "message": "端侧模型尚未加载",
      ])
      return
    }

    let prompt = "<|im_start|>system\n\(systemPrompt)<|im_end|>\n<|im_start|>user\n\(userPrompt)<|im_end|>\n<|im_start|>assistant\n"
    let vocab = llama_model_get_vocab(model)
    let utf8Count = prompt.utf8.count
    let maxPromptTokens = Int32(utf8Count + 32)
    var promptTokens = [llama_token](repeating: 0, count: Int(maxPromptTokens))
    let tokenCount = prompt.withCString { cStr in
      llama_tokenize(vocab, cStr, Int32(utf8Count), &promptTokens, maxPromptTokens, true, true)
    }
    guard tokenCount > 0 else {
      emitEvent([
        "requestId": requestId,
        "kind": "error",
        "code": "TOKENIZE_FAILED",
        "message": "输入文本分词失败",
      ])
      return
    }
    promptTokens = Array(promptTokens.prefix(Int(tokenCount)))

    let sparams = llama_sampler_chain_default_params()
    guard let sampler = llama_sampler_chain_init(sparams) else {
      emitEvent([
        "requestId": requestId,
        "kind": "error",
        "code": "SAMPLER_FAILED",
        "message": "初始化采样器失败",
      ])
      return
    }
    defer { llama_sampler_free(sampler) }
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(Float(temperature)))
    llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))

    var batch = llama_batch_get_one(&promptTokens, tokenCount)
    if llama_decode(ctx, batch) != 0 {
      emitEvent([
        "requestId": requestId,
        "kind": "error",
        "code": "DECODE_FAILED",
        "message": "Prefill 解码失败",
      ])
      return
    }

    var generated = 0
    var pieceBuf = [CChar](repeating: 0, count: 128)
    while generated < maxTokens {
      if isCancelled(requestId) { break }
      var nextToken = llama_sampler_sample(sampler, ctx, -1)
      if llama_vocab_is_eog(vocab, nextToken) { break }
      let n = llama_token_to_piece(vocab, nextToken, &pieceBuf, Int32(pieceBuf.count), 0, false)
      if n > 0 {
        let data = Data(bytes: pieceBuf, count: Int(n))
        if let piece = String(data: data, encoding: .utf8), !piece.isEmpty {
          emitEvent([
            "requestId": requestId,
            "kind": "delta",
            "text": piece,
          ])
        }
      }
      batch = llama_batch_get_one(&nextToken, 1)
      if llama_decode(ctx, batch) != 0 { break }
      generated += 1
    }
    llama_synchronize(ctx)
    emitEvent(["requestId": requestId, "kind": "done"])
    #else
    emitEvent([
      "requestId": requestId,
      "kind": "error",
      "code": "LOCAL_LLM_RUNTIME_UNAVAILABLE",
      "message": "当前安装包未链接 llama.xcframework",
    ])
    #endif
  }

  private func emitEvent(_ payload: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(payload)
    }
  }

  private static func machineIdentifier() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    return withUnsafePointer(to: &systemInfo.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) {
        String(validatingUTF8: $0) ?? "unknown"
      }
    }
  }

  private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "nominal"
    }
  }
}
