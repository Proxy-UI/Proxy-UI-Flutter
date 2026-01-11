package com.proxyui.proxy_ui

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.MethodChannel

class ProxyVpnService : VpnService() {
    private var tunInterface: ParcelFileDescriptor? = null
    private var tunFd: Int = -1

    companion object {
        private const val TAG = "ProxyVpnService"
        private const val NOTIFICATION_ID = 1
        private const val CHANNEL_ID = "vpn_channel"

        @Volatile
        private var instance: ProxyVpnService? = null

        @Volatile
        var methodChannel: MethodChannel? = null

        fun getInstance(): ProxyVpnService? = instance

        // JNI method: registers a native protect() callback for Rust.
        @JvmStatic
        external fun nativeRegisterProtectCallback()

        init {
            try {
                System.loadLibrary("http_proxy")
                nativeRegisterProtectCallback()
            } catch (e: UnsatisfiedLinkError) {
                Log.e(TAG, "Failed to load native library", e)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to register native protect callback", e)
            }
        }

        @JvmStatic
        fun protectSocket(fd: Int): Boolean {
            return instance?.protect(fd) ?: false
        }

        // Called from Rust via JNI.
        @JvmStatic
        fun protectSocketFromJNI(fd: Int): Boolean {
            return protectSocket(fd)
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        Log.d(TAG, "VPN Service created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "VPN Service starting")

        createNotificationChannel()
        startForeground(NOTIFICATION_ID, createNotification())

        try {
            val builder = Builder()
                .addAddress("172.19.0.1", 30)
                .addRoute("0.0.0.0", 0)
                .addDnsServer("8.8.8.8")
                .addDnsServer("8.8.4.4")
                .setMtu(9000)
                .setSession("ProxyEverything")
                .setBlocking(false)

            tunInterface = builder.establish()
            tunFd = tunInterface?.detachFd() ?: -1

            if (tunFd >= 0) {
                Log.d(TAG, "VPN established with FD: $tunFd")
                notifyFlutter("vpn_started", mapOf("fd" to tunFd, "success" to true))
            } else {
                Log.e(TAG, "Failed to establish VPN")
                notifyFlutter("vpn_error", mapOf("error" to "Failed to establish VPN"))
                stopSelf()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error starting VPN", e)
            notifyFlutter("vpn_error", mapOf("error" to e.message))
            stopSelf()
        }

        return START_STICKY
    }

    override fun onDestroy() {
        Log.d(TAG, "VPN Service destroying")

        try {
            tunInterface?.close()
            tunInterface = null
            tunFd = -1
        } catch (e: Exception) {
            Log.e(TAG, "Error closing TUN interface", e)
        }

        notifyFlutter("vpn_stopped", mapOf("success" to true))
        instance = null
        super.onDestroy()
    }

    override fun onRevoke() {
        Log.d(TAG, "VPN permission revoked")
        notifyFlutter("vpn_revoked", mapOf("reason" to "Permission revoked"))
        stopSelf()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "VPN Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Proxy VPN Service"
            }

            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun createNotification(): Notification {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Proxy VPN")
            .setContentText("VPN is running")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    private fun notifyFlutter(event: String, data: Map<String, Any>) {
        methodChannel?.invokeMethod(event, data)
    }
}
