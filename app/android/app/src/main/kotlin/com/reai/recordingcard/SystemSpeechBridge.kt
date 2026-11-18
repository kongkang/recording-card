package com.reai.recordingcard

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Resources
import android.media.AudioFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.annotation.RequiresApi
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Android 系统内置端侧语音识别桥接（channel: `com.reai.recordingcard/system_speech`）。
 *
 * 严格遵循本地隐私红线：
 * - 仅在 Android 13+（API 33+）且系统端侧识别服务可用、且底层包名非三星 Bixby/SMT
 *   （避免忽略 `EXTRA_AUDIO_SOURCE` 后静默回退打开物理麦克风）时启用系统内置模型；
 * - 全程使用 `SpeechRecognizer.createOnDeviceSpeechRecognizer`，音频仅注入本地剥离 WAV 头的 16k PCM 流；
 * - 国行小米 / OPPO / vivo / 荣耀 / 华为等未开放标准端侧识别服务时如实返回不支持与设备型号信息，由 UI 引导下载 SenseVoice。
 */
class SystemSpeechBridge(private val activity: Activity) {
    companion object {
        private const val CHANNEL_NAME = "com.reai.recordingcard/system_speech"
        const val REQ_AUDIO_PERM = 4092

        private const val ERROR_LANGUAGE_NOT_SUPPORTED = 12
        private const val ERROR_LANGUAGE_UNAVAILABLE = 13
    }

    private data class DeviceProfile(
        val osMajorVersion: Int,
        val sdkInt: Int,
        val brandId: String,
        val brandLabel: String,
        val deviceSummary: String,
        val onDeviceServicePackage: String,
        val isBixbyBlocked: Boolean,
        val supportsModernSystemAsr: Boolean,
        val engineName: String,
        val unsupportedReason: String,
    )

    private data class WavPcmData(
        val sampleRate: Int,
        val channels: Int,
        val monoSamples: ShortArray,
    )

    private data class SubWindow(
        val startSample: Int,
        val endSample: Int,
    )

    private class SubWindowException(val code: String, override val message: String) : Exception(message)

    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val seqCounter = AtomicInteger(0)

    private var channel: MethodChannel? = null
    private var pendingPermResult: MethodChannel.Result? = null
    private var activeDownloadRecognizer: SpeechRecognizer? = null

    fun register(messenger: BinaryMessenger) {
        val ch = MethodChannel(messenger, CHANNEL_NAME)
        ch.setMethodCallHandler { call, result -> handle(call, result) }
        channel = ch
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQ_AUDIO_PERM) return false
        val pending = pendingPermResult
        pendingPermResult = null
        if (pending != null) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            pending.success(if (granted) "granted" else "denied")
        }
        return true
    }

    fun destroy() {
        channel?.setMethodCallHandler(null)
        channel = null
        mainHandler.post {
            activeDownloadRecognizer?.destroy()
            activeDownloadRecognizer = null
        }
        worker.shutdownNow()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> queryCapabilities(result)
            "requestAuthorization" -> handleRequestAuthorization(result)
            "downloadSystemModel" -> {
                val language = call.argument<String>("language") ?: "zh"
                handleDownloadSystemModel(language, result)
            }
            "transcribeWav" -> {
                val wavPath = call.argument<String>("wavPath")?.trim().orEmpty()
                val language = call.argument<String>("language") ?: "auto"
                handleTranscribeWav(wavPath, language, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun isAudioPermissionGranted(): Boolean =
        ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun authStatusText(): String =
        if (isAudioPermissionGranted()) "granted" else "notDetermined"

    private fun handleRequestAuthorization(result: MethodChannel.Result) {
        if (isAudioPermissionGranted()) {
            result.success("granted")
            return
        }
        if (pendingPermResult != null) {
            result.success("denied")
            return
        }
        pendingPermResult = result
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            REQ_AUDIO_PERM,
        )
    }

    private fun queryCapabilities(result: MethodChannel.Result) {
        val profile = detectDeviceProfile()
        if (!profile.supportsModernSystemAsr || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(
                buildCapabilityMap(
                    profile = profile,
                    offlinePackInstalled = false,
                    canDownloadOfflinePack = false,
                ),
            )
            return
        }
        checkChineseSupportApi33(profile) { installed, canDownload ->
            result.success(
                buildCapabilityMap(
                    profile = profile,
                    offlinePackInstalled = installed,
                    canDownloadOfflinePack = canDownload,
                ),
            )
        }
    }

    private fun buildCapabilityMap(
        profile: DeviceProfile,
        offlinePackInstalled: Boolean,
        canDownloadOfflinePack: Boolean,
    ): Map<String, Any> = mapOf(
        "platform" to "android",
        "osMajorVersion" to profile.osMajorVersion,
        "sdkInt" to profile.sdkInt,
        "brandId" to profile.brandId,
        "deviceSummary" to profile.deviceSummary,
        "engineName" to profile.engineName,
        "onDeviceServicePackage" to profile.onDeviceServicePackage,
        "supportsModernSystemAsr" to profile.supportsModernSystemAsr,
        "offlinePackInstalled" to offlinePackInstalled,
        "canDownloadOfflinePack" to canDownloadOfflinePack,
        "unsupportedReason" to profile.unsupportedReason,
        "authStatus" to authStatusText(),
    )

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun checkChineseSupportApi33(
        profile: DeviceProfile,
        onDone: (installed: Boolean, canDownload: Boolean) -> Unit,
    ) {
        val finished = AtomicBoolean(false)
        var sr: SpeechRecognizer? = null
        val timeout = Runnable {
            if (finished.compareAndSet(false, true)) {
                sr?.destroy()
                onDone(true, false)
            }
        }
        try {
            sr = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-CN")
            }
            mainHandler.postDelayed(timeout, 1000L)
            sr.checkRecognitionSupport(
                intent,
                worker,
                object : RecognitionSupportCallback {
                    override fun onSupportResult(support: RecognitionSupport) {
                        val installedTags = support.installedOnDeviceLanguages
                        val supportedTags = support.supportedOnDeviceLanguages
                        val pendingTags = support.pendingOnDeviceLanguages
                        val hasZhInstalled = matchesChineseTag(installedTags)
                        val hasZhDownloadable = matchesChineseTag(supportedTags) || matchesChineseTag(pendingTags)
                        val finalInstalled = hasZhInstalled || (!hasZhDownloadable && installedTags.isEmpty())
                        mainHandler.post {
                            mainHandler.removeCallbacks(timeout)
                            if (finished.compareAndSet(false, true)) {
                                sr?.destroy()
                                onDone(finalInstalled, !hasZhInstalled && hasZhDownloadable)
                            }
                        }
                    }

                    override fun onError(error: Int) {
                        mainHandler.post {
                            mainHandler.removeCallbacks(timeout)
                            if (finished.compareAndSet(false, true)) {
                                sr?.destroy()
                                // 部分厂商实现不支持 checkRecognitionSupport，但端侧识别仍可直接调用
                                onDone(true, false)
                            }
                        }
                    }
                },
            )
        } catch (_: Throwable) {
            mainHandler.removeCallbacks(timeout)
            if (finished.compareAndSet(false, true)) {
                sr?.destroy()
                onDone(true, false)
            }
        }
    }

    private fun matchesChineseTag(tags: List<String>): Boolean =
        tags.any { tag ->
            val low = tag.lowercase(Locale.ROOT)
            low.startsWith("zh") || low.startsWith("cmn")
        }

    private fun handleDownloadSystemModel(language: String, result: MethodChannel.Result) {
        val profile = detectDeviceProfile()
        if (!profile.supportsModernSystemAsr || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(false)
            return
        }
        triggerDownloadApi33(resolveLocaleTag(language))
        result.success(true)
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun triggerDownloadApi33(localeTag: String) {
        mainHandler.post {
            try {
                activeDownloadRecognizer?.destroy()
                val sr = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
                activeDownloadRecognizer = sr
                val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE, localeTag)
                }
                sr.triggerModelDownload(intent)
                mainHandler.postDelayed({
                    if (activeDownloadRecognizer === sr) {
                        sr.destroy()
                        activeDownloadRecognizer = null
                    }
                }, 4000L)
            } catch (_: Throwable) {
                // 静默忽略拉起系统语言包下载时的非关键异常
            }
        }
    }

    private fun handleTranscribeWav(
        wavPath: String,
        language: String,
        result: MethodChannel.Result,
    ) {
        if (wavPath.isEmpty()) {
            result.error("INVALID_ARGS", "缺少 wavPath 参数", null)
            return
        }
        val wavFile = File(wavPath)
        if (!wavFile.exists()) {
            result.error("FILE_NOT_FOUND", "音频文件不存在：$wavPath", null)
            return
        }
        val profile = detectDeviceProfile()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || !profile.supportsModernSystemAsr) {
            val reason = profile.unsupportedReason.ifEmpty {
                "当前 Android 设备不支持系统内置端侧语音转写，请下载 SenseVoice 增强模型"
            }
            result.error("SYSTEM_ASR_UNSUPPORTED", reason, null)
            return
        }
        if (!isAudioPermissionGranted()) {
            result.error(
                "PERMISSION_DENIED",
                "未开启麦克风权限，请在系统设置中开启或切换 SenseVoice 增强模型",
                null,
            )
            return
        }

        val localeTag = resolveLocaleTag(language)
        worker.execute {
            try {
                val payload = transcribeWavInBackgroundApi33(wavFile, localeTag)
                mainHandler.post { result.success(payload) }
            } catch (e: SubWindowException) {
                mainHandler.post { result.error(e.code, e.message, null) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error("SYSTEM_ASR_FAILED", t.message ?: "系统语音识别失败", null)
                }
            }
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun transcribeWavInBackgroundApi33(
        wavFile: File,
        localeTag: String,
    ): Map<String, Any> {
        val wav = parseWavPcm16(wavFile.readBytes())
        if (wav.monoSamples.isEmpty()) {
            return mapOf(
                "text" to "",
                "tokens" to emptyList<String>(),
                "timestampsMs" to emptyList<Int>(),
                "lang" to localeTag,
            )
        }

        val windows = buildEnergyAlignedWindows(wav.monoSamples, wav.sampleRate)
        val combinedText = StringBuilder()
        val allTokens = ArrayList<String>()
        val allTimestamps = ArrayList<Int>()

        for (win in windows) {
            if (!hasVoiceEnergy(wav.monoSamples, win.startSample, win.endSample)) {
                continue
            }
            val subText = transcribeWindowApi33(
                samples = wav.monoSamples,
                start = win.startSample,
                end = win.endSample,
                sampleRate = wav.sampleRate,
                localeTag = localeTag,
            ).trim()
            if (subText.isEmpty()) continue

            val winStartMs = (win.startSample * 1000L / wav.sampleRate).toInt()
            val winEndMs = (win.endSample * 1000L / wav.sampleRate).toInt()
            appendWindowTranscript(
                text = subText,
                winStartMs = winStartMs,
                winEndMs = max(winStartMs + 1, winEndMs),
                combined = combinedText,
                outTokens = allTokens,
                outTimestamps = allTimestamps,
            )
        }

        return mapOf(
            "text" to combinedText.toString(),
            "tokens" to allTokens,
            "timestampsMs" to allTimestamps,
            "lang" to localeTag,
        )
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun transcribeWindowApi33(
        samples: ShortArray,
        start: Int,
        end: Int,
        sampleRate: Int,
        localeTag: String,
    ): String {
        val pcmFile = File(activity.cacheDir, "rc_asr_win_${seqCounter.incrementAndGet()}.pcm")
        writeLittleEndianPcm16(pcmFile, samples, start, end)

        var pfd: ParcelFileDescriptor? = null
        val srRef = AtomicReference<SpeechRecognizer?>(null)
        val latch = CountDownLatch(1)
        val textRef = AtomicReference("")
        val partialRef = AtomicReference("")
        val errorCodeRef = AtomicInteger(0)

        try {
            pfd = ParcelFileDescriptor.open(pcmFile, ParcelFileDescriptor.MODE_READ_ONLY)
            val audioSourcePfd = pfd
            mainHandler.post {
                try {
                    val sr = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
                    srRef.set(sr)
                    sr.setRecognitionListener(object : RecognitionListener {
                        override fun onReadyForSpeech(params: Bundle?) {}
                        override fun onBeginningOfSpeech() {}
                        override fun onRmsChanged(rmsdB: Float) {}
                        override fun onBufferReceived(buffer: ByteArray?) {}
                        override fun onEndOfSpeech() {}
                        override fun onEvent(eventType: Int, params: Bundle?) {}

                        override fun onPartialResults(partialResults: Bundle?) {
                            val items = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                            val candidate = items?.firstOrNull()?.trim().orEmpty()
                            if (candidate.isNotEmpty()) {
                                partialRef.set(candidate)
                            }
                        }

                        override fun onResults(results: Bundle?) {
                            val items = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                            val finalText = items?.firstOrNull()?.trim().orEmpty()
                            textRef.set(finalText.ifEmpty { partialRef.get() })
                            latch.countDown()
                        }

                        override fun onError(error: Int) {
                            errorCodeRef.set(error)
                            latch.countDown()
                        }
                    })

                    val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                        putExtra(RecognizerIntent.EXTRA_LANGUAGE, localeTag)
                        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                        putExtra(
                            RecognizerIntent.EXTRA_ENABLE_FORMATTING,
                            RecognizerIntent.FORMATTING_OPTIMIZE_QUALITY,
                        )
                        putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, audioSourcePfd)
                        putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                        putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                        putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, sampleRate)
                    }
                    sr.startListening(intent)
                } catch (_: Throwable) {
                    errorCodeRef.set(SpeechRecognizer.ERROR_CLIENT)
                    latch.countDown()
                }
            }

            val completed = latch.await(25L, TimeUnit.SECONDS)
            if (!completed) {
                throw SubWindowException("SYSTEM_ASR_TIMEOUT", "系统端侧语音识别超时")
            }

            val err = errorCodeRef.get()
            if (err == 0) {
                return textRef.get()
            }
            if (err == SpeechRecognizer.ERROR_NO_MATCH || err == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) {
                return partialRef.get()
            }
            if (err == ERROR_LANGUAGE_NOT_SUPPORTED || err == ERROR_LANGUAGE_UNAVAILABLE) {
                triggerDownloadApi33(localeTag)
                throw SubWindowException(
                    "MODEL_NOT_INSTALLED",
                    "系统离线语音包未就绪，已拉起系统下载；稍后重试或下载 SenseVoice 增强模型",
                )
            }
            throw SubWindowException("SYSTEM_ASR_FAILED", "系统语音识别失败（错误码 $err）")
        } finally {
            mainHandler.post {
                srRef.getAndSet(null)?.destroy()
            }
            try {
                pfd?.close()
            } catch (_: Throwable) {
            }
            pcmFile.delete()
        }
    }

    private fun detectDeviceProfile(): DeviceProfile {
        val sdkInt = Build.VERSION.SDK_INT
        val osMajor = parseMajorInt(Build.VERSION.RELEASE, sdkInt)
        val manufacturer = (Build.MANUFACTURER ?: "").trim()
        val brand = (Build.BRAND ?: "").trim()
        val model = (Build.MODEL ?: "").trim()
        val lowMfr = manufacturer.lowercase(Locale.ROOT)
        val lowBrand = brand.lowercase(Locale.ROOT)
        val combined = "$lowMfr $lowBrand"

        val hyperOsVer = readSysProp("ro.mi.os.version.name")
        val miuiVer = readSysProp("ro.miui.ui.version.name")
        val colorOsVer = readSysProp("ro.build.version.opporom")
        val originOsVer = readSysProp("ro.vivo.os.build.display.id")
        val magicOsVer = readSysProp("ro.build.version.magic")
        val harmonyVer = readSysProp("hw_sc.build.platform.version")
        val emuiVer = readSysProp("ro.build.version.emui")
        val oneUiVer = readSysProp("ro.build.version.oneui")

        val brandId: String
        val brandLabel: String
        val romLabel: String
        when {
            combined.contains("google") -> {
                brandId = "pixel"
                brandLabel = "Google Pixel"
                romLabel = "Android ${Build.VERSION.RELEASE}"
            }
            combined.contains("samsung") -> {
                brandId = "samsung"
                brandLabel = "三星 Galaxy"
                romLabel = if (oneUiVer.isNotEmpty()) "One UI" else "Android ${Build.VERSION.RELEASE}"
            }
            combined.contains("xiaomi") || combined.contains("redmi") || combined.contains("poco") -> {
                brandId = "xiaomi"
                brandLabel = if (lowBrand.contains("redmi")) "Redmi" else "小米"
                romLabel = when {
                    hyperOsVer.isNotEmpty() -> "澎湃 HyperOS $hyperOsVer"
                    miuiVer.isNotEmpty() -> "MIUI $miuiVer"
                    else -> "澎湃 HyperOS / MIUI"
                }
            }
            combined.contains("oppo") || combined.contains("oneplus") || combined.contains("realme") -> {
                brandId = "oppo"
                brandLabel = when {
                    lowBrand.contains("oneplus") -> "一加 OnePlus"
                    lowBrand.contains("realme") -> "realme"
                    else -> "OPPO"
                }
                romLabel = if (colorOsVer.isNotEmpty()) "ColorOS $colorOsVer" else "ColorOS"
            }
            combined.contains("vivo") || combined.contains("iqoo") -> {
                brandId = "vivo"
                brandLabel = if (lowBrand.contains("iqoo")) "iQOO" else "vivo"
                romLabel = if (originOsVer.isNotEmpty()) "OriginOS" else "OriginOS / Funtouch OS"
            }
            combined.contains("honor") -> {
                brandId = "honor"
                brandLabel = "荣耀 HONOR"
                romLabel = if (magicOsVer.isNotEmpty()) "MagicOS $magicOsVer" else "MagicOS"
            }
            combined.contains("huawei") -> {
                brandId = "huawei"
                brandLabel = "华为 HUAWEI"
                romLabel = when {
                    harmonyVer.isNotEmpty() -> "HarmonyOS $harmonyVer"
                    emuiVer.isNotEmpty() -> "EMUI"
                    else -> "HarmonyOS"
                }
            }
            else -> {
                brandId = "other"
                brandLabel = manufacturer.ifEmpty { brand.ifEmpty { "Android" } }
                romLabel = "Android ${Build.VERSION.RELEASE}"
            }
        }

        val deviceSummary = buildString {
            append(brandLabel)
            if (model.isNotEmpty() && !model.equals(brandLabel, ignoreCase = true)) {
                append(' ').append(model)
            }
            append(" · ").append(romLabel)
        }

        val servicePkg = readDefaultOnDeviceServicePackage()
        val lowServicePkg = servicePkg.lowercase(Locale.ROOT)
        val isBixby = lowServicePkg.contains("bixby") || lowServicePkg.startsWith("com.samsung.smt")
        val onDeviceApiAvailable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)
            } catch (_: Throwable) {
                false
            }
        } else {
            false
        }

        val supportsModern =
            sdkInt >= Build.VERSION_CODES.TIRAMISU &&
                onDeviceApiAvailable &&
                !isBixby

        val engineName = if (supportsModern) {
            when {
                lowServicePkg.startsWith("com.google.android.as") ->
                    "Android 系统端侧语音（System Intelligence）"
                lowServicePkg.startsWith("com.google.android.tts") ->
                    "Google 端侧离线语音引擎"
                else ->
                    "$brandLabel 系统内置语音引擎"
            }
        } else {
            ""
        }

        val unsupportedReason = if (supportsModern) {
            ""
        } else {
            buildUnsupportedReason(
                sdkInt = sdkInt,
                brandId = brandId,
                brandLabel = brandLabel,
                romLabel = romLabel,
                isBixby = isBixby,
            )
        }

        return DeviceProfile(
            osMajorVersion = osMajor,
            sdkInt = sdkInt,
            brandId = brandId,
            brandLabel = brandLabel,
            deviceSummary = deviceSummary,
            onDeviceServicePackage = servicePkg,
            isBixbyBlocked = isBixby,
            supportsModernSystemAsr = supportsModern,
            engineName = engineName,
            unsupportedReason = unsupportedReason,
        )
    }

    private fun buildUnsupportedReason(
        sdkInt: Int,
        brandId: String,
        brandLabel: String,
        romLabel: String,
        isBixby: Boolean,
    ): String {
        if (sdkInt < Build.VERSION_CODES.TIRAMISU) {
            return "已识别本机为 $brandLabel（Android ${Build.VERSION.RELEASE}），系统版本低于 Android 13，不支持音频文件级端侧转写；请下载纯端侧 SenseVoice 增强模型。"
        }
        if (isBixby) {
            return "已识别本机为 $brandLabel（Bixby 语音组件），三星 Bixby 端侧接口会忽略离线音频文件并误开手机麦克风；为防串音与隐私风险，请下载 SenseVoice 增强模型。"
        }
        return when (brandId) {
            "xiaomi" ->
                "已识别本机为 $brandLabel（$romLabel），当前未开放免签名端侧音频文件转写服务；音频不上传小爱云端，请下载 SenseVoice 增强模型。"
            "oppo" ->
                "已识别本机为 $brandLabel（$romLabel），当前未开启 Google 端侧语音且 ColorOS AIUnit 需系统白名单；请下载 SenseVoice 增强模型。"
            "vivo" ->
                "已识别本机为 $brandLabel（$romLabel），OriginOS 离线识别接口未向第三方开放标准文件流；请下载 SenseVoice 增强模型。"
            "honor" ->
                "已识别本机为 $brandLabel（$romLabel），当前设备未启用标准端侧识别服务，请下载 SenseVoice 增强模型。"
            "huawei" ->
                "已识别本机为华为设备（$romLabel），无端侧免鉴权文件转写服务；严禁上传录音上云，请下载 SenseVoice 增强模型。"
            else ->
                "已识别本机为 $brandLabel（$romLabel），当前系统未提供标准纯端侧音频文件转写服务；请下载 SenseVoice 增强模型。"
        }
    }

    @SuppressLint("DiscouragedApi")
    private fun readDefaultOnDeviceServicePackage(): String {
        return try {
            val sysRes = Resources.getSystem()
            val resId = sysRes.getIdentifier(
                "config_defaultOnDeviceSpeechRecognitionService",
                "string",
                "android",
            )
            if (resId == 0) {
                ""
            } else {
                val component = sysRes.getString(resId).trim()
                val slash = component.indexOf('/')
                if (slash > 0) component.substring(0, slash) else component
            }
        } catch (_: Throwable) {
            ""
        }
    }

    @SuppressLint("PrivateApi")
    private fun readSysProp(key: String): String {
        return try {
            val cls = Class.forName("android.os.SystemProperties")
            val getter = cls.getMethod("get", String::class.java)
            (getter.invoke(null, key) as? String)?.trim().orEmpty()
        } catch (_: Throwable) {
            ""
        }
    }

    private fun parseMajorInt(versionText: String?, fallback: Int): Int {
        val raw = versionText?.trim().orEmpty()
        val dot = raw.indexOf('.')
        val head = if (dot > 0) raw.substring(0, dot) else raw
        return head.toIntOrNull() ?: fallback
    }

    private fun resolveLocaleTag(language: String): String =
        when (language.trim().lowercase(Locale.ROOT)) {
            "en", "en-us", "en_us" -> "en-US"
            "yue", "zh-hk", "zh_hk" -> "yue-Hant-HK"
            "zh-tw", "zh_tw" -> "zh-TW"
            else -> "zh-CN"
        }

    private fun parseWavPcm16(bytes: ByteArray): WavPcmData {
        if (bytes.size < 44) {
            throw SubWindowException("INVALID_WAV", "WAV 文件长度异常（${bytes.size} 字节）")
        }
        val riff = String(bytes, 0, 4, Charsets.US_ASCII)
        val wave = String(bytes, 8, 4, Charsets.US_ASCII)
        if (riff != "RIFF" || wave != "WAVE") {
            throw SubWindowException("INVALID_WAV", "无效的 WAV 文件头")
        }

        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        var offset = 12
        var sampleRate = 16000
        var channels = 1
        var bitsPerSample = 16
        var dataOffset = -1
        var dataSize = 0

        while (offset + 8 <= bytes.size) {
            val chunkId = String(bytes, offset, 4, Charsets.US_ASCII)
            val chunkSize = bb.getInt(offset + 4)
            val bodyStart = offset + 8
            if (chunkSize < 0 || bodyStart > bytes.size) break
            val safeSize = min(chunkSize, bytes.size - bodyStart)

            when (chunkId) {
                "fmt " -> {
                    if (safeSize >= 16) {
                        val audioFormat = bb.getShort(bodyStart).toInt() and 0xFFFF
                        if (audioFormat != 1) {
                            throw SubWindowException("INVALID_WAV", "仅支持 PCM WAV（audioFormat=$audioFormat）")
                        }
                        channels = max(1, bb.getShort(bodyStart + 2).toInt() and 0xFFFF)
                        sampleRate = max(8000, bb.getInt(bodyStart + 4))
                        bitsPerSample = bb.getShort(bodyStart + 14).toInt() and 0xFFFF
                    }
                }
                "data" -> {
                    dataOffset = bodyStart
                    dataSize = safeSize
                    break
                }
            }

            val padded = if (chunkSize % 2 == 1) chunkSize + 1 else chunkSize
            offset = bodyStart + padded
        }

        if (bitsPerSample != 16) {
            throw SubWindowException("INVALID_WAV", "系统引擎仅支持 16-bit PCM WAV（当前 ${bitsPerSample}bit）")
        }
        if (dataOffset < 0 || dataSize <= 0) {
            return WavPcmData(sampleRate = sampleRate, channels = 1, monoSamples = ShortArray(0))
        }

        val frameBytes = 2 * channels
        val totalFrames = dataSize / frameBytes
        val mono = ShortArray(totalFrames)
        if (channels == 1) {
            for (i in 0 until totalFrames) {
                mono[i] = bb.getShort(dataOffset + i * 2)
            }
        } else {
            for (i in 0 until totalFrames) {
                var sum = 0
                val frameBase = dataOffset + i * frameBytes
                for (c in 0 until channels) {
                    sum += bb.getShort(frameBase + c * 2).toInt()
                }
                mono[i] = (sum / channels).toShort()
            }
        }
        return WavPcmData(sampleRate = sampleRate, channels = 1, monoSamples = mono)
    }

    private fun buildEnergyAlignedWindows(samples: ShortArray, sampleRate: Int): List<SubWindow> {
        val maxSamples = sampleRate * 14
        val targetSamples = sampleRate * 12
        val searchStartDelta = sampleRate * 9
        val searchEndDelta = (sampleRate * 13.5).toInt()
        val hop = max(1, sampleRate / 10) // 100ms 步长寻最低能量谷

        val out = ArrayList<SubWindow>()
        var cursor = 0
        while (cursor < samples.size) {
            val remaining = samples.size - cursor
            if (remaining <= maxSamples) {
                out.add(SubWindow(cursor, samples.size))
                break
            }

            val lo = min(samples.size, cursor + searchStartDelta)
            val hi = min(samples.size, cursor + searchEndDelta)
            var bestCut = min(samples.size, cursor + targetSamples)
            var bestEnergy = Double.MAX_VALUE

            var pos = lo
            while (pos + hop <= hi) {
                var sq = 0.0
                for (i in pos until pos + hop) {
                    val v = samples[i].toDouble()
                    sq += v * v
                }
                val rms = sq / hop
                if (rms < bestEnergy) {
                    bestEnergy = rms
                    bestCut = pos + hop / 2
                }
                pos += hop
            }
            if (bestCut <= cursor) {
                bestCut = min(samples.size, cursor + targetSamples)
            }
            out.add(SubWindow(cursor, bestCut))
            cursor = bestCut
        }
        return out
    }

    private fun hasVoiceEnergy(samples: ShortArray, start: Int, end: Int): Boolean {
        val count = end - start
        if (count <= 0) return false
        var peakAbs = 0
        var sumSq = 0.0
        for (i in start until end) {
            val v = abs(samples[i].toInt())
            if (v > peakAbs) peakAbs = v
            val d = samples[i].toDouble()
            sumSq += d * d
        }
        val rms = sqrt(sumSq / count)
        return peakAbs >= 120 || rms >= 35.0
    }

    private fun writeLittleEndianPcm16(
        outFile: File,
        samples: ShortArray,
        start: Int,
        end: Int,
    ) {
        val count = max(0, end - start)
        val byteBuf = ByteBuffer.allocate(count * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (i in start until end) {
            byteBuf.putShort(samples[i])
        }
        FileOutputStream(outFile).use { fos ->
            fos.write(byteBuf.array())
            fos.fd.sync()
        }
    }

    private fun appendWindowTranscript(
        text: String,
        winStartMs: Int,
        winEndMs: Int,
        combined: StringBuilder,
        outTokens: MutableList<String>,
        outTimestamps: MutableList<Int>,
    ) {
        val spanMs = max(1, winEndMs - winStartMs)
        var piece = text
        if (combined.isNotEmpty() && text.isNotEmpty()) {
            val prevLast = combined[combined.length - 1]
            val curFirst = text[0]
            if (isAsciiWordChar(prevLast) && isAsciiWordChar(curFirst)) {
                piece = " $text"
            }
        }
        val prevCount = outTokens.size
        combined.append(piece)

        val chars = ArrayList<String>(piece.length)
        var offset = 0
        while (offset < piece.length) {
            val cp = piece.codePointAt(offset)
            val charLen = Character.charCount(cp)
            chars.add(piece.substring(offset, offset + charLen))
            offset += charLen
        }
        val total = max(1, chars.size)
        for (i in chars.indices) {
            outTokens.add(chars[i])
            val ts = winStartMs + (spanMs.toLong() * i / total).toInt()
            outTimestamps.add(ts)
        }
        // 保证 timestamps 单调非减
        if (prevCount > 0 && outTimestamps.size > prevCount) {
            val prevTs = outTimestamps[prevCount - 1]
            for (k in prevCount until outTimestamps.size) {
                if (outTimestamps[k] < prevTs) {
                    outTimestamps[k] = prevTs
                }
            }
        }
    }

    private fun isAsciiWordChar(ch: Char): Boolean =
        ch.code in 48..57 || ch.code in 65..90 || ch.code in 97..122
}
