package org.tamx.termigate.data.repository

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import org.tamx.termigate.data.model.Session
import org.tamx.termigate.data.model.SessionsResponse
import org.tamx.termigate.data.network.ApiClient
import org.tamx.termigate.data.network.ChannelEvent
import org.tamx.termigate.data.network.ConnectionState
import org.tamx.termigate.data.network.JoinResult
import org.tamx.termigate.data.network.PhoenixChannel
import org.tamx.termigate.data.network.PhoenixSocket
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class SessionRepository @Inject constructor(
    private val apiClient: ApiClient,
    private val phoenixSocket: PhoenixSocket,
    private val prefs: AppPreferences
) {
    companion object {
        private const val TAG = "SessionRepository"
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val json = Json { ignoreUnknownKeys = true }

    private val _sessions = MutableStateFlow<List<Session>>(emptyList())
    val sessions: StateFlow<List<Session>> = _sessions.asStateFlow()

    private val _tmuxStatus = MutableStateFlow<String?>(null)
    val tmuxStatus: StateFlow<String?> = _tmuxStatus.asStateFlow()

    private var sessionChannel: PhoenixChannel? = null

    suspend fun connectSessionChannel() {
        // Update socket URL/token with the current values from prefs.
        phoenixSocket.updateBaseUrl(prefs.serverUrl ?: "")
        phoenixSocket.updateTokenProvider { prefs.authToken }

        if (phoenixSocket.connectionState.value != ConnectionState.Connected) {
            phoenixSocket.connect()
        }

        val channel = phoenixSocket.channel("sessions")
        sessionChannel = channel

        // Collect channel events
        scope.launch {
            channel.events.collect { event ->
                when (event) {
                    is ChannelEvent.Message -> handleChannelEvent(event.event, event.payload)
                }
            }
        }

        // Join and parse initial session list
        val result = channel.join()
        when (result) {
            is JoinResult.Ok -> {
                parseSessionsFromPayload(result.payload)
            }
            is JoinResult.Error -> {
                Log.e(TAG, "Failed to join sessions channel: ${result.reason}")
            }
        }
    }

    fun disconnectSessionChannel() {
        scope.launch {
            sessionChannel?.leave()
            sessionChannel = null
        }
    }

    suspend fun createSession(name: String, command: String? = null): Result<Unit> {
        return apiClient.createSession(name, command)
    }

    suspend fun deleteSession(name: String): Result<Unit> {
        return apiClient.deleteSession(name)
    }

    suspend fun renameSession(name: String, newName: String): Result<Unit> {
        return apiClient.renameSession(name, newName)
    }

    suspend fun createWindow(sessionName: String): Result<Unit> {
        return apiClient.createWindow(sessionName)
    }

    suspend fun splitPane(target: String, direction: String): Result<Unit> {
        return apiClient.splitPane(target, direction)
    }

    suspend fun deletePane(target: String): Result<Unit> {
        return apiClient.deletePane(target)
    }

    suspend fun refreshSessions(): Result<Unit> {
        return apiClient.listSessions().map { sessions ->
            _sessions.value = sessions
        }
    }

    private fun handleChannelEvent(event: String, payload: Map<String, Any?>) {
        when (event) {
            "sessions_updated" -> parseSessionsFromPayload(payload)
            "tmux_status" -> {
                val status = payload["status"] as? String
                _tmuxStatus.value = if (status == "ok") null else status
            }
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun parseSessionsFromPayload(payload: Map<String, Any?>) {
        try {
            val sessionsList = payload["sessions"] as? List<Map<String, Any?>> ?: return
            val parsed = sessionsList.map { sessionMap ->
                val panesList = (sessionMap["panes"] as? List<Map<String, Any?>>)?.map { paneMap ->
                    org.tamx.termigate.data.model.Pane(
                        sessionName = paneMap["session_name"] as? String ?: "",
                        windowIndex = (paneMap["window_index"] as? Number)?.toInt() ?: 0,
                        index = (paneMap["index"] as? Number)?.toInt() ?: 0,
                        width = (paneMap["width"] as? Number)?.toInt() ?: 80,
                        height = (paneMap["height"] as? Number)?.toInt() ?: 24,
                        command = paneMap["command"] as? String ?: "",
                        paneId = paneMap["pane_id"] as? String ?: ""
                    )
                } ?: emptyList()

                Session(
                    name = sessionMap["name"] as? String ?: "",
                    windows = (sessionMap["windows"] as? Number)?.toInt() ?: 0,
                    attached = sessionMap["attached"] as? Boolean ?: false,
                    created = (sessionMap["created"] as? Number)?.toLong(),
                    panes = panesList
                )
            }
            _sessions.value = parsed
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse sessions", e)
        }
    }
}
