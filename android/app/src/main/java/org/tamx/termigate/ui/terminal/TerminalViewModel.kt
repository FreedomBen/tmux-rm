package org.tamx.termigate.ui.terminal

import android.util.Log
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import org.tamx.termigate.data.model.QuickAction
import org.tamx.termigate.data.network.ApiClient
import org.tamx.termigate.data.repository.TerminalEvent
import org.tamx.termigate.data.repository.TerminalRepository
import javax.inject.Inject

@HiltViewModel
class TerminalViewModel @Inject constructor(
    private val terminalRepo: TerminalRepository,
    private val apiClient: ApiClient,
    savedStateHandle: SavedStateHandle
) : ViewModel() {

    companion object {
        private const val TAG = "TerminalViewModel"
        private const val RESIZE_DEBOUNCE_MS = 150L
    }

    val target: String = savedStateHandle["target"]!!

    var remoteSession: RemoteTerminalSession? = null
        private set

    data class UiState(
        val isConnected: Boolean = false,
        val isLoading: Boolean = true,
        val error: String? = null,
        val paneDead: Boolean = false,
        val supersededTarget: String? = null,
        val title: String = "",
        val quickActions: List<QuickAction> = emptyList()
    )

    private val _uiState = MutableStateFlow(UiState(title = target))
    val uiState: StateFlow<UiState> = _uiState.asStateFlow()

    private var eventCollectionJob: Job? = null
    private var resizeDebounceJob: Job? = null
    private var serverResizeInProgress = false

    private val sessionClient = object : TerminalSessionClient {
        override fun onTextChanged(changedSession: TerminalSession) {}
        override fun onTitleChanged(changedSession: TerminalSession) {}
        override fun onSessionFinished(finishedSession: TerminalSession) {}
        override fun onCopyTextToClipboard(session: TerminalSession, text: String?) {}
        override fun onPasteTextFromClipboard(session: TerminalSession?) {}
        override fun onBell(session: TerminalSession) {}
        override fun onColorsChanged(session: TerminalSession) {}
        override fun onTerminalCursorStateChange(state: Boolean) {}
        override fun setTerminalShellPid(session: TerminalSession, pid: Int) {}
        override fun getTerminalCursorStyle(): Int = 0
        override fun logError(tag: String?, message: String?) {
            Log.e(tag ?: TAG, message ?: "")
        }
        override fun logWarn(tag: String?, message: String?) {
            Log.w(tag ?: TAG, message ?: "")
        }
        override fun logInfo(tag: String?, message: String?) {
            Log.i(tag ?: TAG, message ?: "")
        }
        override fun logDebug(tag: String?, message: String?) {
            Log.d(tag ?: TAG, message ?: "")
        }
        override fun logVerbose(tag: String?, message: String?) {
            Log.v(tag ?: TAG, message ?: "")
        }
        override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) {
            Log.e(tag ?: TAG, message, e)
        }
        override fun logStackTrace(tag: String?, e: Exception?) {
            Log.e(tag ?: TAG, "Stack trace", e)
        }
    }

    fun connect(cols: Int, rows: Int) {
        if (_uiState.value.isConnected) return
        _uiState.update { it.copy(isLoading = true, error = null) }

        viewModelScope.launch {
            terminalRepo.connect(target, cols, rows)
                .onSuccess { connection ->
                    // Create remote session that forwards keyboard input to server
                    val session = RemoteTerminalSession(sessionClient) { data ->
                        viewModelScope.launch {
                            terminalRepo.sendInput(target, data)
                        }
                    }
                    remoteSession = session

                    // Feed history into emulator (emulator gets created by TerminalView.attachSession → updateSize)
                    // We'll feed it after the view attaches and initializes the emulator
                    val history = connection.history

                    _uiState.update {
                        it.copy(isConnected = true, isLoading = false)
                    }

                    loadQuickActions()

                    // Feed history once emulator is available
                    // This is called from the UI after attachSession triggers updateSize
                    if (history.isNotEmpty()) {
                        session.pendingHistory = history
                    }

                    // Collect terminal events
                    eventCollectionJob?.cancel()
                    eventCollectionJob = viewModelScope.launch {
                        connection.events.collect { event ->
                            handleTerminalEvent(event)
                        }
                    }
                }
                .onFailure { e ->
                    Log.e(TAG, "Failed to connect", e)
                    _uiState.update {
                        it.copy(isLoading = false, error = e.message ?: "Connection failed")
                    }
                }
        }
    }

    fun disconnect() {
        eventCollectionJob?.cancel()
        viewModelScope.launch {
            terminalRepo.disconnect(target)
        }
        _uiState.update { it.copy(isConnected = false) }
    }

    fun sendInput(data: ByteArray) {
        viewModelScope.launch {
            terminalRepo.sendInput(target, data)
        }
    }

    fun onQuickAction(action: QuickAction) {
        val command = action.command + "\n"
        sendInput(command.toByteArray(Charsets.UTF_8))
    }

    private fun loadQuickActions() {
        viewModelScope.launch {
            apiClient.getQuickActions()
                .onSuccess { actions ->
                    _uiState.update { it.copy(quickActions = actions) }
                }
        }
    }

    fun sendResize(cols: Int, rows: Int) {
        if (serverResizeInProgress) {
            serverResizeInProgress = false
            return
        }
        // Debounce to avoid flooding the server during animated transitions
        // (keyboard slide, rotation animation)
        resizeDebounceJob?.cancel()
        resizeDebounceJob = viewModelScope.launch {
            delay(RESIZE_DEBOUNCE_MS)
            terminalRepo.sendResize(target, cols, rows)
        }
    }

    private fun handleTerminalEvent(event: TerminalEvent) {
        when (event) {
            is TerminalEvent.Output -> {
                remoteSession?.feedInput(event.data)
            }
            is TerminalEvent.Reconnected -> {
                remoteSession?.resetAndFeedInput(event.buffer)
            }
            is TerminalEvent.Resized -> {
                serverResizeInProgress = true
                remoteSession?.resizeEmulator(event.cols, event.rows)
            }
            is TerminalEvent.PaneDead -> {
                _uiState.update { it.copy(paneDead = true) }
            }
            is TerminalEvent.Superseded -> {
                _uiState.update { it.copy(supersededTarget = event.newTarget) }
            }
        }
    }

    override fun onCleared() {
        super.onCleared()
        disconnect()
    }
}
