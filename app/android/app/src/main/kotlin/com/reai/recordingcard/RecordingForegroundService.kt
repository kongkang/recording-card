package com.reai.recordingcard

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.content.ContextCompat

/**
 * Android 录音与蓝牙同步前台保活服务（`foregroundServiceType="connectedDevice|microphone"`）。
 *
 * 同时承载两路独立生命周期引用：
 * - `SOURCE_MIC`：由 [PhoneMicBridge] 在本机录音 / 蓝牙断连保底接力时启停；
 * - `SOURCE_BLE`：由 `com.reai.recordingcard/bluetooth` (`setRecordingForeground`) 或
 *   `com.reai.recordingcard/live_activity` 在蓝牙硬件录音期间启停。
 * 任一路活跃即维持常驻低打扰通知，两路均结束后自动 `stopForeground` 并销毁服务。
 */
class RecordingForegroundService : Service() {
    companion object {
        private const val CHANNEL_ID = "rc_recording_foreground"
        private const val NOTIFICATION_ID = 0x524301

        private const val ACTION_UPDATE = "com.reai.recordingcard.action.FG_UPDATE"
        private const val ACTION_STOP_ALL = "com.reai.recordingcard.action.FG_STOP_ALL"

        private const val EXTRA_SOURCE = "source"
        private const val EXTRA_ACTIVE = "active"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_SUBTITLE = "subtitle"

        private const val SOURCE_MIC = "mic"
        private const val SOURCE_BLE = "ble"

        @Volatile
        private var micActive: Boolean = false

        @Volatile
        private var bleActive: Boolean = false

        fun setMicrophoneActive(
            context: Context,
            active: Boolean,
            title: String? = null,
            subtitle: String? = null,
        ) {
            dispatchUpdate(context, SOURCE_MIC, active, title, subtitle)
        }

        fun setConnectedDeviceActive(
            context: Context,
            active: Boolean,
            title: String? = null,
            subtitle: String? = null,
        ) {
            dispatchUpdate(context, SOURCE_BLE, active, title, subtitle)
        }

        fun stopAll(context: Context) {
            micActive = false
            bleActive = false
            try {
                context.stopService(Intent(context, RecordingForegroundService::class.java))
            } catch (_: Throwable) {
                // 忽略后台销毁异常
            }
        }

        private fun dispatchUpdate(
            context: Context,
            source: String,
            active: Boolean,
            title: String?,
            subtitle: String?,
        ) {
            val appCtx = context.applicationContext
            val wasAnyActive = micActive || bleActive
            if (source == SOURCE_MIC) {
                micActive = active
            } else {
                bleActive = active
            }
            val nowAnyActive = micActive || bleActive

            if (!nowAnyActive && !wasAnyActive) {
                return
            }

            val intent = Intent(appCtx, RecordingForegroundService::class.java).apply {
                action = if (nowAnyActive) ACTION_UPDATE else ACTION_STOP_ALL
                putExtra(EXTRA_SOURCE, source)
                putExtra(EXTRA_ACTIVE, active)
                if (!title.isNullOrBlank()) putExtra(EXTRA_TITLE, title)
                if (!subtitle.isNullOrBlank()) putExtra(EXTRA_SUBTITLE, subtitle)
            }

            try {
                if (nowAnyActive) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        appCtx.startForegroundService(intent)
                    } else {
                        appCtx.startService(intent)
                    }
                } else {
                    appCtx.stopService(intent)
                }
            } catch (_: Throwable) {
                // Android 12+ 后台限制或缺少权限时安全降级，绝不造成宿主进程崩溃
            }
        }
    }

    private var lastTitle: String = "录音卡"
    private var lastBleSubtitle: String = "蓝牙录音运行中"
    private var lastMicSubtitle: String = "本机录音运行中"

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_STOP_ALL || (!micActive && !bleActive)) {
            stopForegroundAndSelf()
            return START_NOT_STICKY
        }

        val source = intent?.getStringExtra(EXTRA_SOURCE)
        intent?.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() }?.let {
            lastTitle = it
        }
        intent?.getStringExtra(EXTRA_SUBTITLE)?.takeIf { it.isNotBlank() }?.let { sub ->
            if (source == SOURCE_MIC) {
                lastMicSubtitle = sub
            } else {
                lastBleSubtitle = sub
            }
        }

        val resolvedSubtitle = when {
            micActive -> lastMicSubtitle
            bleActive -> lastBleSubtitle
            else -> "录音运行中"
        }

        ensureChannel()
        val notification = buildNotification(lastTitle, resolvedSubtitle)
        if (!promoteForegroundSafely(notification)) {
            stopForegroundAndSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        micActive = false
        bleActive = false
        super.onDestroy()
    }

    private fun promoteForegroundSafely(notification: Notification): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val fgTypes = resolveAllowedForegroundTypes()
                if (fgTypes == 0) {
                    return false
                }
                startForeground(NOTIFICATION_ID, notification, fgTypes)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (_: Throwable) {
            false
        }
    }

    private fun resolveAllowedForegroundTypes(): Int {
        var types = 0
        if (micActive && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && hasMicPermission()) {
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }
        if ((bleActive || types == 0) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && hasConnectedDevicePermission()) {
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        }
        return types
    }

    private fun hasMicPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasConnectedDevicePermission(): Boolean {
        val changeWifiGranted =
            ContextCompat.checkSelfPermission(this, Manifest.permission.CHANGE_WIFI_STATE) ==
                PackageManager.PERMISSION_GRANTED
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            return true
        }
        val btConnect =
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED
        val btScan =
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN) ==
                PackageManager.PERMISSION_GRANTED
        return btConnect || btScan || changeWifiGranted
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val ch = NotificationChannel(
            CHANNEL_ID,
            "录音状态常驻通知",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "在锁屏或后台保持录音卡蓝牙同步与本机保底录音不断连"
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        nm.createNotificationChannel(ch)
    }

    private fun buildNotification(title: String, subtitle: String): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val piFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pendingIntent = PendingIntent.getActivity(this, 0, launchIntent, piFlags)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(subtitle)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    private fun stopForegroundAndSelf() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Throwable) {
            // ignore
        }
        stopSelf()
    }
}
