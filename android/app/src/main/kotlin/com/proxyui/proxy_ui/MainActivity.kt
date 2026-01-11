package com.proxyui.proxy_ui

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val VPN_CHANNEL = "com.proxyui.proxy_ui/vpn"
    private var vpnPlugin: VpnPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VPN_CHANNEL)
        vpnPlugin = VpnPlugin(this, channel)
        channel.setMethodCallHandler(vpnPlugin)

        flutterEngine.plugins.add(vpnPlugin!!)
    }

    override fun onDestroy() {
        vpnPlugin = null
        super.onDestroy()
    }
}
