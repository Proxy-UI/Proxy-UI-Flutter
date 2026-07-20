package com.proxyui.proxy_ui

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import io.flutter.plugin.common.MethodCall
import java.util.concurrent.ConcurrentHashMap

internal data class VpnConfiguration(
    val mode: String,
    val packages: List<String>,
    val mtu: Int,
) {
    companion object {
        private val validModes = setOf("all", "exclude", "include")

        fun fromCall(call: MethodCall): VpnConfiguration {
            val mode = call.argument<String>("mode") ?: "all"
            require(mode in validModes) { "Unsupported Android VPN routing mode: $mode" }
            val packages = call.argument<List<String>>("packages")
                .orEmpty()
                .map(String::trim)
                .filter(String::isNotEmpty)
                .distinct()
                .sorted()
            require(mode != "include" || packages.isNotEmpty()) {
                "Select at least one application for VPN-only mode"
            }
            val mtu = call.argument<Int>("mtu") ?: DEFAULT_MTU
            require(mtu in 1280..9000) { "VPN MTU must be between 1280 and 9000" }
            return VpnConfiguration(mode, packages, mtu)
        }

        const val DEFAULT_MTU = 1500
    }
}

class ProxyVpnService : VpnService() {
    private var vpnInterface: ParcelFileDescriptor? = null
    private var shuttingDown = false
    private var networkCallbackRegistered = false
    @Volatile
    private var underlyingNetwork: Network? = null
    @Volatile
    private var vpnNetwork: Network? = null
    private val underlyingCandidates = ConcurrentHashMap.newKeySet<Network>()

    private val connectivity by lazy {
        getSystemService(ConnectivityManager::class.java)
    }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            underlyingCandidates.add(network)
            selectUnderlyingNetwork("available")
        }

        override fun onCapabilitiesChanged(
            network: Network,
            networkCapabilities: NetworkCapabilities,
        ) {
            if (isUsableUnderlying(networkCapabilities)) {
                underlyingCandidates.add(network)
            } else {
                underlyingCandidates.remove(network)
            }
            selectUnderlyingNetwork("capabilities_changed")
        }

        override fun onLost(network: Network) {
            underlyingCandidates.remove(network)
            selectUnderlyingNetwork("lost")
        }
    }

    private val vpnNetworkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            connectivity.getNetworkCapabilities(network)?.let { capabilities ->
                publishVpnNetworkState(network, capabilities, "available")
            }
        }

        override fun onCapabilitiesChanged(
            network: Network,
            networkCapabilities: NetworkCapabilities,
        ) {
            publishVpnNetworkState(network, networkCapabilities, "capabilities_changed")
        }

        override fun onLost(network: Network) {
            if (vpnNetwork != network) return
            vpnNetwork = null
            ProxyVpnController.updateNetworkState(
                false,
                "VPN network lost: network=$network",
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> shutdown(null)
            ACTION_START -> {
                // Android may deliver a replacement start before destroying the
                // service instance stopped by the previous application policy.
                shuttingDown = false
                startAsForegroundService()
                establishTunnel(VpnConfiguration(
                    mode = intent.getStringExtra(EXTRA_MODE) ?: "all",
                    packages = intent.getStringArrayListExtra(EXTRA_PACKAGES).orEmpty(),
                    mtu = intent.getIntExtra(EXTRA_MTU, VpnConfiguration.DEFAULT_MTU),
                ))
            }
            else -> stopSelf()
        }
        return Service.START_NOT_STICKY
    }

    override fun onRevoke() {
        shutdown("Android revoked VPN permission")
        super.onRevoke()
    }

    override fun onDestroy() {
        closeInterface()
        unregisterNetworkCallback()
        if (ProxyVpnController.running || ProxyVpnController.startPending) {
            ProxyVpnController.completeStop()
        }
        super.onDestroy()
    }

    private fun establishTunnel(configuration: VpnConfiguration) {
        try {
            closeInterface()
            val builder = Builder()
                .setSession("Proxy Everything")
                .setMtu(configuration.mtu)
                .addAddress(IPV4_ADDRESS, 30)
                .addRoute("0.0.0.0", 0)
                .addDnsServer(VIRTUAL_DNS)
                .addAddress(IPV6_ADDRESS, 126)
                .addRoute("::", 0)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
            }
            builder.setBlocking(false)
            applyApplicationPolicy(builder, configuration)

            val established = builder.establish()
                ?: throw IllegalStateException("Android returned no VPN interface")
            vpnInterface = established
            registerNetworkCallback()
            connectivity.activeNetwork
                ?.takeIf { network ->
                    connectivity.getNetworkCapabilities(network)?.let(::isUsableUnderlying) == true
                }
                ?.let(underlyingCandidates::add)
            selectUnderlyingNetwork("established")
            val diagnostics = networkDiagnostics(configuration)
            ProxyVpnController.completeStart(established.fd, diagnostics)
            publishCurrentVpnNetwork("established")
            Log.i(TAG, "VPN interface established: $diagnostics")
        } catch (error: Exception) {
            val message = error.message ?: "Failed to establish Android VPN interface"
            Log.e(TAG, message, error)
            ProxyVpnController.failStart(message)
            shutdown(message)
        }
    }

    private fun applyApplicationPolicy(builder: Builder, configuration: VpnConfiguration) {
        if (configuration.mode == "include") {
            val allowed = configuration.packages.filterNot { it == packageName }
            require(allowed.isNotEmpty()) {
                "VPN-only mode must include an application other than Proxy Everything"
            }
            allowed.forEach { selected ->
                addAllowedApplication(builder, selected)
            }
            return
        }

        // The local SOCKS listener and its remote sockets live in this package.
        // Keeping this package outside the VPN is the mandatory Android loop barrier.
        addDisallowedApplication(builder, packageName)
        if (configuration.mode == "exclude") {
            configuration.packages.forEach { selected ->
                if (selected != packageName) addDisallowedApplication(builder, selected)
            }
        }
    }

    private fun addAllowedApplication(builder: Builder, selected: String) {
        try {
            builder.addAllowedApplication(selected)
        } catch (_: PackageManager.NameNotFoundException) {
            Log.w(TAG, "Ignoring uninstalled VPN include package: $selected")
        }
    }

    private fun addDisallowedApplication(builder: Builder, selected: String) {
        try {
            builder.addDisallowedApplication(selected)
        } catch (_: PackageManager.NameNotFoundException) {
            Log.w(TAG, "Ignoring uninstalled VPN bypass package: $selected")
        }
    }

    private fun startAsForegroundService() {
        val notificationManager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            notificationManager.createNotificationChannel(
                NotificationChannel(
                    NOTIFICATION_CHANNEL,
                    "VPN connection",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }

        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopIntent = PendingIntent.getService(
            this,
            1,
            stopIntent(this),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notificationBuilder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = notificationBuilder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Proxy Everything VPN")
            .setContentText("Device traffic capture is active")
            .setContentIntent(openIntent)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(
                Notification.Action.Builder(
                    null,
                    "Disconnect",
                    stopIntent,
                ).build(),
            )
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun shutdown(error: String?) {
        if (shuttingDown) {
            // A second Dart stop waiter can arrive while Android is still
            // destroying the same service instance. Never leave it pending.
            ProxyVpnController.completeStop(error)
            return
        }
        shuttingDown = true
        closeInterface()
        ProxyVpnController.completeStop(error)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun closeInterface() {
        try {
            vpnInterface?.close()
        } catch (error: Exception) {
            Log.w(TAG, "Failed to close VPN interface", error)
        } finally {
            vpnInterface = null
        }
    }

    private fun registerNetworkCallback() {
        if (networkCallbackRegistered) return
        connectivity.registerNetworkCallback(
            NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build(),
            networkCallback,
        )
        try {
            connectivity.registerNetworkCallback(
                NetworkRequest.Builder()
                    .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                    .addTransportType(NetworkCapabilities.TRANSPORT_VPN)
                    .build(),
                vpnNetworkCallback,
            )
        } catch (error: RuntimeException) {
            connectivity.unregisterNetworkCallback(networkCallback)
            throw error
        }
        networkCallbackRegistered = true
    }

    private fun unregisterNetworkCallback() {
        if (!networkCallbackRegistered) return
        unregisterNetworkCallback(networkCallback, "default")
        unregisterNetworkCallback(vpnNetworkCallback, "VPN")
        networkCallbackRegistered = false
        underlyingNetwork = null
        vpnNetwork = null
        underlyingCandidates.clear()
    }

    private fun unregisterNetworkCallback(
        callback: ConnectivityManager.NetworkCallback,
        label: String,
    ) {
        try {
            connectivity.unregisterNetworkCallback(callback)
        } catch (error: IllegalArgumentException) {
            Log.w(TAG, "$label network callback was already unregistered", error)
        }
    }

    private fun applyUnderlyingNetwork(network: Network?, reason: String) {
        val capabilities = network?.let(connectivity::getNetworkCapabilities)
        if (network == null || capabilities == null || !isUsableUnderlying(capabilities)) {
            Log.w(
                TAG,
                "Ignoring unusable underlying network: reason=$reason network=$network " +
                    "capabilities=${describeCapabilities(capabilities)}",
            )
            return
        }
        underlyingNetwork = network
        val accepted = setUnderlyingNetworks(arrayOf(network))
        Log.i(
            TAG,
            "Underlying network applied: reason=$reason network=$network accepted=$accepted " +
                "capabilities=${describeCapabilities(capabilities)}",
        )
    }

    private fun selectUnderlyingNetwork(reason: String) {
        val selected = underlyingCandidates
            .asSequence()
            .mapNotNull { network ->
                connectivity.getNetworkCapabilities(network)
                    ?.takeIf(::isUsableUnderlying)
                    ?.let { capabilities -> Triple(network, capabilities, networkRank(capabilities)) }
            }
            .minByOrNull { (_, _, rank) -> rank }

        if (selected == null) {
            if (underlyingNetwork != null) {
                underlyingNetwork = null
                val accepted = setUnderlyingNetworks(null)
                Log.i(TAG, "No usable underlying network: reason=$reason accepted=$accepted")
            }
            return
        }

        val (network, capabilities) = selected
        if (network == underlyingNetwork) return
        applyUnderlyingNetwork(network, reason)
        Log.i(TAG, "Selected underlying network rank=${networkRank(capabilities)}")
    }

    private fun networkRank(capabilities: NetworkCapabilities): Int {
        val transportRank = when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 0
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 1
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 4
            else -> 20
        }
        val validationPenalty = if (
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        ) 0 else 10
        return transportRank + validationPenalty
    }

    private fun isUsableUnderlying(capabilities: NetworkCapabilities): Boolean =
        capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)

    private fun publishCurrentVpnNetwork(reason: String) {
        connectivity.allNetworks
            .asSequence()
            .mapNotNull { network ->
                connectivity.getNetworkCapabilities(network)?.let { network to it }
            }
            .firstOrNull { (_, capabilities) ->
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            }
            ?.let { (network, capabilities) ->
                publishVpnNetworkState(network, capabilities, reason)
            }
    }

    private fun publishVpnNetworkState(
        network: Network,
        capabilities: NetworkCapabilities,
        reason: String,
    ) {
        vpnNetwork = network
        val validated = capabilities.hasCapability(
            NetworkCapabilities.NET_CAPABILITY_VALIDATED,
        )
        val diagnostics =
            "reason=$reason vpn=$network vpnCaps=${describeCapabilities(capabilities)} " +
                "underlying=$underlyingNetwork underlyingCaps=" +
                describeCapabilities(
                    underlyingNetwork?.let(connectivity::getNetworkCapabilities),
                )
        ProxyVpnController.updateNetworkState(validated, diagnostics)
        Log.i(TAG, "VPN network state: $diagnostics")
    }

    private fun networkDiagnostics(configuration: VpnConfiguration): String {
        val underlying = underlyingNetwork
        val underlyingCapabilities = underlying?.let(connectivity::getNetworkCapabilities)
        val vpnCapabilities = connectivity.allNetworks
            .asSequence()
            .mapNotNull { network ->
                connectivity.getNetworkCapabilities(network)?.let { network to it }
            }
            .firstOrNull { (_, capabilities) ->
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            }
        return "mode=${configuration.mode} sdk=${Build.VERSION.SDK_INT} mtu=${configuration.mtu} " +
            "underlying=$underlying underlyingCaps=${describeCapabilities(underlyingCapabilities)} " +
            "vpn=${vpnCapabilities?.first} vpnCaps=${describeCapabilities(vpnCapabilities?.second)}"
    }

    private fun describeCapabilities(capabilities: NetworkCapabilities?): String {
        if (capabilities == null) return "none"
        val transports = buildList {
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) add("WIFI")
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) add("CELLULAR")
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) add("ETHERNET")
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) add("VPN")
        }
        return "transports=${transports.joinToString("+").ifEmpty { "OTHER" }}," +
            "internet=${capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)}," +
            "validated=${capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)}," +
            "metered=${!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)}"
    }

    companion object {
        private const val TAG = "ProxyVpnService"
        private const val ACTION_START = "com.proxyui.proxy_ui.START_VPN"
        private const val ACTION_STOP = "com.proxyui.proxy_ui.STOP_VPN"
        private const val EXTRA_MODE = "mode"
        private const val EXTRA_PACKAGES = "packages"
        private const val EXTRA_MTU = "mtu"
        private const val NOTIFICATION_CHANNEL = "proxy_vpn"
        private const val NOTIFICATION_ID = 4201
        private const val IPV4_ADDRESS = "172.19.0.1"
        private const val IPV6_ADDRESS = "fdfe:dcba:9876::1"
        // Keep the DNS portal outside tun2proxy's 198.18.0.0/15 fake-IP pool.
        // Android probes VPN DNS servers with opportunistic DoT on port 853;
        // overlapping the portal with a fake IP can route that probe to an
        // unrelated hostname and destabilize Android's resolver state.
        private const val VIRTUAL_DNS = "172.19.0.2"

        internal fun startIntent(context: Context, configuration: VpnConfiguration) =
            Intent(context, ProxyVpnService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_MODE, configuration.mode)
                .putStringArrayListExtra(EXTRA_PACKAGES, ArrayList(configuration.packages))
                .putExtra(EXTRA_MTU, configuration.mtu)

        fun stopIntent(context: Context) =
            Intent(context, ProxyVpnService::class.java).setAction(ACTION_STOP)
    }
}
