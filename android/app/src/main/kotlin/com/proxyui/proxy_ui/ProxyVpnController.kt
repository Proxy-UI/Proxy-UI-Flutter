package com.proxyui.proxy_ui

internal object ProxyVpnController {
    @Volatile
    var running: Boolean = false
        private set

    @Volatile
    var startPending: Boolean = false
        private set

    @Volatile
    var networkValidated: Boolean = false
        private set

    @Volatile
    var networkDiagnostics: String = "VPN network is not established"
        private set

    @Volatile
    var stateListener: ((Boolean, String?) -> Unit)? = null

    private var startSuccess: ((Int, String) -> Unit)? = null
    private var startError: ((String) -> Unit)? = null
    private var stopComplete: ((String?) -> Unit)? = null

    @Synchronized
    fun beginStart(onSuccess: (Int, String) -> Unit, onError: (String) -> Unit): Boolean {
        if (startPending || running || stopComplete != null) return false
        startPending = true
        startSuccess = onSuccess
        startError = onError
        return true
    }

    fun completeStart(fd: Int, diagnostics: String) {
        val callback: ((Int, String) -> Unit)?
        synchronized(this) {
            startPending = false
            running = true
            networkValidated = false
            networkDiagnostics = diagnostics
            callback = startSuccess
            startSuccess = null
            startError = null
        }
        callback?.invoke(fd, diagnostics)
        stateListener?.invoke(true, null)
    }

    fun failStart(error: String) {
        val callback: ((String) -> Unit)?
        synchronized(this) {
            startPending = false
            running = false
            networkValidated = false
            networkDiagnostics = error
            callback = startError
            startSuccess = null
            startError = null
        }
        callback?.invoke(error)
        stateListener?.invoke(false, error)
    }

    @Synchronized
    fun beginStop(onComplete: (String?) -> Unit): Boolean {
        if (stopComplete != null) return false
        stopComplete = onComplete
        return true
    }

    fun completeStop(error: String? = null) {
        val callback: ((String?) -> Unit)?
        synchronized(this) {
            running = false
            startPending = false
            networkValidated = false
            networkDiagnostics = error ?: "VPN network is stopped"
            startSuccess = null
            startError = null
            callback = stopComplete
            stopComplete = null
        }
        callback?.invoke(error)
        stateListener?.invoke(false, error)
    }

    @Synchronized
    fun updateNetworkState(validated: Boolean, diagnostics: String) {
        networkValidated = validated
        networkDiagnostics = diagnostics
    }
}
