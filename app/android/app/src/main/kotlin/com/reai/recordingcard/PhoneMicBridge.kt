package com.reai.recordingcard

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.os.Process
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

/**
 * Android 本机麦克风实时采集通道（channel: `com.reai.recordingcard/phone_mic`）。
 *
 * 对齐 iOS `PhoneMicBridge.swift` 与 Dart `PlatformPhoneMicBackend`：
 * - 输出标准 16kHz / 16-bit Little-Endian / 单声道 PCM 字节块（`pcm` 回调）；
 * - 支撑三大核心链路：Android 独立本机录音、蓝牙硬件异常断连自动接力保底、以及物理按键语音任务麦克风兜底；
 * - 采集期间自动联动 [RecordingForegroundService] 保持锁屏与后台持续录音。
 */
class PhoneMicBridge(private val activity: Activity) {
    companion object {
        private const val CHANNEL_NAME = "com.reai.recordingcard/phone_mic"
        private const val PREFS_NAME = "rc_phone_mic_prefs"
        private const val KEY_MIC_REQUESTED = "mic_perm_requested"

        const val REQ_PHONE_MIC_PERM = 4093
        const val SAMPLE_RATE = 16000
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
        private const val CHUNK_SAMPLES = 1600 // 100ms @ 16kHz
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val running = AtomicBoolean(false)
    private var channel: MethodChannel? = null
    private var pendingPermResult: MethodChannel.Result? = null
    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null

    val isCapturing: Boolean
        get() = running.get()

    fun register(messenger: BinaryMessenger) {
        val ch = MethodChannel(messenger, CHANNEL_NAME)
        ch.setMethodCallHandler { call, result -> handle(call, result) }
        channel = ch
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQ_PHONE_MIC_PERM) return false
        val pending = pendingPermResult
        pendingPermResult = null
        if (pending != null) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            pending.success(if (granted) "granted" else "denied")
        }
        return true
    }

    fun destroy() {
        stopCapture()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status", "checkPermission" -> result.success(checkPermission())
            "request", "requestPermission" -> requestPermission(result)
            "start", "startCapture" -> {
                try {
                    startCapture()
                    result.success(null)
                } catch (t: Throwable) {
                    result.error(
                        "phone_mic_start_failed",
                        t.message ?: "启动本机麦克风采集失败",
                        null,
                    )
                }
            }
            "stop", "stopCapture" -> {
                stopCapture()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun checkPermission(): String {
        val granted = ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) return "granted"

        val prefs = activity.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val requestedBefore = prefs.getBoolean(KEY_MIC_REQUESTED, false)
        val shouldShowRationale = ActivityCompat.shouldShowRequestPermissionRationale(
            activity,
            Manifest.permission.RECORD_AUDIO,
        )
        return if (!requestedBefore && !shouldShowRationale) "notDetermined" else "denied"
    }

    fun requestPermission(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success("granted")
            return
        }
        if (pendingPermResult != null) {
            result.success(checkPermission())
            return
        }
        pendingPermResult = result
        activity.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_MIC_REQUESTED, true)
            .apply()
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            REQ_PHONE_MIC_PERM,
        )
    }

    @SuppressLint("MissingPermission")
    @Synchronized
    fun startCapture() {
        if (running.get() && audioRecord != null) {
            return
        }
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            throw IllegalStateException("未授予麦克风权限，请在系统设置中允许录音访问")
        }

        stopCaptureInternal(updateForeground = false)

        val minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
        if (minBuf == AudioRecord.ERROR || minBuf == AudioRecord.ERROR_BAD_VALUE || minBuf <= 0) {
            throw IllegalStateException("当前设备不支持 16kHz 单声道 PCM 麦克风采集 (minBuf=$minBuf)")
        }
        val bufferSizeBytes = max(minBuf * 2, CHUNK_SAMPLES * 4)

        val record = createInitializedAudioRecord(bufferSizeBytes)
            ?: throw IllegalStateException("无法初始化系统麦克风采集器（可能被系统通话或其它独占录音占用）")

        RecordingForegroundService.setMicrophoneActive(
            activity.applicationContext,
            active = true,
            title = "录音卡",
            subtitle = "本机录音运行中",
        )

        try {
            record.startRecording()
        } catch (t: Throwable) {
            try {
                record.release()
            } catch (_: Throwable) {}
            RecordingForegroundService.setMicrophoneActive(activity.applicationContext, active = false)
            throw IllegalStateException("启动麦克风录音失败：${t.message ?: t.javaClass.simpleName}", t)
        }

        if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            try {
                record.release()
            } catch (_: Throwable) {}
            RecordingForegroundService.setMicrophoneActive(activity.applicationContext, active = false)
            throw IllegalStateException("麦克风未能进入录音态（可能被系统限制或被其它应用独占）")
        }

        audioRecord = record
        running.set(true)

        val worker = Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            val shortBuf = ShortArray(CHUNK_SAMPLES)
            while (running.get()) {
                val n = try {
                    record.read(shortBuf, 0, shortBuf.size)
                } catch (t: Throwable) {
                    if (running.compareAndSet(true, false)) {
                        postError("麦克风读取异常：${t.message ?: t.javaClass.simpleName}")
                        RecordingForegroundService.setMicrophoneActive(activity.applicationContext, active = false)
                    }
                    break
                }

                if (n > 0) {
                    val bytes = ByteArray(n * 2)
                    ByteBuffer.wrap(bytes)
                        .order(ByteOrder.LITTLE_ENDIAN)
                        .asShortBuffer()
                        .put(shortBuf, 0, n)
                    mainHandler.post {
                        if (running.get()) {
                            channel?.invokeMethod("pcm", bytes)
                        }
                    }
                } else if (n < 0) {
                    if (running.compareAndSet(true, false)) {
                        postError("麦克风采集流中断 (错误码 $n)")
                        RecordingForegroundService.setMicrophoneActive(activity.applicationContext, active = false)
                    }
                    break
                }
            }
        }, "rc-phone-mic-16k").apply {
            isDaemon = true
            start()
        }
        captureThread = worker
    }

    @Synchronized
    fun stopCapture() {
        stopCaptureInternal(updateForeground = true)
    }

    private fun stopCaptureInternal(updateForeground: Boolean) {
        running.set(false)
        val record = audioRecord
        audioRecord = null
        val thread = captureThread
        captureThread = null

        if (record != null) {
            try {
                if (record.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                    record.stop()
                }
            } catch (_: Throwable) {
                // ignore stop race
            }
            try {
                record.release()
            } catch (_: Throwable) {
                // ignore release race
            }
        }
        if (thread != null && thread !== Thread.currentThread()) {
            try {
                thread.join(300)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        if (updateForeground) {
            RecordingForegroundService.setMicrophoneActive(activity.applicationContext, active = false)
        }
    }

    @SuppressLint("MissingPermission")
    private fun createInitializedAudioRecord(bufferSizeBytes: Int): AudioRecord? {
        val sources = intArrayOf(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            MediaRecorder.AudioSource.MIC,
        )
        for (source in sources) {
            try {
                val candidate = AudioRecord(
                    source,
                    SAMPLE_RATE,
                    CHANNEL_CONFIG,
                    AUDIO_FORMAT,
                    bufferSizeBytes,
                )
                if (candidate.state == AudioRecord.STATE_INITIALIZED) {
                    return candidate
                }
                candidate.release()
            } catch (_: Throwable) {
                // 尝试下一个音源兜底
            }
        }
        return null
    }

    private fun postError(message: String) {
        mainHandler.post {
            channel?.invokeMethod("error", message)
        }
    }
}
