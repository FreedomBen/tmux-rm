package org.tamx.termigate.ui.terminal

import android.graphics.Typeface
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.inputmethod.InputMethodManager
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.termux.terminal.TerminalSession
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient
import kotlinx.coroutines.delay

private const val AUTO_HIDE_DELAY_MS = 3000L
private const val DEFAULT_FONT_SIZE = 14

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TerminalScreen(
    onBack: () -> Unit,
    onNavigateToTarget: (String) -> Unit,
    viewModel: TerminalViewModel = hiltViewModel()
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    var showTopBar by remember { mutableStateOf(true) }
    var terminalView by remember { mutableStateOf<TerminalView?>(null) }
    var isKeyboardVisible by remember { mutableStateOf(false) }

    // Detect soft keyboard visibility
    val view = LocalView.current
    DisposableEffect(view) {
        val listener = ViewCompat.setOnApplyWindowInsetsListener(view) { _, insets ->
            isKeyboardVisible = insets.isVisible(WindowInsetsCompat.Type.ime())
            insets
        }
        onDispose {
            ViewCompat.setOnApplyWindowInsetsListener(view, null)
        }
    }

    // Auto-hide top bar
    LaunchedEffect(showTopBar) {
        if (showTopBar) {
            delay(AUTO_HIDE_DELAY_MS)
            showTopBar = false
        }
    }

    // Trigger connect when screen is first composed
    LaunchedEffect(Unit) {
        if (!viewModel.uiState.value.isConnected) {
            viewModel.connect(cols = 80, rows = 24)
        }
    }

    // Handle superseded target
    LaunchedEffect(state.supersededTarget) {
        state.supersededTarget?.let { onNavigateToTarget(it) }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .imePadding()
        ) {
            // Quick action bar (below top bar area, above terminal)
            if (state.isConnected && state.quickActions.isNotEmpty()) {
                QuickActionBar(
                    quickActions = state.quickActions,
                    onActionExecute = viewModel::onQuickAction
                )
            }

            // Terminal view
            if (state.isConnected && viewModel.remoteSession != null) {
                TerminalViewComposable(
                    viewModel = viewModel,
                    onTerminalViewCreated = { tv -> terminalView = tv },
                    onTopBarToggle = { showTopBar = !showTopBar },
                    modifier = Modifier.weight(1f)
                )
            } else {
                // Spacer when terminal not connected
                Box(modifier = Modifier.weight(1f))
            }

            // Special key toolbar (visible when keyboard is open)
            AnimatedVisibility(
                visible = isKeyboardVisible,
                enter = slideInVertically { it },
                exit = slideOutVertically { it }
            ) {
                SpecialKeyToolbar(
                    onSendInput = viewModel::sendInput
                )
            }
        }

        // Loading overlay
        if (state.isLoading) {
            Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center
            ) {
                CircularProgressIndicator(color = MaterialTheme.colorScheme.primary)
            }
        }

        // Error overlay
        state.error?.let { error ->
            Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = error,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.padding(32.dp)
                )
            }
        }

        // Auto-hide top bar
        AnimatedVisibility(
            visible = showTopBar,
            enter = slideInVertically { -it },
            exit = slideOutVertically { -it }
        ) {
            Surface(
                modifier = Modifier
                    .fillMaxWidth()
                    .statusBarsPadding(),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.9f)
            ) {
                TopAppBar(
                    title = {
                        Text(
                            text = viewModel.target,
                            fontFamily = FontFamily.Monospace,
                            style = MaterialTheme.typography.titleSmall
                        )
                    },
                    navigationIcon = {
                        IconButton(onClick = onBack) {
                            Icon(
                                Icons.AutoMirrored.Filled.ArrowBack,
                                contentDescription = "Back"
                            )
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = Color.Transparent
                    )
                )
            }
        }

        // Pane dead overlay
        if (state.paneDead) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.7f))
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = onBack
                    ),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = "Pane closed",
                    color = Color.White,
                    style = MaterialTheme.typography.headlineSmall
                )
            }
        }
    }
}

@Composable
private fun TerminalViewComposable(
    viewModel: TerminalViewModel,
    onTerminalViewCreated: (TerminalView) -> Unit,
    onTopBarToggle: () -> Unit,
    modifier: Modifier = Modifier
) {
    AndroidView(
        factory = { ctx ->
            TerminalView(ctx, null).apply {
                val termView = this
                isFocusable = true
                isFocusableInTouchMode = true
                setTextSize(DEFAULT_FONT_SIZE)
                setTypeface(Typeface.MONOSPACE)
                setTerminalViewClient(createViewClient(viewModel, onTopBarToggle, showKeyboard = {
                    termView.requestFocus()
                    val imm = ctx.getSystemService(InputMethodManager::class.java)
                    imm.showSoftInput(termView, InputMethodManager.SHOW_IMPLICIT)
                }))

                val session = viewModel.remoteSession ?: return@apply
                attachSession(session)

                // After attachSession -> updateSize -> initializeEmulator, feed pending history
                session.pendingHistory?.let { history ->
                    session.feedInput(history)
                    session.pendingHistory = null
                    invalidate()
                }

                requestFocus()
                onTerminalViewCreated(this)
            }
        },
        update = { view ->
            val session = viewModel.remoteSession
            if (session != null && view.currentSession !== session) {
                view.attachSession(session)
                session.pendingHistory?.let { history ->
                    session.feedInput(history)
                    session.pendingHistory = null
                }
                view.invalidate()
            }
        },
        modifier = modifier
    )
}

private fun createViewClient(
    viewModel: TerminalViewModel,
    onTopBarToggle: () -> Unit,
    showKeyboard: () -> Unit
): TerminalViewClient {
    return object : TerminalViewClient {
        override fun onScale(scale: Float): Float = scale

        override fun onSingleTapUp(e: MotionEvent?) {
            onTopBarToggle()
            showKeyboard()
        }

        override fun shouldBackButtonBeMappedToEscape(): Boolean = false
        override fun shouldEnforceCharBasedInput(): Boolean = true
        override fun shouldUseCtrlSpaceWorkaround(): Boolean = false
        override fun isTerminalViewSelected(): Boolean = true

        override fun copyModeChanged(copyMode: Boolean) {}

        override fun onKeyDown(keyCode: Int, e: KeyEvent?, session: TerminalSession?): Boolean = false
        override fun onKeyUp(keyCode: Int, e: KeyEvent?): Boolean = false
        override fun onLongPress(event: MotionEvent?): Boolean = false

        override fun readControlKey(): Boolean = false
        override fun readAltKey(): Boolean = false
        override fun readShiftKey(): Boolean = false
        override fun readFnKey(): Boolean = false

        override fun onCodePoint(codePoint: Int, ctrlDown: Boolean, session: TerminalSession?): Boolean = false

        override fun onEmulatorSet() {
            val session = viewModel.remoteSession ?: return
            val emulator = session.emulator ?: return
            viewModel.sendResize(emulator.mColumns, emulator.mRows)
        }

        override fun logError(tag: String?, message: String?) {
            android.util.Log.e(tag ?: "TerminalView", message ?: "")
        }
        override fun logWarn(tag: String?, message: String?) {
            android.util.Log.w(tag ?: "TerminalView", message ?: "")
        }
        override fun logInfo(tag: String?, message: String?) {
            android.util.Log.i(tag ?: "TerminalView", message ?: "")
        }
        override fun logDebug(tag: String?, message: String?) {
            android.util.Log.d(tag ?: "TerminalView", message ?: "")
        }
        override fun logVerbose(tag: String?, message: String?) {
            android.util.Log.v(tag ?: "TerminalView", message ?: "")
        }
        override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) {
            android.util.Log.e(tag ?: "TerminalView", message, e)
        }
        override fun logStackTrace(tag: String?, e: Exception?) {
            android.util.Log.e(tag ?: "TerminalView", "Stack trace", e)
        }
    }
}
