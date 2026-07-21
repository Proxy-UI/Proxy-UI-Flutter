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
import android.util.LruCache
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.Locale
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingStart: PendingStart? = null
    private val applicationExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "vpn-application-catalog").apply { isDaemon = true }
    }

    @Volatile
    private var installedApplicationsCache: List<Map<String, Any>>? = null
    private val applicationIconCache =
        object : LruCache<String, ByteArray>(APPLICATION_ICON_CACHE_BYTES) {
            override fun sizeOf(
                key: String,
                value: ByteArray,
            ): Int = value.size
        }

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
            "listInstalledApps" -> listInstalledApps(call, result)
            "loadAppIcons" -> loadAppIcons(call, result)
            "startVpn" -> startVpn(call, result)
            "stopVpn" -> stopVpn(result)
            "getVpnState" -> result.success(ProxyVpnController.running)
            "getVpnNetworkState" -> result.success(
                mapOf(
                    "validated" to ProxyVpnController.networkValidated,
                    "diagnostics" to ProxyVpnController.networkDiagnostics,
                ),
            )
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
            onSuccess = { fd, diagnostics ->
                runOnUiThread {
                    result.success(
                        mapOf(
                            "fd" to fd,
                            "mtu" to configuration.mtu,
                            "diagnostics" to diagnostics,
                        ),
                    )
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

    private fun listInstalledApps(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val forceRefresh = call.argument<Boolean>("forceRefresh") ?: false
        if (!forceRefresh) {
            installedApplicationsCache?.let { cached ->
                result.success(cached)
                return
            }
        }

        applicationExecutor.execute {
            try {
                if (forceRefresh) {
                    installedApplicationsCache = null
                    applicationIconCache.evictAll()
                }
                val rows = installedApplicationsCache ?: queryInstalledApplications().also {
                    installedApplicationsCache = it
                }
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
        }
    }

    private fun queryInstalledApplications(): List<Map<String, Any>> {
        val packages = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getInstalledPackages(
                PackageManager.PackageInfoFlags.of(PackageManager.GET_PERMISSIONS.toLong()),
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.getInstalledPackages(PackageManager.GET_PERMISSIONS)
        }
        return packages.asSequence()
            .filter { packageInfo ->
                packageInfo.requestedPermissions?.contains(Manifest.permission.INTERNET) == true
            }
            .mapNotNull { packageInfo ->
                val application = packageInfo.applicationInfo ?: return@mapNotNull null
                if (!application.enabled || application.packageName == packageName) {
                    return@mapNotNull null
                }
                val label = packageManager.getApplicationLabel(application).toString()
                    .ifBlank { application.packageName }
                mapOf(
                    "packageName" to application.packageName,
                    "label" to label,
                    "system" to ((application.flags and ApplicationInfo.FLAG_SYSTEM) != 0),
                )
            }
            .sortedWith(
                compareBy<Map<String, Any>> {
                    (it.getValue("label") as String).lowercase(Locale.getDefault())
                }.thenBy { it.getValue("packageName") as String },
            )
            .toList()
    }

    private fun loadAppIcons(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val packages = call.argument<List<String>>("packages")
            .orEmpty()
            .asSequence()
            .map(String::trim)
            .filter(String::isNotEmpty)
            .filter { it != packageName }
            .distinct()
            .take(MAX_APPLICATION_ICON_BATCH)
            .toList()
        if (packages.isEmpty()) {
            result.success(emptyMap<String, ByteArray>())
            return
        }

        applicationExecutor.execute {
            val icons = linkedMapOf<String, ByteArray>()
            for (applicationPackage in packages) {
                try {
                    val icon = applicationIconCache.get(applicationPackage)
                        ?: encodeIcon(packageManager.getApplicationIcon(applicationPackage)).also {
                            applicationIconCache.put(applicationPackage, it)
                        }
                    icons[applicationPackage] = icon
                } catch (_: PackageManager.NameNotFoundException) {
                    // The package may have been removed after the catalog snapshot.
                } catch (_: RuntimeException) {
                    // A broken package resource must not delay the remaining icons.
                }
            }
            runOnUiThread { result.success(icons) }
        }
    }

    override fun onDestroy() {
        applicationExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun encodeIcon(drawable: Drawable): ByteArray {
        val size = APPLICATION_ICON_SIZE
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        return try {
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, size, size)
            drawable.draw(canvas)
            ByteArrayOutputStream(size * size).use { output ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
                output.toByteArray()
            }
        } finally {
            bitmap.recycle()
        }
    }

    private data class PendingStart(
        val configuration: VpnConfiguration,
        val result: MethodChannel.Result,
    )

    private companion object {
        const val CHANNEL = "com.proxyui.proxy_ui/vpn"
        const val VPN_PERMISSION_REQUEST = 4107
        const val APPLICATION_ICON_SIZE = 48
        const val APPLICATION_ICON_CACHE_BYTES = 4 * 1024 * 1024
        const val MAX_APPLICATION_ICON_BATCH = 32
    }
}
