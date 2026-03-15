package org.tamx.termigate.data.network

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

enum class ConnectionState {
    Connected, Disconnected, Reconnecting
}

class PhoenixSocket(
    private var baseUrl: String,
    private var params: Map<String, String>,
    private val client: OkHttpClient
) {
    companion object {
        private const val TAG = "PhoenixSocket"
        private const val HEARTBEAT_INTERVAL_MS = 30_000L
        private const val HEARTBEAT_TIMEOUT_MS = 10_000L
        private const val MAX_RECONNECT_DELAY_MS = 30_000L
    }

    private val _connectionState = MutableStateFlow(ConnectionState.Disconnected)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var webSocket: WebSocket? = null
    private val ref = AtomicLong(0)
    private var heartbeatJob: Job? = null
    private var heartbeatRef: String? = null
    private var reconnectAttempt = 0
    private var shouldReconnect = false

    private val channels = ConcurrentHashMap<String, PhoenixChannel>()

    // Internal flow for dispatching incoming messages to channels
    internal val incomingMessages = MutableSharedFlow<PhoenixMessage>(extraBufferCapacity = 256)

    fun updateParams(params: Map<String, String>) {
        this.params = params
    }

    fun updateBaseUrl(url: String) {
        this.baseUrl = url
    }

    fun connect() {
        shouldReconnect = true
        doConnect()
    }

    fun disconnect() {
        shouldReconnect = false
        heartbeatJob?.cancel()
        heartbeatJob = null
        webSocket?.close(1000, "Client disconnect")
        webSocket = null
        _connectionState.value = ConnectionState.Disconnected
    }

    fun channel(topic: String): PhoenixChannel {
        return channels.getOrPut(topic) { PhoenixChannel(this, topic) }
    }

    internal fun removeChannel(topic: String) {
        channels.remove(topic)
    }

    internal fun nextRef(): String = ref.incrementAndGet().toString()

    internal fun send(message: PhoenixMessage): Boolean {
        val ws = webSocket ?: return false
        val json = JSONArray().apply {
            put(message.joinRef ?: JSONObject.NULL)
            put(message.ref ?: JSONObject.NULL)
            put(message.topic)
            put(message.event)
            put(message.payload)
        }
        return ws.send(json.toString())
    }

    private fun doConnect() {
        val wsUrl = buildWsUrl()
        Log.d(TAG, "Connecting to $wsUrl")

        val request = Request.Builder().url(wsUrl).build()
        webSocket = client.newWebSocket(request, SocketListener())
    }

    private fun buildWsUrl(): String {
        val base = baseUrl.trimEnd('/')
        val scheme = when {
            base.startsWith("https://") -> "wss://" + base.removePrefix("https://")
            base.startsWith("http://") -> "ws://" + base.removePrefix("http://")
            else -> "ws://$base"
        }
        val queryParams = (params + ("vsn" to "2.0.0"))
            .entries.joinToString("&") { "${it.key}=${it.value}" }
        return "$scheme/socket/websocket?$queryParams"
    }

    private fun startHeartbeat() {
        heartbeatJob?.cancel()
        heartbeatJob = scope.launch {
            while (true) {
                delay(HEARTBEAT_INTERVAL_MS)
                val hbRef = nextRef()
                heartbeatRef = hbRef
                val sent = send(
                    PhoenixMessage(
                        joinRef = null,
                        ref = hbRef,
                        topic = "phoenix",
                        event = "heartbeat",
                        payload = JSONObject()
                    )
                )
                if (!sent) {
                    Log.w(TAG, "Failed to send heartbeat")
                    reconnect()
                    return@launch
                }

                delay(HEARTBEAT_TIMEOUT_MS)
                // If heartbeatRef hasn't been cleared by a reply, we timed out
                if (heartbeatRef != null) {
                    Log.w(TAG, "Heartbeat timeout")
                    reconnect()
                    return@launch
                }
            }
        }
    }

    private fun reconnect() {
        if (!shouldReconnect) return
        webSocket?.close(1000, "Reconnecting")
        webSocket = null
        _connectionState.value = ConnectionState.Reconnecting

        scope.launch {
            val delayMs = minOf(
                (1000L * (1L shl minOf(reconnectAttempt, 5))),
                MAX_RECONNECT_DELAY_MS
            )
            Log.d(TAG, "Reconnecting in ${delayMs}ms (attempt $reconnectAttempt)")
            delay(delayMs)
            reconnectAttempt++
            if (shouldReconnect) doConnect()
        }
    }

    private fun rejoinChannels() {
        for (channel in channels.values) {
            channel.rejoinIfNeeded()
        }
    }

    private inner class SocketListener : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            Log.d(TAG, "WebSocket connected")
            reconnectAttempt = 0
            _connectionState.value = ConnectionState.Connected
            startHeartbeat()
            rejoinChannels()
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            try {
                val json = JSONArray(text)
                val message = PhoenixMessage(
                    joinRef = json.optString(0).ifEmpty { null },
                    ref = json.optString(1).ifEmpty { null },
                    topic = json.getString(2),
                    event = json.getString(3),
                    payload = json.getJSONObject(4)
                )

                // Handle heartbeat reply
                if (message.topic == "phoenix" && message.event == "phx_reply") {
                    if (message.ref == heartbeatRef) {
                        heartbeatRef = null
                    }
                    return
                }

                scope.launch {
                    incomingMessages.emit(message)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to parse message: $text", e)
            }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            Log.e(TAG, "WebSocket failure", t)
            heartbeatJob?.cancel()
            reconnect()
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            Log.d(TAG, "WebSocket closed: $code $reason")
            heartbeatJob?.cancel()
            if (shouldReconnect) {
                reconnect()
            } else {
                _connectionState.value = ConnectionState.Disconnected
            }
        }
    }
}

data class PhoenixMessage(
    val joinRef: String?,
    val ref: String?,
    val topic: String,
    val event: String,
    val payload: JSONObject
)
