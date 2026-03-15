package org.tamx.termigate.data.repository

import android.content.Context
import android.util.Base64
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import org.tamx.termigate.data.network.ChannelEvent
import org.tamx.termigate.data.network.ConnectionState
import org.tamx.termigate.data.network.JoinResult
import org.tamx.termigate.data.network.PhoenixChannel
import org.tamx.termigate.data.network.PhoenixSocket
import org.tamx.termigate.service.TerminalForegroundService
import javax.inject.Inject
import javax.inject.Singleton

sealed class TerminalEvent {
    data class Output(val data: ByteArray) : TerminalEvent()
    data class Reconnected(val buffer: ByteArray) : TerminalEvent()
    data class Resized(val cols: Int, val rows: Int) : TerminalEvent()
    data object PaneDead : TerminalEvent()
    data class Superseded(val newTarget: String) : TerminalEvent()
}

data class TerminalConnection(
    val history: ByteArray,
    val cols: Int,
    val rows: Int,
    val events: Flow<TerminalEvent>
)

@Singleton
class TerminalRepository @Inject constructor(
    private val phoenixSocket: PhoenixSocket,
    @ApplicationContext private val context: Context
) {
    companion object {
        private const val TAG = "TerminalRepository"
        private const val MAX_JOIN_RETRIES = 3
        private const val RETRY_DELAY_MS = 1000L
        private const val DISCONNECT_NOTIFY_DELAY_MS = 60_000L
        private const val SOCKET_CONNECT_TIMEOUT_MS = 20_000L
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val activeChannels = mutableMapOf<String, PhoenixChannel>()
    private var disconnectNotifyJob: Job? = null

    init {
        // Watch for prolonged disconnection to notify user
        scope.launch {
            phoenixSocket.connectionState.collect { state ->
                when (state) {
                    ConnectionState.Connected -> {
                        disconnectNotifyJob?.cancel()
                        disconnectNotifyJob = null
                    }
                    ConnectionState.Reconnecting -> {
                        if (activeChannels.isNotEmpty() && disconnectNotifyJob == null) {
                            disconnectNotifyJob = scope.launch {
                                delay(DISCONNECT_NOTIFY_DELAY_MS)
                                TerminalForegroundService.notifyDisconnected(context)
                            }
                        }
                    }
                    ConnectionState.Disconnected -> { /* no-op */ }
                }
            }
        }
    }

    /** Convert target "session:window.pane" to channel topic "terminal:session:window:pane" */
    private fun targetToTopic(target: String): String {
        val colonIdx = target.indexOf(':')
        if (colonIdx == -1) return "terminal:$target:0:0"
        val session = target.substring(0, colonIdx)
        val rest = target.substring(colonIdx + 1)
        val dotIdx = rest.indexOf('.')
        if (dotIdx == -1) return "terminal:$session:$rest:0"
        val window = rest.substring(0, dotIdx)
        val pane = rest.substring(dotIdx + 1)
        return "terminal:$session:$window:$pane"
    }

    suspend fun connect(target: String, cols: Int, rows: Int): Result<TerminalConnection> {
        // Ensure socket is connected before attempting to join
        if (phoenixSocket.connectionState.value != ConnectionState.Connected) {
            phoenixSocket.connect()
            val connected = withTimeoutOrNull(SOCKET_CONNECT_TIMEOUT_MS) {
                phoenixSocket.connectionState.first { it == ConnectionState.Connected }
            }
            if (connected == null) {
                return Result.failure(Exception("Could not connect to server"))
            }
        }

        val topic = targetToTopic(target)

        var lastError: String? = null
        for (attempt in 0 until MAX_JOIN_RETRIES) {
            val channel = phoenixSocket.channel(topic)
            val joinPayload = mapOf<String, Any>("cols" to cols, "rows" to rows)
            val result = channel.join(joinPayload)

            when (result) {
                is JoinResult.Ok -> {
                    activeChannels[target] = channel
                    updateServiceState(target)

                    val historyB64 = result.payload["history"] as? String ?: ""
                    val history = if (historyB64.isNotEmpty()) {
                        Base64.decode(historyB64, Base64.DEFAULT)
                    } else {
                        ByteArray(0)
                    }

                    val events = channel.events.mapNotNull { event ->
                        when (event) {
                            is ChannelEvent.Message -> parseTerminalEvent(event, target)
                        }
                    }

                    return Result.success(
                        TerminalConnection(
                            history = history,
                            cols = cols,
                            rows = rows,
                            events = events
                        )
                    )
                }
                is JoinResult.Error -> {
                    lastError = result.reason
                    if (result.reason == "pane_not_ready" && attempt < MAX_JOIN_RETRIES - 1) {
                        Log.d(TAG, "Pane not ready, retrying in ${RETRY_DELAY_MS}ms...")
                        phoenixSocket.removeChannel(topic)
                        delay(RETRY_DELAY_MS)
                        continue
                    }
                    phoenixSocket.removeChannel(topic)
                    return Result.failure(Exception("Failed to join terminal: ${result.reason}"))
                }
            }
        }
        return Result.failure(Exception("Failed to join terminal: $lastError"))
    }

    suspend fun disconnect(target: String) {
        val channel = activeChannels.remove(target)
        channel?.leave()
        updateServiceState(null)
    }

    suspend fun sendInput(target: String, data: ByteArray) {
        val channel = activeChannels[target] ?: return
        val dataStr = String(data, Charsets.ISO_8859_1)
        channel.push("input", mapOf("data" to dataStr))
    }

    suspend fun sendResize(target: String, cols: Int, rows: Int) {
        val channel = activeChannels[target] ?: return
        channel.push("resize", mapOf("cols" to cols, "rows" to rows))
    }

    private fun updateServiceState(newTarget: String?) {
        val count = activeChannels.size
        if (count == 0) {
            TerminalForegroundService.stop(context)
        } else if (count == 1 && newTarget != null) {
            TerminalForegroundService.start(context, "Connected to $newTarget")
        } else {
            TerminalForegroundService.updateCount(context, count)
        }
    }

    private fun parseTerminalEvent(event: ChannelEvent.Message, target: String): TerminalEvent? {
        return when (event.event) {
            "output" -> {
                val b64 = event.payload["data"] as? String ?: return null
                val decoded = Base64.decode(b64, Base64.DEFAULT)
                TerminalEvent.Output(decoded)
            }
            "pane_dead" -> {
                TerminalForegroundService.notifyPaneDead(context, target)
                TerminalEvent.PaneDead
            }
            "reconnected" -> {
                val b64 = event.payload["data"] as? String ?: return null
                val decoded = Base64.decode(b64, Base64.DEFAULT)
                TerminalEvent.Reconnected(decoded)
            }
            "resized" -> {
                val cols = (event.payload["cols"] as? Number)?.toInt() ?: return null
                val rows = (event.payload["rows"] as? Number)?.toInt() ?: return null
                TerminalEvent.Resized(cols, rows)
            }
            "superseded" -> {
                val newTarget = event.payload["target"] as? String ?: return null
                TerminalEvent.Superseded(newTarget)
            }
            else -> null
        }
    }
}
