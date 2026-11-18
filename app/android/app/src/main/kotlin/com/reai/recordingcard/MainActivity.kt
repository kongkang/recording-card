package com.reai.recordingcard

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity(), TextToSpeech.OnInitListener {
    companion object {
        init {
            // Android：必须从 Java 侧加载 card_bridge，JNI_OnLoad 才会被 ART 调用，
            // 把 JavaVM 交给 btleplug droidplug 后端（裸 dlopen 不触发 JNI_OnLoad）。
            // 加载后 Dart 侧 DynamicLibrary.process() 即可看到桥符号。
            System.loadLibrary("card_bridge")
        }

        private const val SPEECH_CHANNEL = "com.reai.recordingcard/agent_speech"
        private const val REQ_AUDIO_PERM = 4091
    }

    private var speechChannel: MethodChannel? = null
    private var systemSpeechBridge: SystemSpeechBridge? = null
    private var recognizer: SpeechRecognizer? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var pendingPermResult: MethodChannel.Result? = null
    private var pendingPermLocale: String = "zh-CN"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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

            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) {
                runOnUiThread {
                    speechChannel?.invokeMethod("onSpeakState", mapOf("speaking" to false))
                }
            }
        })

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SPEECH_CHANNEL)
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
                    if (text.isNotEmpty() && ttsReady) {
                        tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "os1-${System.currentTimeMillis()}")
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
        sysSpeech.register(flutterEngine.dartExecutor.binaryMessenger)
        systemSpeechBridge = sysSpeech
    }

    override fun onInit(status: Int) {
        ttsReady = status == TextToSpeech.SUCCESS
        if (ttsReady) {
            tts?.setLanguage(Locale.SIMPLIFIED_CHINESE)
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
        systemSpeechBridge?.destroy()
        systemSpeechBridge = null
        recognizer?.destroy()
        tts?.shutdown()
        super.onDestroy()
    }
}
