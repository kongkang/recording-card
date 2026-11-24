package com.reai.recordingcard

import android.Manifest
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity(), TextToSpeech.OnInitListener {
    private var pendingAuth: MethodChannel.Result? = null

    companion object {
        init {
            // Android：必须从 Java 侧加载 card_bridge，JNI_OnLoad 才会被 ART 调用，
            // 把 JavaVM 交给 btleplug droidplug 后端（裸 dlopen 不触发 JNI_OnLoad）。
            // 加载后 Dart 侧 DynamicLibrary.process() 即可看到桥符号。
            // 若设备 ABI 缺少对应 .so，捕获异常由 Dart 侧如实提示「不支持硬件连接」，避免冷启动崩溃。
            try {
                System.loadLibrary("card_bridge")
            } catch (e: UnsatisfiedLinkError) {
                Log.w("MainActivity", "card_bridge unavailable for current ABI: ${e.message}")
            }
        }

        private const val SPEECH_CHANNEL = "com.reai.recordingcard/agent_speech"
        private const val OAUTH_CHANNEL = "com.reai.recordingcard/oauth"
        private const val BLUETOOTH_CHANNEL = "com.reai.recordingcard/bluetooth"
        private const val LIVE_ACTIVITY_CHANNEL = "com.reai.recordingcard/live_activity"
        private const val LOCAL_NOTIF_CHANNEL = "com.reai.recordingcard/local_notifications"
        private const val ALERT_CHANNEL_ID = "rc_device_alerts"
        private const val ALERT_NOTIF_ID = 4201
        private const val BLE_PREFS = "rc_ble_perm_prefs"
        private const val KEY_BLE_REQUESTED = "ble_perm_requested"

        private const val AUTH_REQUEST = 0x5243
        private const val REQ_AUDIO_PERM = 4091
        private const val REQ_BLE_PERM = 4094
    }

    private var speechChannel: MethodChannel? = null
    private var systemSpeechBridge: SystemSpeechBridge? = null
    private var phoneMicBridge: PhoneMicBridge? = null
    private var recognizer: SpeechRecognizer? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var ttsLanguageSupported = false
    private var ttsUnavailableMessage: String = "当前设备系统语音播报暂不可用"
    private var pendingPermResult: MethodChannel.Result? = null
    private var pendingPermLocale: String = "zh-CN"
    private var pendingBlePermResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        com.nonpolynomial.btleplug.android.impl.Adapter.setAppContext(applicationContext)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        tts = TextToSpeech(this, this)
        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {
                runOnUiThread {
                    speechChannel?.invokeMethod("onSpeakState", mapOf("speaking" to true))
                }
            }

            override fun onDone(utteranceId: String?) {
                runOnUiThread {
                    speechChannel?.invokeMethod("onSpeakState", mapOf("speaking" to false))
                }
            }

            override fun onStop(utteranceId: String?, interrupted: Boolean) {
                runOnUiThread {
                    speechChannel?.invokeMethod("onSpeakState", mapOf("speaking" to false))
                }
            }

            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) {
                emitTtsFailure("系统语音播报失败")
            }

            override fun onError(utteranceId: String?, errorCode: Int) {
                emitTtsFailure("系统语音播报失败（错误码 $errorCode）")
            }
        })

        val channel = MethodChannel(messenger, SPEECH_CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startListening" -> {
                    val locale = call.argument<String>("locale") ?: "zh-CN"
                    startListening(locale, result)
                }
                "stopListening" -> {
                    recognizer?.stopListening()
                    result.success(null)
                }
                "speak" -> {
                    val text = (call.argument<String>("text") ?: "").trim()
                    val locale = call.argument<String>("locale") ?: "zh-CN"
                    if (text.isNotEmpty()) {
                        speakWithTts(text, locale)
                    }
                    result.success(null)
                }
                "stopSpeaking" -> {
                    tts?.stop()
                    speechChannel?.invokeMethod("onSpeakState", mapOf("speaking" to false))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        speechChannel = channel

        val sysSpeech = SystemSpeechBridge(this)
        sysSpeech.register(messenger)
        systemSpeechBridge = sysSpeech

        val micBridge = PhoneMicBridge(this)
        micBridge.register(messenger)
        phoneMicBridge = micBridge

        MethodChannel(messenger, BLUETOOTH_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(blePermissionStatus())
                    "request" -> requestBlePermissions(result)
                    "setKeepScreenOn" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        runOnUiThread {
                            if (enabled) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            }
                            result.success(true)
                        }
                    }
                    "setRecordingForeground" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        val title = call.argument<String>("title")
                        val subtitle = call.argument<String>("subtitle")
                        val useMic = call.argument<Boolean>("useMicrophone") ?: false
                        if (useMic) {
                            RecordingForegroundService.setMicrophoneActive(
                                applicationContext,
                                active = enabled,
                                title = title,
                                subtitle = subtitle,
                            )
                        } else {
                            RecordingForegroundService.setConnectedDeviceActive(
                                applicationContext,
                                active = enabled,
                                title = title,
                                subtitle = subtitle,
                            )
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(messenger, LIVE_ACTIVITY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capabilities" -> result.success(
                        mapOf(
                            "supportsLiveActivities" to false,
                            "supportsDynamicIsland" to false,
                            "supportsActionButton" to false,
                            "areActivitiesEnabled" to false,
                        ),
                    )
                    "start" -> {
                        val title = call.argument<String>("title")
                        val subtitle = call.argument<String>("subtitle")
                        val isLocalMicSession =
                            phoneMicBridge?.isCapturing == true ||
                                subtitle?.contains("本机") == true
                        if (isLocalMicSession) {
                            RecordingForegroundService.setConnectedDeviceActive(
                                applicationContext,
                                active = false,
                            )
                            RecordingForegroundService.setMicrophoneActive(
                                applicationContext,
                                active = true,
                                title = title,
                                subtitle = subtitle,
                            )
                        } else {
                            RecordingForegroundService.setConnectedDeviceActive(
                                applicationContext,
                                active = true,
                                title = title,
                                subtitle = subtitle,
                            )
                        }
                        result.success(null)
                    }
                    "stop" -> {
                        RecordingForegroundService.setConnectedDeviceActive(
                            applicationContext,
                            active = false,
                        )
                        if (phoneMicBridge?.isCapturing != true) {
                            RecordingForegroundService.setMicrophoneActive(
                                applicationContext,
                                active = false,
                            )
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(messenger, OAUTH_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "authenticate") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val url = call.argument<String>("url")
                if (url.isNullOrBlank()) {
                    result.error("BAD_URL", "missing url", null)
                    return@setMethodCallHandler
                }
                pendingAuth?.error("CANCELED", "replaced", null)
                pendingAuth = result
                startActivityForResult(
                    Intent(this, OAuthWebActivity::class.java)
                        .putExtra(OAuthWebActivity.EXTRA_URL, url),
                    AUTH_REQUEST,
                )
            }

        MethodChannel(messenger, LOCAL_NOTIF_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermission" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                            ContextCompat.checkSelfPermission(
                                this,
                                Manifest.permission.POST_NOTIFICATIONS,
                            ) == PackageManager.PERMISSION_GRANTED
                        ) {
                            result.success("granted")
                        } else {
                            result.success("denied")
                        }
                    }
                    "notify" -> {
                        val id = call.argument<String>("id") ?: "rc_device_alert"
                        val title = call.argument<String>("title") ?: "录音卡"
                        val body = call.argument<String>("body") ?: ""
                        val urgent = call.argument<Boolean>("urgent") ?: false
                        result.success(showDeviceAlertNotification(id, title, body, urgent))
                    }
                    "cancel" -> {
                        val id = call.argument<String>("id") ?: "rc_device_alert"
                        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                        nm?.cancel(id, ALERT_NOTIF_ID)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun showDeviceAlertNotification(
        tag: String,
        title: String,
        body: String,
        urgent: Boolean,
    ): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val existing = nm.getNotificationChannel(ALERT_CHANNEL_ID)
            if (existing == null) {
                val ch = NotificationChannel(
                    ALERT_CHANNEL_ID,
                    "设备连接与兜底提醒",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "蓝牙意外断连、自动切换兜底设备与重连恢复提醒"
                }
                nm.createNotificationChannel(ch)
            }
        }
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val pendingIntent = PendingIntent.getActivity(this, 0, launchIntent, piFlags)
        val notif = NotificationCompat.Builder(this, ALERT_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(if (urgent) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()
        nm.notify(tag, ALERT_NOTIF_ID, notif)
        return true
    }

    private fun requiredBlePermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun areAllGranted(perms: Array<String>): Boolean =
        perms.all { perm ->
            ContextCompat.checkSelfPermission(this, perm) == PackageManager.PERMISSION_GRANTED
        }

    private fun blePermissionStatus(): String {
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            return "restricted"
        }
        val perms = requiredBlePermissions()
        if (areAllGranted(perms)) {
            return "granted"
        }
        val prefs = getSharedPreferences(BLE_PREFS, Context.MODE_PRIVATE)
        val requestedBefore = prefs.getBoolean(KEY_BLE_REQUESTED, false)
        val anyRationale = perms.any { perm ->
            ActivityCompat.shouldShowRequestPermissionRationale(this, perm)
        }
        // Android 首次拒绝后 anyRationale == true 仍允许第 2 次系统弹窗申请，仅永久拒绝时返回 denied
        return if (!requestedBefore || anyRationale) "notDetermined" else "denied"
    }

    private fun requestBlePermissions(result: MethodChannel.Result) {
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            result.success("restricted")
            return
        }
        val perms = requiredBlePermissions()
        if (areAllGranted(perms)) {
            result.success("granted")
            return
        }
        if (pendingBlePermResult != null) {
            result.success(blePermissionStatus())
            return
        }
        pendingBlePermResult = result
        getSharedPreferences(BLE_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_BLE_REQUESTED, true)
            .apply()
        val requestList = perms.toMutableList()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            requestList.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        ActivityCompat.requestPermissions(this, requestList.toTypedArray(), REQ_BLE_PERM)
    }

    // FlutterActivity 继承 Activity，没有 registerForActivityResult。
    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != AUTH_REQUEST) return
        val callback = pendingAuth
        pendingAuth = null
        if (callback == null) return
        val url = data?.dataString
        if (resultCode == Activity.RESULT_OK && !url.isNullOrBlank()) {
            callback.success(url)
        } else {
            callback.error("CANCELED", "User canceled authentication", null)
        }
    }

    override fun onInit(status: Int) {
        if (status != TextToSpeech.SUCCESS) {
            ttsReady = false
            ttsLanguageSupported = false
            ttsUnavailableMessage = "当前设备系统语音合成初始化失败"
            return
        }
        val engine = tts
        if (engine == null) {
            ttsReady = false
            ttsLanguageSupported = false
            return
        }
        ttsReady = true
        ttsLanguageSupported = configureTtsLanguage(engine, "zh-CN")
    }

    private fun configureTtsLanguage(engine: TextToSpeech, localeTag: String): Boolean {
        val candidates = listOf(
            Locale.forLanguageTag(localeTag),
            Locale.SIMPLIFIED_CHINESE,
            Locale.CHINA,
        )
        var lastResult = TextToSpeech.LANG_NOT_SUPPORTED
        for (loc in candidates) {
            if (loc.language.isNullOrBlank()) continue
            val res = try {
                engine.setLanguage(loc)
            } catch (_: Throwable) {
                TextToSpeech.LANG_NOT_SUPPORTED
            }
            lastResult = res
            if (res != TextToSpeech.LANG_MISSING_DATA && res != TextToSpeech.LANG_NOT_SUPPORTED) {
                return true
            }
        }
        ttsUnavailableMessage = if (lastResult == TextToSpeech.LANG_MISSING_DATA) {
            "系统语音合成缺少语音数据包，暂无法播报"
        } else {
            "当前系统语音合成不支持中文播报"
        }
        return false
    }

    private fun speakWithTts(text: String, localeTag: String) {
        val engine = tts
        if (!ttsReady || engine == null) {
            emitTtsFailure(ttsUnavailableMessage)
            return
        }
        ttsLanguageSupported = configureTtsLanguage(engine, localeTag)
        if (!ttsLanguageSupported) {
            emitTtsFailure(ttsUnavailableMessage)
            return
        }
        val speakRes = try {
            engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, "os1-${System.currentTimeMillis()}")
        } catch (_: Throwable) {
            TextToSpeech.ERROR
        }
        if (speakRes == TextToSpeech.ERROR) {
            emitTtsFailure("系统语音播报启动失败")
        }
    }

    private fun emitTtsFailure(message: String) {
        runOnUiThread {
            speechChannel?.invokeMethod("onSpeakState", mapOf("speaking" to false))
            speechChannel?.invokeMethod("onSpeechError", mapOf("message" to message))
        }
    }

    private fun startListening(locale: String, result: MethodChannel.Result) {
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            speechChannel?.invokeMethod("onSpeechError", mapOf("message" to "当前设备系统语音识别暂不可用"))
            result.success(false)
            return
        }
        val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) {
            pendingPermResult = result
            pendingPermLocale = locale
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), REQ_AUDIO_PERM)
            return
        }
        launchRecognizer(locale, result)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (systemSpeechBridge?.onRequestPermissionsResult(requestCode, grantResults) == true) {
            return
        }
        if (phoneMicBridge?.onRequestPermissionsResult(requestCode, grantResults) == true) {
            return
        }
        if (requestCode == REQ_BLE_PERM) {
            val res = pendingBlePermResult
            pendingBlePermResult = null
            if (res != null) {
                // 仅按 requiredBlePermissions() 判定授权结果；API 33+ 顺带请求的 POST_NOTIFICATIONS 被拒时不阻断蓝牙连接
                val granted = areAllGranted(requiredBlePermissions())
                res.success(if (granted) "granted" else "denied")
            }
            return
        }
        if (requestCode == REQ_AUDIO_PERM) {
            val res = pendingPermResult
            pendingPermResult = null
            if (res == null) return
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            if (granted) {
                launchRecognizer(pendingPermLocale, res)
            } else {
                speechChannel?.invokeMethod("onSpeechError", mapOf("message" to "需要麦克风权限才能语音对话"))
                res.success(false)
            }
        }
    }

    private fun launchRecognizer(locale: String, result: MethodChannel.Result) {
        tts?.stop()
        recognizer?.destroy()
        val sr = SpeechRecognizer.createSpeechRecognizer(this)
        recognizer = sr
        sr.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {
                if (recognizer !== sr) return
                speechChannel?.invokeMethod("onListenState", mapOf("listening" to true))
            }

            override fun onBeginningOfSpeech() {}

            override fun onRmsChanged(rmsdB: Float) {
                if (recognizer !== sr) return
                val level = ((rmsdB + 2f) / 12f).coerceIn(0f, 1f).toDouble()
                speechChannel?.invokeMethod("onSoundLevel", mapOf("level" to level))
            }

            override fun onBufferReceived(buffer: ByteArray?) {}

            override fun onEndOfSpeech() {
                if (recognizer !== sr) return
                speechChannel?.invokeMethod("onListenState", mapOf("listening" to false))
            }

            override fun onError(error: Int) {
                if (recognizer !== sr) return
                speechChannel?.invokeMethod("onListenState", mapOf("listening" to false))
                if (error == SpeechRecognizer.ERROR_CLIENT) return
                val msg = when (error) {
                    SpeechRecognizer.ERROR_NO_MATCH,
                    SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "未检测到清晰语音，请再试一次"
                    SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "需要麦克风权限才能语音对话"
                    else -> "语音识别失败（错误码 $error）"
                }
                speechChannel?.invokeMethod("onSpeechError", mapOf("message" to msg))
            }

            override fun onResults(results: Bundle?) {
                if (recognizer !== sr) return
                val list = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val text = list?.firstOrNull()?.trim() ?: ""
                speechChannel?.invokeMethod("onListenState", mapOf("listening" to false))
                if (text.isNotEmpty()) {
                    speechChannel?.invokeMethod("onTranscript", mapOf("text" to text, "isFinal" to true))
                }
            }

            override fun onPartialResults(partialResults: Bundle?) {
                if (recognizer !== sr) return
                val list = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val text = list?.firstOrNull()?.trim() ?: ""
                if (text.isNotEmpty()) {
                    speechChannel?.invokeMethod("onTranscript", mapOf("text" to text, "isFinal" to false))
                }
            }

            override fun onEvent(eventType: Int, params: Bundle?) {}
        })

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        }
        sr.startListening(intent)
        result.success(true)
    }

    override fun onDestroy() {
        phoneMicBridge?.destroy()
        phoneMicBridge = null
        systemSpeechBridge?.destroy()
        systemSpeechBridge = null
        recognizer?.destroy()
        tts?.shutdown()
        super.onDestroy()
    }
}
