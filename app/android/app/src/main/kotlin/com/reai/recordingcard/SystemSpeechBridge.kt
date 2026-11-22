package com.reai.recordingcard

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.content.res.Resources
import android.media.AudioFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.ModelDownloadListener
import android.speech.RecognitionListener
import android.speech.RecognitionService
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
 * Android 系统内置及兼容端侧语音识别桥接（channel: `com.reai.recordingcard/system_speech`）。
 *
 * 按 Android 13–16 官方标准三层自适应优先级解析：
 * 1. `native_on_device`: 系统默认提供可用端侧识别（API 33+ `isOnDeviceRecognitionAvailable == true`）且非 Bixby/SMT；
 * 2. `compat_service`: 当默认引擎不可用或为三星 `bixby` / `com.google.android.as` 时，枚举已安装的非 Bixby
 *    `RecognitionService`（优先 `com.google.android.tts` / `GoogleTTSRecognitionService`），在通过
 *    `checkRecognitionSupport(EXTRA_PREFER_OFFLINE=true)` 纯端侧中文校验后直连 `createSpeechRecognizer(ctx, ComponentName)`；
 * 3. `local_self_hosted`: 未匹配到免下载的纯端侧系统/兼容服务时，如实返回不支持与品牌说明，由上层优先展示本地离线 SenseVoice 模型。
 *
 * 全程严格遵守本地隐私红线：音频仅剥离 WAV 头后通过 `ParcelFileDescriptor` 注入 16kHz PCM 流，
 * 不回退开启物理麦克风、不使用纯在线识别服务、不上传云端。
 */
class SystemSpeechBridge(private val activity: Activity) {
    companion object {
        private const val CHANNEL_NAME = "com.reai.recordingcard/system_speech"
        const val REQ_AUDIO_PERM = 4092

        private const val ERROR_LANGUAGE_NOT_SUPPORTED = 12
        private const val ERROR_LANGUAGE_UNAVAILABLE = 13

        const val STRATEGY_NATIVE = "native_on_device"
        const val STRATEGY_COMPAT = "compat_service"
        const val STRATEGY_LOCAL_SELF_HOSTED = "local_self_hosted"
    }

    private data class CompatServiceCandidate(
        val component: ComponentName,
        val packageName: String,
        val label: String,
        val isGoogleTts: Boolean,
    )

    private data class BaseDeviceProfile(
        val osMajorVersion: Int,
        val sdkInt: Int,
        val brandId: String,
        val brandLabel: String,
        val romLabel: String,
        val deviceSummary: String,
        val defaultServicePackage: String,
        val isBixby: Boolean,
        val onDeviceApiAvailable: Boolean,
        val candidates: List<CompatServiceCandidate>,
    )

    private data class ResolvedProfile(
        val base: BaseDeviceProfile,
        val resolutionStrategy: String,
        val supportsModernSystemAsr: Boolean,
        val engineName: String,
        val onDeviceServicePackage: String,
        val compatComponent: ComponentName?,
        val compatDescription: String,
        val offlinePackInstalled: Boolean,
        val canDownloadOfflinePack: Boolean,
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

    private class SubWindowException(
        val code: String,
        override val message: String,
        val speechErrorCode: Int = 0,
    ) : Exception(message)

    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val seqCounter = AtomicInteger(0)

    private var channel: MethodChannel? = null
    private var pendingPermResult: MethodChannel.Result? = null
    private var activeDownloadRecognizer: SpeechRecognizer? = null
    private val lastResolvedProfile = AtomicReference<ResolvedProfile?>(null)

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
        resolveProfileAsync { resolved ->
            lastResolvedProfile.set(resolved)
            result.success(buildCapabilityMap(resolved))
        }
    }

    private fun resolveProfileAsync(onDone: (ResolvedProfile) -> Unit) {
        val base = detectBaseProfile()
        if (base.sdkInt < Build.VERSION_CODES.TIRAMISU || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            onDone(buildLocalSelfHostedProfile(base))
            return
        }

        val preferCompatFirst =
            base.brandId == "samsung" &&
                (base.isBixby || base.defaultServicePackage.lowercase(Locale.ROOT).startsWith("com.google.android.as")) &&
                base.candidates.any { it.isGoogleTts }

        val canTryNative = base.onDeviceApiAvailable && !base.isBixby

        if (preferCompatFirst) {
            probeCompatCandidatesApi33(base, base.candidates.take(3), 0) { compatProfile ->
                if (compatProfile != null) {
                    onDone(compatProfile)
                } else if (canTryNative) {
                    probeNativeApi33(base, onFallbackCompat = { onDone(buildLocalSelfHostedProfile(base)) }, onDone = onDone)
                } else {
                    onDone(buildLocalSelfHostedProfile(base))
                }
            }
            return
        }

        if (canTryNative) {
            probeNativeApi33(
                base = base,
                onFallbackCompat = {
                    val remaining = base.candidates
                        .filter { !it.packageName.equals(base.defaultServicePackage, ignoreCase = true) }
                        .take(3)
                    probeCompatCandidatesApi33(base, remaining, 0) { compatProfile ->
                        onDone(compatProfile ?: buildLocalSelfHostedProfile(base))
                    }
                },
                onDone = onDone,
            )
            return
        }

        probeCompatCandidatesApi33(base, base.candidates.take(3), 0) { compatProfile ->
            onDone(compatProfile ?: buildLocalSelfHostedProfile(base))
        }
    }

    private fun buildCapabilityMap(profile: ResolvedProfile): Map<String, Any> = mapOf(
        "platform" to "android",
        "osMajorVersion" to profile.base.osMajorVersion,
        "sdkInt" to profile.base.sdkInt,
        "brandId" to profile.base.brandId,
        "deviceSummary" to profile.base.deviceSummary,
        "engineName" to profile.engineName,
        "onDeviceServicePackage" to profile.onDeviceServicePackage,
        "resolutionStrategy" to profile.resolutionStrategy,
        "compatServiceComponent" to (profile.compatComponent?.flattenToShortString() ?: ""),
        "compatDescription" to profile.compatDescription,
        "detectedServices" to profile.base.candidates.map { it.packageName },
        "supportsModernSystemAsr" to profile.supportsModernSystemAsr,
        "offlinePackInstalled" to profile.offlinePackInstalled,
        "canDownloadOfflinePack" to profile.canDownloadOfflinePack,
        "unsupportedReason" to profile.unsupportedReason,
        "authStatus" to authStatusText(),
    )

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun buildChineseSupportIntent(): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-CN")
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun probeNativeApi33(
        base: BaseDeviceProfile,
        onFallbackCompat: () -> Unit,
        onDone: (ResolvedProfile) -> Unit,
    ) {
        val finished = AtomicBoolean(false)
        var sr: SpeechRecognizer? = null
        val timeout = Runnable {
            if (finished.compareAndSet(false, true)) {
                sr?.destroy()
                onDone(
                    buildNativeProfile(
                        base = base,
                        installed = true,
                        canDownload = false,
                    ),
                )
            }
        }
        mainHandler.post {
            try {
                sr = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
                mainHandler.postDelayed(timeout, 1000L)
                sr?.checkRecognitionSupport(
                    buildChineseSupportIntent(),
                    worker,
                    object : RecognitionSupportCallback {
                        override fun onSupportResult(support: RecognitionSupport) {
                            val installedTags = support.installedOnDeviceLanguages
                            val supportedTags = support.supportedOnDeviceLanguages
                            val pendingTags = support.pendingOnDeviceLanguages
                            val hasZhInstalled = matchesChineseTag(installedTags)
                            val hasZhDownloadable =
                                matchesChineseTag(supportedTags) || matchesChineseTag(pendingTags)
                            val emptyOnDevice = installedTags.isEmpty() &&
                                supportedTags.isEmpty() &&
                                pendingTags.isEmpty()
                            mainHandler.post {
                                mainHandler.removeCallbacks(timeout)
                                if (finished.compareAndSet(false, true)) {
                                    sr?.destroy()
                                    if (!hasZhInstalled && !hasZhDownloadable && base.candidates.isNotEmpty() && !emptyOnDevice) {
                                        onFallbackCompat()
                                    } else {
                                        val finalInstalled = hasZhInstalled || (!hasZhDownloadable && emptyOnDevice)
                                        onDone(
                                            buildNativeProfile(
                                                base = base,
                                                installed = finalInstalled,
                                                canDownload = !hasZhInstalled && hasZhDownloadable,
                                            ),
                                        )
                                    }
                                }
                            }
                        }

                        override fun onError(error: Int) {
                            mainHandler.post {
                                mainHandler.removeCallbacks(timeout)
                                if (finished.compareAndSet(false, true)) {
                                    sr?.destroy()
                                    // 部分原生端侧实现不开放 checkRecognitionSupport，仍允许直接转写；若报错则转兼容检查或按默认可用
                                    onDone(
                                        buildNativeProfile(
                                            base = base,
                                            installed = true,
                                            canDownload = false,
                                        ),
                                    )
                                }
                            }
                        }
                    },
                )
            } catch (_: Throwable) {
                mainHandler.removeCallbacks(timeout)
                if (finished.compareAndSet(false, true)) {
                    sr?.destroy()
                    onFallbackCompat()
                }
            }
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun probeCompatCandidatesApi33(
        base: BaseDeviceProfile,
        candidates: List<CompatServiceCandidate>,
        index: Int,
        onDone: (ResolvedProfile?) -> Unit,
    ) {
        if (index >= candidates.size) {
            onDone(null)
            return
        }
        val cand = candidates[index]
        val finished = AtomicBoolean(false)
        var sr: SpeechRecognizer? = null
        val timeout = Runnable {
            if (finished.compareAndSet(false, true)) {
                sr?.destroy()
                probeCompatCandidatesApi33(base, candidates, index + 1, onDone)
            }
        }
        mainHandler.post {
            try {
                sr = SpeechRecognizer.createSpeechRecognizer(activity, cand.component)
                mainHandler.postDelayed(timeout, 1000L)
                sr?.checkRecognitionSupport(
                    buildChineseSupportIntent(),
                    worker,
                    object : RecognitionSupportCallback {
                        override fun onSupportResult(support: RecognitionSupport) {
                            // 严格端侧隐私门控：必须明确支持端侧离线中文（禁止仅列 onlineLanguages 的服务通过）
                            val hasZhInstalled = matchesChineseTag(support.installedOnDeviceLanguages)
                            val hasZhDownloadable =
                                matchesChineseTag(support.supportedOnDeviceLanguages) ||
                                    matchesChineseTag(support.pendingOnDeviceLanguages)
                            mainHandler.post {
                                mainHandler.removeCallbacks(timeout)
                                if (finished.compareAndSet(false, true)) {
                                    sr?.destroy()
                                    if (hasZhInstalled || hasZhDownloadable) {
                                        onDone(
                                            buildCompatProfile(
                                                base = base,
                                                candidate = cand,
                                                installed = hasZhInstalled,
                                                canDownload = !hasZhInstalled && hasZhDownloadable,
                                            ),
                                        )
                                    } else {
                                        probeCompatCandidatesApi33(base, candidates, index + 1, onDone)
                                    }
                                }
                            }
                        }

                        override fun onError(error: Int) {
                            mainHandler.post {
                                mainHandler.removeCallbacks(timeout)
                                if (finished.compareAndSet(false, true)) {
                                    sr?.destroy()
                                    probeCompatCandidatesApi33(base, candidates, index + 1, onDone)
                                }
                            }
                        }
                    },
                )
            } catch (_: Throwable) {
                mainHandler.removeCallbacks(timeout)
                if (finished.compareAndSet(false, true)) {
                    sr?.destroy()
                    probeCompatCandidatesApi33(base, candidates, index + 1, onDone)
                }
            }
        }
    }

    private fun buildNativeProfile(
        base: BaseDeviceProfile,
        installed: Boolean,
        canDownload: Boolean,
    ): ResolvedProfile {
        val lowPkg = base.defaultServicePackage.lowercase(Locale.ROOT)
        val engineName = when {
            base.brandId == "pixel" && lowPkg.startsWith("com.google.android.as") ->
                "Pixel 原生端侧语音模型（System Intelligence）"
            lowPkg.startsWith("com.google.android.as") ->
                "${base.brandLabel} 端侧语音模型（System Intelligence）"
            lowPkg.startsWith("com.google.android.tts") ->
                "${base.brandLabel} 系统内置语音模型（Google 端侧离线）"
            else ->
                "${base.brandLabel} 系统内置端侧语音模型"
        }
        val desc =
            "已匹配当前设备原生端侧语音识别服务（Android ${base.osMajorVersion} · createOnDeviceSpeechRecognizer），通过本地文件流注入 16kHz PCM 转写，免下载 228 MB 模型且全程不打开麦克风、不上云。"
        return ResolvedProfile(
            base = base,
            resolutionStrategy = STRATEGY_NATIVE,
            supportsModernSystemAsr = true,
            engineName = engineName,
            onDeviceServicePackage = base.defaultServicePackage,
            compatComponent = null,
            compatDescription = desc,
            offlinePackInstalled = installed,
            canDownloadOfflinePack = canDownload,
            unsupportedReason = "",
        )
    }

    private fun buildCompatProfile(
        base: BaseDeviceProfile,
        candidate: CompatServiceCandidate,
        installed: Boolean,
        canDownload: Boolean,
    ): ResolvedProfile {
        val engineName = if (candidate.isGoogleTts) {
            "${base.brandLabel} 兼容方案（直连 Google 端侧语音）"
        } else {
            "${base.brandLabel} 兼容方案（直连 ${candidate.label} 端侧离线）"
        }
        val prefix = if (base.isBixby) {
            "已自动绕开三星 Bixby 语音组件，直连本机已安装的"
        } else {
            "已匹配并直连本机可用的"
        }
        val serviceLabel = if (candidate.isGoogleTts) {
            "Google 端侧离线语音服务（GoogleTTSRecognitionService）"
        } else {
            "${candidate.label} 端侧离线服务（${candidate.packageName}）"
        }
        val desc =
            "$prefix「$serviceLabel」，直接通过本地 PCM 文件流转写，无需下载 228 MB 增强模型，全程不开麦克风、不上传云端。"
        return ResolvedProfile(
            base = base,
            resolutionStrategy = STRATEGY_COMPAT,
            supportsModernSystemAsr = true,
            engineName = engineName,
            onDeviceServicePackage = candidate.packageName,
            compatComponent = candidate.component,
            compatDescription = desc,
            offlinePackInstalled = installed,
            canDownloadOfflinePack = canDownload,
            unsupportedReason = "",
        )
    }

    private fun buildLocalSelfHostedProfile(base: BaseDeviceProfile): ResolvedProfile = ResolvedProfile(
        base = base,
        resolutionStrategy = STRATEGY_LOCAL_SELF_HOSTED,
        supportsModernSystemAsr = false,
        engineName = "",
        onDeviceServicePackage = base.defaultServicePackage,
        compatComponent = null,
        compatDescription = "",
        offlinePackInstalled = false,
        canDownloadOfflinePack = false,
        unsupportedReason = buildUnsupportedReason(base),
    )

    private fun matchesChineseTag(tags: List<String>): Boolean =
        tags.any { tag ->
            val low = tag.lowercase(Locale.ROOT)
            low.startsWith("zh") || low.startsWith("cmn")
        }

    private fun handleDownloadSystemModel(language: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(false)
            return
        }
        val cached = lastResolvedProfile.get()
        if (cached != null) {
            triggerDownloadForProfile(cached, resolveLocaleTag(language), result)
            return
        }
        resolveProfileAsync { resolved ->
            lastResolvedProfile.set(resolved)
            triggerDownloadForProfile(resolved, resolveLocaleTag(language), result)
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun triggerDownloadForProfile(
        profile: ResolvedProfile,
        localeTag: String,
        result: MethodChannel.Result,
    ) {
        if (!profile.supportsModernSystemAsr) {
            result.success(false)
            return
        }
        mainHandler.post {
            try {
                activeDownloadRecognizer?.destroy()
                val sr = if (profile.compatComponent != null) {
                    SpeechRecognizer.createSpeechRecognizer(activity, profile.compatComponent)
                } else {
                    SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
                }
                activeDownloadRecognizer = sr
                val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE, localeTag)
                    putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    val settled = AtomicBoolean(false)
                    val timeout = Runnable {
                        if (settled.compareAndSet(false, true)) {
                            if (activeDownloadRecognizer === sr) {
                                sr.destroy()
                                activeDownloadRecognizer = null
                            }
                            result.success(false)
                        }
                    }
                    mainHandler.postDelayed(timeout, 12000L)
                    sr.triggerModelDownload(
                        intent,
                        worker,
                        object : ModelDownloadListener {
                            override fun onProgress(completedPercent: Int) {}

                            override fun onSuccess() {
                                finishDownloadCallback(sr, timeout, settled, true, result)
                            }

                            override fun onScheduled() {
                                finishDownloadCallback(sr, timeout, settled, true, result)
                            }

                            override fun onError(error: Int) {
                                finishDownloadCallback(sr, timeout, settled, false, result)
                            }
                        },
                    )
                } else {
                    sr.triggerModelDownload(intent)
                    mainHandler.postDelayed({
                        if (activeDownloadRecognizer === sr) {
                            sr.destroy()
                            activeDownloadRecognizer = null
                        }
                    }, 4000L)
                    result.success(true)
                }
            } catch (_: Throwable) {
                result.success(false)
            }
        }
    }

    private fun finishDownloadCallback(
        sr: SpeechRecognizer,
        timeout: Runnable,
        settled: AtomicBoolean,
        ok: Boolean,
        result: MethodChannel.Result,
    ) {
        mainHandler.post {
            mainHandler.removeCallbacks(timeout)
            if (settled.compareAndSet(false, true)) {
                if (activeDownloadRecognizer === sr) {
                    sr.destroy()
                    activeDownloadRecognizer = null
                }
                result.success(ok)
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
        val cached = lastResolvedProfile.get()
        if (cached != null) {
            dispatchTranscribeWithProfile(cached, wavFile, language, result)
            return
        }
        resolveProfileAsync { resolved ->
            lastResolvedProfile.set(resolved)
            dispatchTranscribeWithProfile(resolved, wavFile, language, result)
        }
    }

    private fun dispatchTranscribeWithProfile(
        profile: ResolvedProfile,
        wavFile: File,
        language: String,
        result: MethodChannel.Result,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || !profile.supportsModernSystemAsr) {
            val reason = profile.unsupportedReason.ifEmpty {
                "当前 Android 设备未匹配免下载的端侧兼容语音模型，请下载本机首选的 SenseVoice 增强模型"
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
                val payload = transcribeWavInBackgroundApi33(profile, wavFile, localeTag)
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
        profile: ResolvedProfile,
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

        val googleTtsFallback = profile.base.candidates.firstOrNull { it.isGoogleTts }?.component
        val windows = buildEnergyAlignedWindows(wav.monoSamples, wav.sampleRate)
        val combinedText = StringBuilder()
        val allTokens = ArrayList<String>()
        val allTimestamps = ArrayList<Int>()

        for (win in windows) {
            if (!hasVoiceEnergy(wav.monoSamples, win.startSample, win.endSample)) {
                continue
            }
            val subText = transcribeWindowWithOptionalFallbackApi33(
                samples = wav.monoSamples,
                start = win.startSample,
                end = win.endSample,
                sampleRate = wav.sampleRate,
                localeTag = localeTag,
                primaryComponent = profile.compatComponent,
                fallbackComponent = if (profile.compatComponent == null) googleTtsFallback else null,
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
    private fun transcribeWindowWithOptionalFallbackApi33(
        samples: ShortArray,
        start: Int,
        end: Int,
        sampleRate: Int,
        localeTag: String,
        primaryComponent: ComponentName?,
        fallbackComponent: ComponentName?,
    ): String {
        return try {
            transcribeWindowApi33(samples, start, end, sampleRate, localeTag, primaryComponent)
        } catch (e: SubWindowException) {
            val shouldFallback =
                primaryComponent == null &&
                    fallbackComponent != null &&
                    (e.code == "SYSTEM_ASR_TIMEOUT" ||
                        e.speechErrorCode == SpeechRecognizer.ERROR_CLIENT ||
                        e.speechErrorCode == SpeechRecognizer.ERROR_AUDIO ||
                        e.speechErrorCode == SpeechRecognizer.ERROR_SERVER)
            if (!shouldFallback) throw e
            transcribeWindowApi33(samples, start, end, sampleRate, localeTag, fallbackComponent)
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun transcribeWindowApi33(
        samples: ShortArray,
        start: Int,
        end: Int,
        sampleRate: Int,
        localeTag: String,
        targetComponent: ComponentName?,
    ): String {
        val pcmFile = File(activity.cacheDir, "rc_asr_win_${seqCounter.incrementAndGet()}.pcm")
        writeLittleEndianPcm16(pcmFile, samples, start, end)

        var pfd: ParcelFileDescriptor? = null
        val srRef = AtomicReference<SpeechRecognizer?>(null)
        val latch = CountDownLatch(1)
        val textRef = AtomicReference("")
        val partialRef = AtomicReference("")
        val segmentTexts = java.util.Collections.synchronizedList(ArrayList<String>())
        val errorCodeRef = AtomicInteger(0)

        try {
            pfd = ParcelFileDescriptor.open(pcmFile, ParcelFileDescriptor.MODE_READ_ONLY)
            val audioSourcePfd = pfd
            mainHandler.post {
                try {
                    val sr = if (targetComponent != null) {
                        SpeechRecognizer.createSpeechRecognizer(activity, targetComponent)
                    } else {
                        SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
                    }
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

                        override fun onSegmentResults(segmentResults: Bundle) {
                            val items = segmentResults.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                            val piece = items?.firstOrNull()?.trim().orEmpty()
                            if (piece.isNotEmpty()) {
                                segmentTexts.add(piece)
                            }
                        }

                        override fun onEndOfSegmentedSession() {
                            latch.countDown()
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
                        putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, activity.packageName)
                        putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
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

            val segmentedJoined = joinSegmentPieces(segmentTexts)
            val err = errorCodeRef.get()
            if (err == 0) {
                return textRef.get().ifEmpty { segmentedJoined }.ifEmpty { partialRef.get() }
            }
            if (err == SpeechRecognizer.ERROR_NO_MATCH || err == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) {
                return segmentedJoined.ifEmpty { partialRef.get() }
            }
            if (err == ERROR_LANGUAGE_NOT_SUPPORTED || err == ERROR_LANGUAGE_UNAVAILABLE) {
                throw SubWindowException(
                    "MODEL_NOT_INSTALLED",
                    "系统离线语音包未就绪，请先下载系统中文离线语言包或切换 SenseVoice 增强模型",
                    err,
                )
            }
            throw SubWindowException("SYSTEM_ASR_FAILED", "系统语音识别失败（错误码 $err）", err)
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

    private fun joinSegmentPieces(pieces: List<String>): String {
        val sb = StringBuilder()
        synchronized(pieces) {
            for (raw in pieces) {
                val p = raw.trim()
                if (p.isEmpty()) continue
                if (sb.isNotEmpty() && isAsciiWordChar(sb[sb.length - 1]) && isAsciiWordChar(p[0])) {
                    sb.append(' ')
                }
                sb.append(p)
            }
        }
        return sb.toString()
    }

    private fun detectBaseProfile(): BaseDeviceProfile {
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

        return BaseDeviceProfile(
            osMajorVersion = osMajor,
            sdkInt = sdkInt,
            brandId = brandId,
            brandLabel = brandLabel,
            romLabel = romLabel,
            deviceSummary = deviceSummary,
            defaultServicePackage = servicePkg,
            isBixby = isBixby,
            onDeviceApiAvailable = onDeviceApiAvailable,
            candidates = discoverCompatibleServices(),
        )
    }

    private fun discoverCompatibleServices(): List<CompatServiceCandidate> {
        return try {
            val pm = activity.packageManager
            val queryIntent = Intent(RecognitionService.SERVICE_INTERFACE)
            val infos: List<ResolveInfo> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.queryIntentServices(queryIntent, PackageManager.ResolveInfoFlags.of(0L))
            } else {
                @Suppress("DEPRECATION")
                pm.queryIntentServices(queryIntent, 0)
            }
            val seen = HashSet<String>()
            val out = ArrayList<CompatServiceCandidate>()
            for (ri in infos) {
                val si = ri.serviceInfo ?: continue
                val pkg = si.packageName?.trim().orEmpty()
                val cls = si.name?.trim().orEmpty()
                if (pkg.isEmpty() || cls.isEmpty()) continue
                val lowPkg = pkg.lowercase(Locale.ROOT)
                if (lowPkg.contains("bixby") || lowPkg.startsWith("com.samsung.smt")) {
                    continue
                }
                if (!seen.add(pkg)) continue
                val label = try {
                    si.loadLabel(pm).toString().trim().ifEmpty { pkg }
                } catch (_: Throwable) {
                    pkg
                }
                out.add(
                    CompatServiceCandidate(
                        component = ComponentName(pkg, cls),
                        packageName = pkg,
                        label = label,
                        isGoogleTts = lowPkg == "com.google.android.tts",
                    ),
                )
            }
            out.sortWith(
                compareBy<CompatServiceCandidate> {
                    when {
                        it.isGoogleTts -> 0
                        it.packageName.lowercase(Locale.ROOT) == "com.google.android.as" -> 1
                        else -> 2
                    }
                }.thenBy { it.packageName },
            )
            out
        } catch (_: Throwable) {
            emptyList()
        }
    }

    private fun buildUnsupportedReason(base: BaseDeviceProfile): String {
        if (base.sdkInt < Build.VERSION_CODES.TIRAMISU) {
            return "已识别本机为 ${base.brandLabel}（Android ${Build.VERSION.RELEASE}），系统版本低于 Android 13，无法通过端侧文件流免麦转写；已优先为您切换外脑本地离线模型 SenseVoice。"
        }
        if (base.isBixby) {
            return "已识别本机为 ${base.brandLabel}（默认绑定 Bixby 语音且未检测到可用的 Google 端侧兼容语音服务），Bixby 接口会忽略离线音频文件并误开手机麦克风；为保障隐私已优先展示本地离线 SenseVoice 模型。"
        }
        return when (base.brandId) {
            "xiaomi" ->
                "已识别本机为 ${base.brandLabel}（${base.romLabel}），当前未匹配到免下载的端侧系统/兼容语音服务（国行小爱未开放标准端侧文件流）；已优先展示本地离线 SenseVoice 模型，音频不出本机。"
            "oppo" ->
                "已识别本机为 ${base.brandLabel}（${base.romLabel}），当前未匹配到可用的端侧系统/兼容语音服务（ColorOS AIUnit 需商业白名单且未开源文件流）；已优先展示本地离线 SenseVoice 模型。"
            "vivo" ->
                "已识别本机为 ${base.brandLabel}（${base.romLabel}），当前未匹配到标准端侧文件流语音服务（OriginOS 未向第三方开放）；已优先展示本地离线 SenseVoice 模型。"
            "honor" ->
                "已识别本机为 ${base.brandLabel}（${base.romLabel}），当前未检测到标准端侧兼容服务（Magic Live 离线工具需专属渠道授权与签名）；已优先展示本地离线 SenseVoice 模型。"
            "huawei" ->
                "已识别本机为华为设备（${base.romLabel}），无标准免上云端侧系统语音服务（HMS AFT 仅支持云端传输）；为坚守隐私红线，已优先展示本地离线 SenseVoice 模型。"
            else ->
                "已识别本机为 ${base.brandLabel}（${base.romLabel}），未检测到可用的免下载系统或兼容端侧语音服务；已优先展示本地离线 SenseVoice 模型。"
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
        val hop = max(1, sampleRate / 10)

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
