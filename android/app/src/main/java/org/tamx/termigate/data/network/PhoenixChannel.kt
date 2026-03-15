package org.tamx.termigate.data.network

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume

sealed class ChannelEvent {
    data class Message(val event: String, val payload: Map<String, Any?>) : ChannelEvent()
}

sealed class JoinResult {
    data class Ok(val payload: Map<String, Any?>) : JoinResult()
    data class Error(val reason: String) : JoinResult()
}

sealed class PushResult {
    data class Ok(val payload: Map<String, Any?>) : PushResult()
    data class Error(val reason: String) : PushResult()
    data object Timeout : PushResult()
}

enum class ChannelState {
    Closed, Joining, Joined, Leaving, Errored
}

class PhoenixChannel(
    private val socket: PhoenixSocket,
    val topic: String
) {
    companion object {
        private const val TAG = "PhoenixChannel"
        private const val PUSH_TIMEOUT_MS = 10_000L
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val _events = MutableSharedFlow<ChannelEvent>(extraBufferCapacity = 256)
    val events: SharedFlow<ChannelEvent> = _events.asSharedFlow()

    private var state = ChannelState.Closed
    private var joinRef: String? = null
    private var joinPayload: Map<String, Any> = emptyMap()
    private val pendingReplies = ConcurrentHashMap<String, (PhoenixMessage) -> Unit>()

    init {
        scope.launch {
            socket.incomingMessages.collect { message ->
                if (message.topic == topic) {
                    handleMessage(message)
                }
            }
        }
    }

    suspend fun join(payload: Map<String, Any> = emptyMap()): JoinResult {
        joinPayload = payload
        state = ChannelState.Joining
        val ref = socket.nextRef()
        joinRef = ref

        val jsonPayload = JSONObject(payload)
        val message = PhoenixMessage(
            joinRef = ref,
            ref = ref,
            topic = topic,
            event = "phx_join",
            payload = jsonPayload
        )

        return suspendCancellableCoroutine { cont ->
            pendingReplies[ref] = { reply ->
                val status = reply.payload.optString("status")
                val response = reply.payload.optJSONObject("response")
                val responseMap = response?.toMap() ?: emptyMap()

                if (status == "ok") {
                    state = ChannelState.Joined
                    cont.resume(JoinResult.Ok(responseMap))
                } else {
                    state = ChannelState.Errored
                    val reason = response?.optString("reason") ?: status
                    cont.resume(JoinResult.Error(reason))
                }
            }

            cont.invokeOnCancellation { pendingReplies.remove(ref) }

            if (!socket.send(message)) {
                pendingReplies.remove(ref)
                state = ChannelState.Errored
                cont.resume(JoinResult.Error("Failed to send join"))
            }
        }
    }

    suspend fun leave() {
        if (state != ChannelState.Joined) return
        state = ChannelState.Leaving
        val ref = socket.nextRef()

        val message = PhoenixMessage(
            joinRef = joinRef,
            ref = ref,
            topic = topic,
            event = "phx_leave",
            payload = JSONObject()
        )
        socket.send(message)
        state = ChannelState.Closed
        socket.removeChannel(topic)
    }

    suspend fun push(event: String, payload: Map<String, Any> = emptyMap()): PushResult {
        if (state != ChannelState.Joined) {
            return PushResult.Error("Channel not joined")
        }

        val ref = socket.nextRef()
        val jsonPayload = JSONObject(payload)
        val message = PhoenixMessage(
            joinRef = joinRef,
            ref = ref,
            topic = topic,
            event = event,
            payload = jsonPayload
        )

        val result = withTimeoutOrNull(PUSH_TIMEOUT_MS) {
            suspendCancellableCoroutine { cont ->
                pendingReplies[ref] = { reply ->
                    val status = reply.payload.optString("status")
                    val response = reply.payload.optJSONObject("response")
                    val responseMap = response?.toMap() ?: emptyMap()

                    if (status == "ok") {
                        cont.resume(PushResult.Ok(responseMap))
                    } else {
                        val reason = response?.optString("reason") ?: status
                        cont.resume(PushResult.Error(reason))
                    }
                }

                cont.invokeOnCancellation { pendingReplies.remove(ref) }

                if (!socket.send(message)) {
                    pendingReplies.remove(ref)
                    cont.resume(PushResult.Error("Failed to send"))
                }
            }
        }

        if (result == null) {
            pendingReplies.remove(ref)
            return PushResult.Timeout
        }
        return result
    }

    internal fun rejoinIfNeeded() {
        if (state == ChannelState.Joined || state == ChannelState.Joining) {
            state = ChannelState.Closed
            scope.launch {
                join(joinPayload)
            }
        }
    }

    private fun handleMessage(message: PhoenixMessage) {
        when (message.event) {
            "phx_reply" -> {
                val ref = message.ref
                if (ref != null) {
                    pendingReplies.remove(ref)?.invoke(message)
                }
            }
            "phx_error" -> {
                Log.e(TAG, "Channel error on $topic")
                state = ChannelState.Errored
            }
            "phx_close" -> {
                state = ChannelState.Closed
            }
            else -> {
                val payload = message.payload.toMap()
                scope.launch {
                    _events.emit(ChannelEvent.Message(message.event, payload))
                }
            }
        }
    }
}

internal fun JSONObject.toMap(): Map<String, Any?> {
    val map = mutableMapOf<String, Any?>()
    val keys = this.keys()
    while (keys.hasNext()) {
        val key = keys.next()
        val value = this.get(key)
        map[key] = when (value) {
            is JSONObject -> value.toMap()
            is org.json.JSONArray -> value.toList()
            JSONObject.NULL -> null
            else -> value
        }
    }
    return map
}

internal fun org.json.JSONArray.toList(): List<Any?> {
    val list = mutableListOf<Any?>()
    for (i in 0 until this.length()) {
        val value = this.get(i)
        list.add(
            when (value) {
                is JSONObject -> value.toMap()
                is org.json.JSONArray -> value.toList()
                JSONObject.NULL -> null
                else -> value
            }
        )
    }
    return list
}
