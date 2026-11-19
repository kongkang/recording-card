package com.reai.recordingcard

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.webkit.CookieManager
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient

/// 在 App 内打开授权页，并在跳到 reai-mobile://callback 时把结果交回登录流程。
/// 系统浏览器处理这个 scheme 时，外脑 App 也注册了同一回调，会弹出选择框，回不到本 App。
class OAuthWebActivity : Activity() {
    private var webView: WebView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.getStringExtra(EXTRA_URL)
        if (url.isNullOrBlank()) {
            setResult(RESULT_CANCELED)
            finish()
            return
        }

        val view = WebView(this)
        webView = view
        view.setBackgroundColor(Color.WHITE)
        view.settings.javaScriptEnabled = true
        view.settings.domStorageEnabled = true
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(view, true)
        view.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                return intercept(request.url)
            }

            @Deprecated("Deprecated in Java")
            override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean {
                return intercept(Uri.parse(url))
            }

            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError,
            ) {
                if (request.isForMainFrame) intercept(request.url)
            }
        }
        setContentView(view)
        view.loadUrl(url)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        val view = webView
        if (view != null && view.canGoBack()) {
            view.goBack()
            return
        }
        setResult(RESULT_CANCELED)
        super.onBackPressed()
    }

    override fun onDestroy() {
        webView?.destroy()
        webView = null
        super.onDestroy()
    }

    private fun intercept(uri: Uri): Boolean {
        if (uri.scheme != CALLBACK_SCHEME || uri.host != CALLBACK_HOST) return false
        setResult(RESULT_OK, Intent().setData(uri))
        finish()
        return true
    }

    companion object {
        const val EXTRA_URL = "url"
        private const val CALLBACK_SCHEME = "reai-mobile"
        private const val CALLBACK_HOST = "callback"
    }
}
