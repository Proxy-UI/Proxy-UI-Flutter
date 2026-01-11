package com.proxyui.proxy_ui

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class VpnPlugin(
    private val activity: FlutterActivity,
    private val channel: MethodChannel
) : MethodChannel.MethodCallHandler, PluginRegistry.ActivityResultListener {

    companion object {
        private const val TAG = "VpnPlugin"
        private const val VPN_REQUEST_CODE = 100
    }

    private var pendingResult: MethodChannel.Result? = null

    init {
        ProxyVpnService.methodChannel = channel
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> handleStart(call, result)
            "stop" -> handleStop(result)
            "isRunning" -> result.success(isVpnRunning())
            "prepare" -> handlePrepare(result)
            "protectSocket" -> {
                val fd = call.argument<Int>("fd") ?: -1
                result.success(ProxyVpnService.protectSocket(fd))
            }
            else -> result.notImplemented()
        }
    }

    private fun handlePrepare(result: MethodChannel.Result) {
        val intent = VpnService.prepare(activity)
        if (intent != null) {
            result.success(false)
        } else {
            result.success(true)
        }
    }

    private fun handleStart(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "Starting VPN service")

        val intent = VpnService.prepare(activity)
        if (intent != null) {
            Log.d(TAG, "VPN permission not granted, requesting")
            pendingResult = result
            activity.startActivityForResult(intent, VPN_REQUEST_CODE)
        } else {
            Log.d(TAG, "VPN permission already granted, starting service")
            startVpnService()
            result.success(true)
        }
    }

    private fun handleStop(result: MethodChannel.Result) {
        Log.d(TAG, "Stopping VPN service")

        try {
            val intent = Intent(activity, ProxyVpnService::class.java)
            activity.stopService(intent)
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping VPN service", e)
            result.error("STOP_ERROR", e.message, null)
        }
    }

    private fun isVpnRunning(): Boolean {
        return ProxyVpnService.getInstance() != null
    }

    private fun startVpnService() {
        val intent = Intent(activity, ProxyVpnService::class.java)
        activity.startForegroundService(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == VPN_REQUEST_CODE) {
            val result = pendingResult
            pendingResult = null

            if (resultCode == Activity.RESULT_OK) {
                Log.d(TAG, "VPN permission granted")
                startVpnService()
                result?.success(true)
            } else {
                Log.d(TAG, "VPN permission denied")
                result?.error("PERMISSION_DENIED", "User denied VPN permission", null)
            }
            return true
        }
        return false
    }
}
