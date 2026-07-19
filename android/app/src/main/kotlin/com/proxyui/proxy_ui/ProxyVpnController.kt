package com.proxyui.proxy_ui

internal object ProxyVpnController {
    @Volatile
    var running: Boolean = false
        private set

    @Volatile
    var startPending: Boolean = false
        private set

    @Volatile
    var stateListener: ((Boolean, String?) -> Unit)? = null

    private var startSuccess: ((Int) -> Unit)? = null
    private var startError: ((String) -> Unit)? = null
    private var stopComplete: ((String?) -> Unit)? = null

    @Synchronized
    fun beginStart(onSuccess: (Int) -> Unit, onError: (String) -> Unit): Boolean {
        if (startPending || running || stopComplete != null) return false
        startPending = true
        startSuccess = onSuccess
        startError = onError
        return true
    }

    fun completeStart(fd: Int) {
        val callback: ((Int) -> Unit)?
        synchronized(this) {
            startPending = false
            running = true
            callback = startSuccess
            startSuccess = null
            startError = null
        }
        callback?.invoke(fd)
        stateListener?.invoke(true, null)
    }

    fun failStart(error: String) {
        val callback: ((String) -> Unit)?
        synchronized(this) {
            startPending = false
            running = false
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
            startSuccess = null
            startError = null
            callback = stopComplete
            stopComplete = null
        }
        callback?.invoke(error)
        stateListener?.invoke(false, error)
    }
}
