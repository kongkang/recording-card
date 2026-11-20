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
 * 线程与生命周期安全约束（防 Android 8–15 `ForegroundServiceDidNotStartInTimeException`）：
 * 1. `dispatchUpdate` 在调用 `startForegroundService` 前先经 [resolveAllowedForegroundTypes] 校验对应权限，
 *    权限不满足时绝不发起无法调用 `startForeground` 的服务启动；
 * 2. 若 `startForegroundService` 已入队但主线程 `onStartCommand` 尚未完成 `startForeground`（`pendingForegroundStart == true`），
 *    外部停止请求绝不直接调 `stopService` 抢杀未晋升服务，而是交由 `onStartCommand` 完成一次合规 `startForeground` 后立即自停。
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

        private val stateLock = Any()

        @Volatile
        private var micActive: Boolean = false

        @Volatile
        private var bleActive: Boolean = false

        @Volatile
        private var isServiceRunning: Boolean = false

        @Volatile
        private var isPromoted: Boolean = false

        @Volatile
        private var pendingForegroundStart: Boolean = false

        @Volatile
        private var lastAuthorizedFgTypes: Int = 0

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
            val appCtx = context.applicationContext
            var canStopDirectly = false
            synchronized(stateLock) {
                micActive = false
                bleActive = false
                if (isServiceRunning && isPromoted && !pendingForegroundStart) {
                    canStopDirectly = true
                }
            }
            if (canStopDirectly) {
                try {
                    appCtx.stopService(Intent(appCtx, RecordingForegroundService::class.java))
                } catch (_: Throwable) {
                    // 忽略后台销毁异常
                }
            }
        }

        private fun hasMicPermission(context: Context): Boolean =
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED

        private fun hasConnectedDevicePermission(context: Context): Boolean {
            val changeWifiGranted =
                ContextCompat.checkSelfPermission(context, Manifest.permission.CHANGE_WIFI_STATE) ==
                    PackageManager.PERMISSION_GRANTED
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                return true
            }
            val btConnect =
                ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) ==
                    PackageManager.PERMISSION_GRANTED
            val btScan =
                ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_SCAN) ==
                    PackageManager.PERMISSION_GRANTED
            return btConnect || btScan || changeWifiGranted
        }

        fun resolveAllowedForegroundTypes(
            context: Context,
            useMic: Boolean,
            useBle: Boolean,
        ): Int {
            var types = 0
            if (useMic && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && hasMicPermission(context)) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
            if (useBle && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && hasConnectedDevicePermission(context)) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            }
            return types
        }

        private fun canPromoteOnCurrentApi(
            context: Context,
            useMic: Boolean,
            useBle: Boolean,
            allowedTypes: Int,
        ): Boolean {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                return allowedTypes != 0
            }
            // API <= 29: FOREGROUND_SERVICE_TYPE_MICROPHONE 尚未引入，2 参数 startForeground 合法可用
            return (useMic && hasMicPermission(context)) ||
                (useBle && hasConnectedDevicePermission(context))
        }

        private fun dispatchUpdate(
            context: Context,
            source: String,
            active: Boolean,
            title: String?,
            subtitle: String?,
        ) {
            val appCtx = context.applicationContext
            var shouldStartFg = false
            var shouldStopNow = false

            synchronized(stateLock) {
                if (source == SOURCE_MIC) {
                    micActive = active
                } else {
                    bleActive = active
                }
                val nowAnyActive = micActive || bleActive
                if (nowAnyActive) {
                    val allowedTypes = resolveAllowedForegroundTypes(appCtx, micActive, bleActive)
                    if (!canPromoteOnCurrentApi(appCtx, micActive, bleActive, allowedTypes)) {
                        if (source == SOURCE_MIC) micActive = false else bleActive = false
                        return
                    }
                    if (allowedTypes != 0) {
                        lastAuthorizedFgTypes = allowedTypes
                    }
                    if (!isPromoted) {
                        pendingForegroundStart = true
                    }
                    isServiceRunning = true
                    shouldStartFg = true
                } else {
                    if (!isServiceRunning && !pendingForegroundStart) {
                        return
                    }
                    if (isPromoted && !pendingForegroundStart) {
                        shouldStopNow = true
                    }
                    // 若 pendingForegroundStart == true，绝不在此刻调 stopService；
                    // 排队中的 onStartCommand 会先完成合规 startForeground 再立即自停。
                }
            }

            if (shouldStartFg) {
                val intent = Intent(appCtx, RecordingForegroundService::class.java).apply {
                    action = ACTION_UPDATE
                    putExtra(EXTRA_SOURCE, source)
                    putExtra(EXTRA_ACTIVE, active)
                    if (!title.isNullOrBlank()) putExtra(EXTRA_TITLE, title)
                    if (!subtitle.isNullOrBlank()) putExtra(EXTRA_SUBTITLE, subtitle)
                }
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        appCtx.startForegroundService(intent)
                    } else {
                        appCtx.startService(intent)
                    }
                } catch (_: Throwable) {
                    synchronized(stateLock) {
                        if (!isPromoted) {
                            pendingForegroundStart = false
                            isServiceRunning = false
                        }
                    }
                }
            } else if (shouldStopNow) {
                try {
                    appCtx.stopService(
                        Intent(appCtx, RecordingForegroundService::class.java).apply {
                            action = ACTION_STOP_ALL
                        },
                    )
                } catch (_: Throwable) {
                    // ignore
                }
            }
        }
    }

    private var lastTitle: String = "录音卡"
    private var lastBleSubtitle: String = "蓝牙录音运行中"
    private var lastMicSubtitle: String = "本机录音运行中"

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
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

        val (currentlyActive, mustPromoteBeforeStop, fallbackTypes) = synchronized(stateLock) {
            val activeNow = action != ACTION_STOP_ALL && (micActive || bleActive)
            val mustPromote = !activeNow &&
                (pendingForegroundStart || !isPromoted) &&
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
            Triple(activeNow, mustPromote, lastAuthorizedFgTypes)
        }

        ensureChannel()
        val resolvedSubtitle = when {
            micActive -> lastMicSubtitle
            bleActive -> lastBleSubtitle
            else -> "录音运行中"
        }
        val notification = buildNotification(lastTitle, resolvedSubtitle)

        if (!currentlyActive) {
            if (mustPromoteBeforeStop) {
                promoteForegroundSafely(notification, fallbackTypes = fallbackTypes)
            }
            stopForegroundAndSelf()
            return START_NOT_STICKY
        }

        if (!promoteForegroundSafely(notification, fallbackTypes = fallbackTypes)) {
            stopForegroundAndSelf()
            return START_NOT_STICKY
        }

        val stillActiveAfterPromote = synchronized(stateLock) {
            isPromoted = true
            pendingForegroundStart = false
            micActive || bleActive
        }
        if (!stillActiveAfterPromote) {
            stopForegroundAndSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopForegroundRemoveOnly()
        synchronized(stateLock) {
            micActive = false
            bleActive = false
            isPromoted = false
            pendingForegroundStart = false
            isServiceRunning = false
        }
        super.onDestroy()
    }

    private fun promoteForegroundSafely(
        notification: Notification,
        fallbackTypes: Int,
    ): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val liveTypes = resolveAllowedForegroundTypes(this, micActive, bleActive)
                val fgTypes = if (liveTypes != 0) liveTypes else fallbackTypes
                if (fgTypes != 0) {
                    startForeground(NOTIFICATION_ID, notification, fgTypes)
                } else if (Build.VERSION.SDK_INT == Build.VERSION_CODES.Q) {
                    startForeground(NOTIFICATION_ID, notification)
                } else {
                    return false
                }
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            synchronized(stateLock) {
                isPromoted = true
                pendingForegroundStart = false
            }
            true
        } catch (_: Throwable) {
            false
        }
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

    private fun stopForegroundRemoveOnly() {
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
    }

    private fun stopForegroundAndSelf() {
        stopForegroundRemoveOnly()
        synchronized(stateLock) {
            isPromoted = false
            pendingForegroundStart = false
            isServiceRunning = false
        }
        stopSelf()
    }
}
