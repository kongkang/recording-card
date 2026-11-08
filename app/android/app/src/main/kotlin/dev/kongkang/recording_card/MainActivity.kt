package dev.kongkang.recording_card

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object CardNative {
    init { System.loadLibrary("card_bridge") }
    @JvmStatic external fun initialize(): String?
}

class MainActivity : FlutterActivity() {
    private var permissionResult: MethodChannel.Result? = null
    private val permissionRequest = 7314
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "recording_card/card_native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> initializeWithPermissions(result)
                    "openWifiSettings" -> {
                        startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
    private fun initializeWithPermissions(result: MethodChannel.Result) {
        if (permissionResult != null) { result.error("busy", "蓝牙权限请求正在进行", null); return }
        val permissions = if (Build.VERSION.SDK_INT >= 31) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else { arrayOf(Manifest.permission.ACCESS_FINE_LOCATION) }
        val missing = permissions.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) {
            permissionResult = result
            requestPermissions(missing.toTypedArray(), permissionRequest)
        } else { initializeNative(result) }
    }
    private fun initializeNative(result: MethodChannel.Result) {
        try {
            val error = CardNative.initialize()
            if (error == null) result.success(null) else result.error("native", error, null)
        } catch (_: Throwable) {
            result.error("native", "Rust蓝牙库或btleplug Java类未链接/初始化失败", null)
        }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == permissionRequest) {
            val result = permissionResult ?: return
            permissionResult = null
            if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) initializeNative(result)
            else result.error("permission", "蓝牙扫描/连接权限未授予", null)
        }
    }
}
