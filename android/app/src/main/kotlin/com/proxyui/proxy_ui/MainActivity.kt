package com.proxyui.proxy_ui

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.net.VpnService
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.Locale

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingStart: PendingStart? = null

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VPN_PERMISSION_REQUEST) return

        val pending = pendingStart ?: return
        pendingStart = null
        if (resultCode != Activity.RESULT_OK) {
            pending.result.error(
                "vpn_permission_denied",
                "Android VPN permission was not granted",
                null,
            )
            return
        }
        launchVpnService(pending.configuration, pending.result)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also { methodChannel ->
            methodChannel.setMethodCallHandler(::handleMethodCall)
        }
        ProxyVpnController.stateListener = { running, error ->
            runOnUiThread {
                channel?.invokeMethod(
                    "vpnStateChanged",
                    mapOf("running" to running, "error" to error),
                )
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        ProxyVpnController.stateListener = null
        channel?.setMethodCallHandler(null)
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listInstalledApps" -> listInstalledApps(result)
            "startVpn" -> startVpn(call, result)
            "stopVpn" -> stopVpn(result)
            "getVpnState" -> result.success(ProxyVpnController.running)
            else -> result.notImplemented()
        }
    }

    private fun startVpn(call: MethodCall, result: MethodChannel.Result) {
        if (pendingStart != null || ProxyVpnController.startPending) {
            result.error("vpn_busy", "Another VPN operation is already in progress", null)
            return
        }

        val configuration = try {
            VpnConfiguration.fromCall(call)
        } catch (error: IllegalArgumentException) {
            result.error("vpn_invalid_config", error.message, null)
            return
        }

        val permissionIntent = VpnService.prepare(this)
        if (permissionIntent != null) {
            pendingStart = PendingStart(configuration, result)
            @Suppress("DEPRECATION")
            startActivityForResult(permissionIntent, VPN_PERMISSION_REQUEST)
            return
        }
        launchVpnService(configuration, result)
    }

    private fun launchVpnService(
        configuration: VpnConfiguration,
        result: MethodChannel.Result,
    ) {
        val accepted = ProxyVpnController.beginStart(
            onSuccess = { fd ->
                runOnUiThread {
                    result.success(mapOf("fd" to fd, "mtu" to configuration.mtu))
                }
            },
            onError = { error ->
                runOnUiThread { result.error("vpn_start_failed", error, null) }
            },
        )
        if (!accepted) {
            result.error("vpn_busy", "Another VPN operation is already in progress", null)
            return
        }

        try {
            val intent = ProxyVpnService.startIntent(this, configuration)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (error: Exception) {
            ProxyVpnController.failStart(error.message ?: "Failed to launch VPN service")
        }
    }

    private fun stopVpn(result: MethodChannel.Result) {
        if (!ProxyVpnController.running && !ProxyVpnController.startPending) {
            result.success(true)
            return
        }
        if (!ProxyVpnController.beginStop { error ->
                runOnUiThread {
                    if (error == null) {
                        result.success(true)
                    } else {
                        result.error("vpn_stop_failed", error, null)
                    }
                }
            }) {
            result.error("vpn_busy", "Another VPN operation is already in progress", null)
            return
        }
        try {
            startService(ProxyVpnService.stopIntent(this))
        } catch (error: Exception) {
            ProxyVpnController.completeStop(error.message)
        }
    }

    private fun listInstalledApps(result: MethodChannel.Result) {
        Thread {
            try {
                val packageManager = packageManager
                val applications = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    packageManager.getInstalledApplications(
                        PackageManager.ApplicationInfoFlags.of(PackageManager.GET_META_DATA.toLong()),
                    )
                } else {
                    @Suppress("DEPRECATION")
                    packageManager.getInstalledApplications(PackageManager.GET_META_DATA)
                }
                val rows = applications.asSequence()
                    .filter { it.enabled && it.packageName != packageName }
                    .filter {
                        packageManager.checkPermission(
                            Manifest.permission.INTERNET,
                            it.packageName,
                        ) == PackageManager.PERMISSION_GRANTED
                    }
                    .map { application ->
                        val label = packageManager.getApplicationLabel(application).toString()
                            .ifBlank { application.packageName }
                        mapOf(
                            "packageName" to application.packageName,
                            "label" to label,
                            "system" to ((application.flags and ApplicationInfo.FLAG_SYSTEM) != 0),
                            "icon" to encodeIcon(packageManager.getApplicationIcon(application)),
                        )
                    }
                    .sortedWith(
                        compareBy<Map<String, Any?>> {
                            (it["label"] as String).lowercase(Locale.getDefault())
                        }.thenBy { it["packageName"] as String },
                    )
                    .toList()
                runOnUiThread { result.success(rows) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "vpn_apps_failed",
                        error.message ?: "Failed to enumerate installed applications",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun encodeIcon(drawable: Drawable): ByteArray {
        val size = 64
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        return ByteArrayOutputStream().use { output ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
            bitmap.recycle()
            output.toByteArray()
        }
    }

    private data class PendingStart(
        val configuration: VpnConfiguration,
        val result: MethodChannel.Result,
    )

    private companion object {
        const val CHANNEL = "com.proxyui.proxy_ui/vpn"
        const val VPN_PERMISSION_REQUEST = 4107
    }
}
