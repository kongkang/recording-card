package com.reai.recordingcard

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import com.linusu.flutter_web_auth_2.AuthenticationManagementActivity
import com.linusu.flutter_web_auth_2.FlutterWebAuth2Plugin

/// 接收外部打开的 reai-mobile://callback，把授权结果交回等待中的会话，再把主界面拉回前台。
class OAuthCallbackActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        completeCallback(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        completeCallback(intent)
    }

    private fun completeCallback(sourceIntent: Intent?) {
        val expectedScheme = getString(R.string.rc_oauth_callback_scheme)
        val callbackUri = sourceIntent?.data
        val scheme = callbackUri?.scheme
        if (scheme != expectedScheme || callbackUri == null) {
            Log.w(TAG, "忽略无效的 OAuth 回调 scheme=$scheme (expected=$expectedScheme)")
            finish()
            return
        }

        val callback = FlutterWebAuth2Plugin.callbacks.remove(scheme)
        if (callback == null) {
            Log.e(TAG, "没有等待中的 OAuth 会话，scheme=$scheme")
        } else {
            callback.success(callbackUri.toString())
        }

        try {
            startActivity(AuthenticationManagementActivity.createResponseHandlingIntent(this))
        } catch (error: Exception) {
            Log.w(TAG, "关闭授权页失败：$error")
        }
        try {
            startActivity(
                Intent(this, MainActivity::class.java).apply {
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP,
                    )
                },
            )
        } catch (error: Exception) {
            Log.w(TAG, "拉回主界面失败：$error")
        }
        finish()
    }

    companion object {
        private const val TAG = "OAuthCallbackActivity"
    }
}
