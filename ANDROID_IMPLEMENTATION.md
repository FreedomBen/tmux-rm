# Android App Implementation Plan

## Overview

Native Android app for termigate — connects to the termigate server via Phoenix Channels (WebSocket) for real-time terminal I/O and REST API for session management. The app does **not** bundle tmux; the server is the source of truth for all terminal state.

**Package ID**: `org.tamx.tmuxrm`
**Min API**: 26 (Android 8.0)
**Language**: Kotlin

## Server Prerequisites

The termigate server already has all required infrastructure:
- Phoenix Channels: `TerminalChannel` (binary terminal I/O), `SessionChannel` (real-time session list)
- REST API: `/api/login`, `/api/sessions`, `/api/panes`, `/api/quick-actions`, `/api/config`
- Auth: `POST /api/login` returns a `Phoenix.Token` bearer token; `UserSocket` validates it on connect
- Binary frame support: raw binary WebSocket frames for terminal data, JSON for control messages

No server changes are needed for the Android app.

## Phase Overview

| Phase | Name | Description | Effort |
|-------|------|-------------|--------|
| 1 | Project Setup & Dependencies | Gradle project, Termux library fork, Hilt DI shell | Medium |
| 2 | Network Layer | Phoenix Channel client, REST API client (Ktor), auth | Large |
| 3 | Login Screen | Auth flow, token storage, server URL config | Small |
| 4 | Session List Screen | Session/pane listing via Channel + REST, CRUD actions | Medium |
| 5 | Terminal Screen (Core) | Termux TerminalView + Channel integration, keyboard input | Large |
| 6 | Terminal Toolbars | Special key toolbar, quick action bar | Medium |
| 7 | Settings Screen | Quick actions CRUD, display preferences, connection settings | Small |
| 8 | Foreground Service & Notifications | Background connection persistence, pane death alerts | Medium |
| 9 | Polish & Distribution | ProGuard, CI/CD, Play Store, F-Droid, direct APK | Medium |

---

## Phase 1: Project Setup & Dependencies

### Goal
Create the Android Gradle project, fork the Termux terminal library into a local module, set up Hilt DI, and establish the project structure.

### Steps

#### 1.1 Create Gradle Project

Create `android/` at the repo root with this structure:

```
android/
  app/
    src/main/
      java/org/tamx/tmuxrm/
        App.kt                     # @HiltAndroidApp
      AndroidManifest.xml
    build.gradle.kts
  terminal-lib/
    src/main/java/
      com/termux/terminal/          # Forked from Termux
      com/termux/view/              # Forked from Termux
    build.gradle.kts               # Android library module
  build.gradle.kts                 # Root build file
  settings.gradle.kts              # includes :app, :terminal-lib
  gradle/
    libs.versions.toml             # Version catalog
  gradle.properties
  gradlew / gradlew.bat
```

#### 1.2 Version Catalog (`gradle/libs.versions.toml`)

```toml
[versions]
kotlin = "2.1.0"
agp = "8.7.3"
compose-bom = "2025.01.01"
compose-compiler = "1.5.15"
hilt = "2.53.1"
ktor = "3.0.3"
okhttp = "4.12.0"
navigation = "2.8.6"
lifecycle = "2.8.7"
kotlinx-serialization = "1.7.3"
coroutines = "1.9.0"
security-crypto = "1.1.0-alpha06"

[libraries]
# Compose
compose-bom = { group = "androidx.compose", name = "compose-bom", version.ref = "compose-bom" }
compose-ui = { group = "androidx.compose.ui", name = "ui" }
compose-material3 = { group = "androidx.compose.material3", name = "material3" }
compose-tooling-preview = { group = "androidx.compose.ui", name = "ui-tooling-preview" }
compose-tooling = { group = "androidx.compose.ui", name = "ui-tooling" }

# Navigation
navigation-compose = { group = "androidx.navigation", name = "navigation-compose", version.ref = "navigation" }

# Lifecycle
lifecycle-viewmodel-compose = { group = "androidx.lifecycle", name = "lifecycle-viewmodel-compose", version.ref = "lifecycle" }
lifecycle-runtime-compose = { group = "androidx.lifecycle", name = "lifecycle-runtime-compose", version.ref = "lifecycle" }

# Hilt
hilt-android = { group = "com.google.dagger", name = "hilt-android", version.ref = "hilt" }
hilt-compiler = { group = "com.google.dagger", name = "hilt-android-compiler", version.ref = "hilt" }
hilt-navigation-compose = { group = "androidx.hilt", name = "hilt-navigation-compose", version = "1.2.0" }

# Ktor
ktor-client-core = { group = "io.ktor", name = "ktor-client-core", version.ref = "ktor" }
ktor-client-okhttp = { group = "io.ktor", name = "ktor-client-okhttp", version.ref = "ktor" }
ktor-client-content-negotiation = { group = "io.ktor", name = "ktor-client-content-negotiation", version.ref = "ktor" }
ktor-serialization-json = { group = "io.ktor", name = "ktor-serialization-kotlinx-json", version.ref = "ktor" }

# OkHttp (shared with Ktor engine for WebSocket)
okhttp = { group = "com.squareup.okhttp3", name = "okhttp", version.ref = "okhttp" }

# Serialization
kotlinx-serialization-json = { group = "org.jetbrains.kotlinx", name = "kotlinx-serialization-json", version.ref = "kotlinx-serialization" }

# Coroutines
kotlinx-coroutines-android = { group = "org.jetbrains.kotlinx", name = "kotlinx-coroutines-android", version.ref = "coroutines" }

# Security
security-crypto = { group = "androidx.security", name = "security-crypto", version.ref = "security-crypto" }

# Testing
junit5 = { group = "org.junit.jupiter", name = "junit-jupiter", version = "5.11.4" }
compose-ui-test = { group = "androidx.compose.ui", name = "ui-test-junit4" }
compose-ui-test-manifest = { group = "androidx.compose.ui", name = "ui-test-manifest" }

[plugins]
android-application = { id = "com.android.application", version.ref = "agp" }
android-library = { id = "com.android.library", version.ref = "agp" }
kotlin-android = { id = "org.jetbrains.kotlin.android", version.ref = "kotlin" }
kotlin-serialization = { id = "org.jetbrains.kotlin.plugin.serialization", version.ref = "kotlin" }
compose-compiler = { id = "org.jetbrains.kotlin.plugin.compose", version.ref = "kotlin" }
hilt = { id = "com.google.dagger.hilt.android", version.ref = "hilt" }
ksp = { id = "com.google.devtools.ksp", version = "2.1.0-1.0.29" }
```

#### 1.3 Fork Termux Terminal Library

Copy the `terminal-emulator` and `terminal-view` source from [termux-app](https://github.com/termux/termux-app) into `android/terminal-lib/`:
- `com.termux.terminal` package: `TerminalEmulator`, `TerminalBuffer`, `TerminalRow`, `TerminalOutput`, etc.
- `com.termux.view` package: `TerminalView`, `TerminalRenderer`, `TextSelectionCursorController`

Create `terminal-lib/build.gradle.kts` as an Android library module (no Compose, no Hilt — pure Android View library).

#### 1.4 App Module Setup

`app/build.gradle.kts`:
- `applicationId = "org.tamx.tmuxrm"`
- `minSdk = 26`, `targetSdk = 35`
- Enable Compose, Hilt (KSP), kotlinx.serialization
- `implementation(project(":terminal-lib"))`

#### 1.5 Hilt Application Class

```kotlin
// App.kt
@HiltAndroidApp
class App : Application()
```

#### 1.6 Create Package Structure

```
org/tamx/tmuxrm/
  di/
  data/
    network/
    repository/
    model/
  ui/
    login/
    sessions/
    terminal/
    settings/
    navigation/
    theme/
  service/
```

### Verification
- Project builds and installs on a device/emulator
- Hilt compiles without errors
- `terminal-lib` module compiles (Termux classes available in app module)

---

## Phase 2: Network Layer

### Goal
Build the Phoenix Channel WebSocket client and REST API client. These are the foundation for all server communication.

### Dependencies
- Phase 1 complete

### Steps

#### 2.1 Phoenix Channel Client (`data/network/PhoenixSocket.kt`)

Minimal Kotlin implementation of the Phoenix Channel protocol on top of OkHttp WebSocket (~200-300 lines total across PhoenixSocket and PhoenixChannel).

**PhoenixSocket**:
```kotlin
class PhoenixSocket(
    private val url: String,
    private val params: Map<String, String>,  // {"token": "..."}
    private val client: OkHttpClient
) {
    val connectionState: StateFlow<ConnectionState>  // Connected, Disconnected, Reconnecting

    fun connect()
    fun disconnect()
    fun channel(topic: String): PhoenixChannel
}
```

Protocol details:
- **Text frames** (JSON): `[join_ref, ref, topic, event, payload]` — control messages, join/leave, heartbeat, replies
- **Binary frames**: raw terminal data — dispatched by WebSocket opcode (OkHttp's `onMessage(bytes: ByteString)`)
- **Heartbeat**: send `"heartbeat"` event every 30 seconds, expect `"phx_reply"` within 10 seconds or reconnect
- **Reconnection**: exponential backoff 1s → 2s → 4s → 8s → 16s → 30s cap, reset on successful connect

Key implementation notes:
- Use `ref` counter (AtomicLong) to match push replies
- Parse binary frames: the server sends raw bytes with no header for terminal output (see Phase 11 of server docs — `{:push, {:binary, data}, socket}` bypasses Channel framing). The client distinguishes binary frames (terminal data) from text frames (JSON control) by WebSocket opcode.
- Client-to-server binary input: send as JSON text frame `["join_ref", "ref", "terminal:...", "input", {"data": "<base64>"}]` since the existing server `handle_in("input")` accepts base64. Alternatively, if binary input is supported, use that path.

#### 2.2 Phoenix Channel Abstraction (`data/network/PhoenixChannel.kt`)

```kotlin
class PhoenixChannel(
    private val socket: PhoenixSocket,
    val topic: String
) {
    val events: SharedFlow<ChannelEvent>  // Server push events

    suspend fun join(payload: Map<String, Any> = emptyMap()): JoinResult
    suspend fun leave()
    suspend fun push(event: String, payload: Map<String, Any>): PushResult
}

sealed class ChannelEvent {
    data class TextEvent(val event: String, val payload: Map<String, Any?>) : ChannelEvent()
    data class BinaryEvent(val data: ByteArray) : ChannelEvent()
}

sealed class JoinResult {
    data class Ok(val payload: Map<String, Any?>) : JoinResult()
    data class Error(val reason: String) : JoinResult()
}
```

#### 2.3 REST API Client (`data/network/ApiClient.kt`)

Ktor HttpClient using the OkHttp engine (shares the OkHttpClient instance with WebSocket):

```kotlin
class ApiClient(
    private val client: HttpClient,
    private val serverUrl: () -> String
) {
    // Auth
    suspend fun login(username: String, password: String): Result<LoginResponse>

    // Sessions
    suspend fun listSessions(): Result<List<Session>>
    suspend fun createSession(name: String, command: String? = null): Result<Session>
    suspend fun deleteSession(name: String): Result<Unit>
    suspend fun renameSession(name: String, newName: String): Result<Unit>
    suspend fun createWindow(sessionName: String): Result<Unit>

    // Panes
    suspend fun splitPane(target: String, direction: String): Result<Unit>
    suspend fun deletePane(target: String): Result<Unit>

    // Quick Actions
    suspend fun getQuickActions(): Result<List<QuickAction>>
    suspend fun createQuickAction(action: QuickAction): Result<List<QuickAction>>
    suspend fun updateQuickAction(id: String, action: QuickAction): Result<List<QuickAction>>
    suspend fun deleteQuickAction(id: String): Result<List<QuickAction>>
    suspend fun reorderQuickActions(ids: List<String>): Result<List<QuickAction>>

    // Config
    suspend fun getConfig(): Result<Config>
}
```

#### 2.4 Auth Plugin (`data/network/AuthPlugin.kt`)

Ktor plugin that adds the bearer token from `AuthRepository` to all API requests (except `/api/login`). On 401 response, clear the token and signal re-authentication.

#### 2.5 Hilt Network Module (`di/NetworkModule.kt`)

```kotlin
@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {
    @Provides @Singleton
    fun provideOkHttpClient(): OkHttpClient  // shared between Ktor and PhoenixSocket

    @Provides @Singleton
    fun provideHttpClient(okhttp: OkHttpClient, authRepo: AuthRepository): HttpClient  // Ktor

    @Provides @Singleton
    fun provideApiClient(httpClient: HttpClient, prefs: AppPreferences): ApiClient
}
```

#### 2.6 Data Models (`data/model/`)

```kotlin
@Serializable
data class Session(
    val name: String,
    val windows: List<Window>,
    val attached: Boolean,
    val created: Long
)

@Serializable
data class Window(
    val index: Int,
    val name: String,
    val panes: List<Pane>
)

@Serializable
data class Pane(
    val index: Int,
    val width: Int,
    val height: Int,
    val command: String,
    val active: Boolean
)

@Serializable
data class QuickAction(
    val id: String? = null,
    val label: String,
    val command: String,
    val confirm: Boolean = false,
    val color: String = "default",
    val icon: String? = null
)

@Serializable
data class LoginResponse(val token: String)
```

### Verification
- Unit test PhoenixSocket/Channel with a mock WebSocket (verify JSON framing, heartbeat, reconnect)
- Unit test ApiClient with mock HTTP responses (verify serialization, auth header injection, error handling)
- Integration test: connect to a running termigate server, authenticate, join a session channel, receive session list

---

## Phase 3: Login Screen

### Goal
Implement the login flow — server URL configuration, credential entry, token storage.

### Dependencies
- Phase 2 complete (ApiClient, AuthPlugin)

### Steps

#### 3.1 Auth Repository (`data/repository/AuthRepository.kt`)

```kotlin
class AuthRepository @Inject constructor(
    private val apiClient: ApiClient,
    private val encryptedPrefs: SharedPreferences  // EncryptedSharedPreferences
) {
    val isAuthenticated: StateFlow<Boolean>

    suspend fun login(serverUrl: String, username: String, password: String): Result<Unit>
    fun getToken(): String?
    fun clearToken()
    fun getServerUrl(): String?
    fun getLastUsername(): String?
}
```

- Token stored in `EncryptedSharedPreferences` (Android Keystore-backed)
- Server URL and last username stored in regular `SharedPreferences`
- On 401 anywhere in the app → `clearToken()` and navigate to Login

#### 3.2 Login ViewModel (`ui/login/LoginViewModel.kt`)

```kotlin
@HiltViewModel
class LoginViewModel @Inject constructor(
    private val authRepository: AuthRepository
) : ViewModel() {

    data class UiState(
        val serverUrl: String = "",
        val username: String = "",
        val password: String = "",
        val isLoading: Boolean = false,
        val error: String? = null
    )

    val uiState: StateFlow<UiState>

    fun onServerUrlChanged(url: String)
    fun onUsernameChanged(username: String)
    fun onPasswordChanged(password: String)
    fun onLoginClicked()
}
```

#### 3.3 Login Screen (`ui/login/LoginScreen.kt`)

Compose UI:
- Server URL text field (pre-filled from last used, stored in preferences)
- Username text field (pre-filled from last login)
- Password text field (password visibility toggle)
- "Connect" button
- Error message display (wrong credentials, server unreachable, timeout)
- Loading indicator during auth request

#### 3.4 Navigation Setup (`ui/navigation/AppNavigation.kt`)

```kotlin
@Composable
fun AppNavigation(navController: NavHostController) {
    NavHost(navController, startDestination = "login") {
        composable("login") { LoginScreen(onLoginSuccess = { navController.navigate("sessions") }) }
        composable("sessions") { SessionListScreen(...) }
        composable("terminal/{target}") { TerminalScreen(...) }
        composable("settings") { SettingsScreen(...) }
    }
}
```

- Start destination: "sessions" if token exists and is valid, "login" otherwise
- Global 401 handling: navigate to "login", clear back stack

#### 3.5 Theme (`ui/theme/`)

Material 3 dark theme (matches termigate web dark terminal aesthetic):
- Dark surface colors
- Terminal-green accent
- Monospace font for terminal-related text

### Verification
- Login with valid credentials → token stored, navigates to sessions
- Login with invalid credentials → error shown, stays on login
- Login with unreachable server → timeout error
- App restart with valid token → skips login, goes to sessions
- App restart with expired token → shows login

---

## Phase 4: Session List Screen

### Goal
Display tmux sessions and panes, support CRUD operations (create, rename, kill sessions; create windows, split/kill panes).

### Dependencies
- Phase 3 complete (auth flow, navigation)

### Steps

#### 4.1 Session Repository (`data/repository/SessionRepository.kt`)

```kotlin
class SessionRepository @Inject constructor(
    private val apiClient: ApiClient,
    private val phoenixSocket: PhoenixSocket
) {
    // Real-time session list via SessionChannel
    val sessions: StateFlow<List<Session>>

    // Channel-based: join "sessions" topic, receive updates
    suspend fun connectSessionChannel()
    fun disconnectSessionChannel()

    // REST-based mutations
    suspend fun createSession(name: String, command: String? = null): Result<Unit>
    suspend fun deleteSession(name: String): Result<Unit>
    suspend fun renameSession(name: String, newName: String): Result<Unit>
    suspend fun createWindow(sessionName: String): Result<Unit>
    suspend fun splitPane(target: String, direction: String): Result<Unit>
    suspend fun deletePane(target: String): Result<Unit>

    // Fallback for pull-to-refresh
    suspend fun refreshSessions(): Result<Unit>
}
```

- On `connectSessionChannel()`: join the `"sessions"` Channel topic, parse join reply for initial session list, collect `"sessions_updated"` push events
- Cache last session list in memory for immediate display

#### 4.2 Session List ViewModel

```kotlin
@HiltViewModel
class SessionListViewModel @Inject constructor(
    private val sessionRepo: SessionRepository
) : ViewModel() {

    data class UiState(
        val sessions: List<Session> = emptyList(),
        val isLoading: Boolean = true,
        val error: String? = null,
        val showCreateDialog: Boolean = false,
        val showRenameDialog: SessionRenameState? = null,
        val showDeleteConfirmation: String? = null  // session name
    )

    val uiState: StateFlow<UiState>

    fun onCreateSession(name: String, command: String?)
    fun onDeleteSession(name: String)
    fun onRenameSession(oldName: String, newName: String)
    fun onCreateWindow(sessionName: String)
    fun onSplitPane(target: String, direction: String)
    fun onDeletePane(target: String)
    fun onRefresh()
    fun onPaneClicked(target: String)  // triggers navigation
}
```

#### 4.3 Session List Screen (`ui/sessions/SessionListScreen.kt`)

Compose UI:
- **Session cards**: expandable cards showing session name, window count, attached status, created time
  - Expand to show panes: pane index, dimensions, running command
  - Tap pane → navigate to Terminal Screen with target
- **FAB**: "New Session" → bottom sheet with name input (validated: `^[a-zA-Z0-9_-]+$`) and optional command
- **Session actions** (long-press or kebab menu): rename, create window, kill (with confirmation dialog)
- **Pane actions** (long-press on pane): split horizontal, split vertical, kill pane (with confirmation)
- **Pull-to-refresh**: calls REST API as fallback
- **Empty state**: "No sessions. Create one to get started."
- **Error state**: "Server unreachable" banner with retry

Session name validation: `^[a-zA-Z0-9_-]+$` — enforced in the create/rename dialogs, matching the server's validation.

#### 4.4 Swipe-to-Delete

Implement `SwipeToDismiss` on session cards for quick delete, with a confirmation dialog.

### Verification
- Sessions appear from Channel join reply
- Real-time updates when sessions change (create/kill from another client)
- Create session → appears in list immediately
- Delete session → removed from list, confirmation shown first
- Rename session → name updates in list
- Split pane → new pane appears under the session
- Pull-to-refresh works when Channel is disconnected
- Tap pane → navigates to terminal screen

---

## Phase 5: Terminal Screen (Core)

### Goal
Full-screen terminal rendering with real-time streaming via Phoenix Channel. This is the most complex phase — it bridges the Termux terminal emulator with the Channel protocol.

### Dependencies
- Phase 4 complete (session list, navigation)
- Phase 1 complete (terminal-lib module with Termux classes)

### Steps

#### 5.1 Terminal Repository (`data/repository/TerminalRepository.kt`)

```kotlin
class TerminalRepository @Inject constructor(
    private val phoenixSocket: PhoenixSocket
) {
    // Join terminal channel, return history + dimensions
    suspend fun connect(target: String): Result<TerminalConnection>

    // Disconnect from terminal channel
    suspend fun disconnect(target: String)

    // Send keyboard input
    suspend fun sendInput(target: String, data: ByteArray)

    // Send resize
    suspend fun sendResize(target: String, cols: Int, rows: Int)
}

data class TerminalConnection(
    val history: ByteArray,       // ring buffer contents from join reply
    val cols: Int,
    val rows: Int,
    val events: Flow<TerminalEvent>  // streaming events from server
)

sealed class TerminalEvent {
    data class Output(val data: ByteArray) : TerminalEvent()
    data class Reconnected(val buffer: ByteArray) : TerminalEvent()
    data class Resized(val cols: Int, val rows: Int) : TerminalEvent()
    data object PaneDead : TerminalEvent()
    data class Superseded(val newTarget: String) : TerminalEvent()
}
```

Channel topic format: `"terminal:{session}:{window}:{pane}"` — convert from the `"session:window.pane"` target format used in the UI.

Join reply: `{"history": "<base64>", "cols": int, "rows": int}` — decode base64 history into ByteArray.

#### 5.2 Terminal Session Bridge (`ui/terminal/TerminalSession.kt`)

Bridges Phoenix Channel events ↔ Termux `TerminalEmulator`:

```kotlin
class TerminalSession(
    cols: Int,
    rows: Int,
    private val onOutput: (ByteArray) -> Unit  // called by emulator for query responses
) : TerminalOutput {

    val emulator = TerminalEmulator(this, cols, rows, /* scrollback */ 10000)

    // Called when server sends terminal output
    fun onServerOutput(bytes: ByteArray) {
        emulator.append(bytes, bytes.size)
    }

    // Called when server sends full buffer (reconnect)
    fun onReconnected(buffer: ByteArray) {
        emulator.reset()
        emulator.append(buffer, buffer.size)
    }

    // Called when pane is resized by another viewer
    fun onResized(cols: Int, rows: Int) {
        emulator.resize(cols, rows)
    }

    // TerminalOutput interface — emulator sends data back (e.g., cursor position queries)
    override fun write(data: ByteArray, offset: Int, count: Int) {
        onOutput(data.sliceArray(offset until offset + count))
    }
}
```

#### 5.3 Terminal ViewModel

```kotlin
@HiltViewModel
class TerminalViewModel @Inject constructor(
    private val terminalRepo: TerminalRepository,
    private val savedStateHandle: SavedStateHandle
) : ViewModel() {

    private val target: String = savedStateHandle["target"]!!

    // TerminalSession lives in ViewModel — survives config changes (rotation)
    var terminalSession: TerminalSession? = null
        private set

    data class UiState(
        val isConnected: Boolean = false,
        val isLoading: Boolean = true,
        val error: String? = null,
        val paneDead: Boolean = false,
        val supersededTarget: String? = null,
        val quickActions: List<QuickAction> = emptyList()
    )

    val uiState: StateFlow<UiState>

    fun connect()           // join channel, create TerminalSession, start collecting events
    fun disconnect()        // leave channel
    fun sendInput(data: ByteArray)
    fun sendResize(cols: Int, rows: Int)
    fun onQuickAction(action: QuickAction)
}
```

- `connect()`: calls `terminalRepo.connect(target)`, creates `TerminalSession` with the returned dimensions, feeds history into it, then launches a coroutine to collect the event Flow and dispatch to `TerminalSession`
- `TerminalSession` is held in the ViewModel, not the Composable — it persists across rotation/recomposition
- On `PaneDead`: set `paneDead = true`, show overlay
- On `Superseded(newTarget)`: set `supersededTarget`, prompt user or auto-navigate

#### 5.4 Terminal Screen (`ui/terminal/TerminalScreen.kt`)

```kotlin
@Composable
fun TerminalScreen(
    target: String,
    onBack: () -> Unit,
    onNavigateToTarget: (String) -> Unit,
    viewModel: TerminalViewModel = hiltViewModel()
) {
    // Top bar (auto-hides after 3s)
    // Quick action bar (Phase 6)
    // Terminal view (AndroidView wrapping TerminalView)
    // Special key toolbar (Phase 6)
    // Pane dead overlay
    // Reconnecting indicator
}
```

**TerminalView integration via `AndroidView`**:

```kotlin
AndroidView(
    factory = { context ->
        TerminalView(context, null).apply {
            // Attach to TerminalSession's emulator
            val session = viewModel.terminalSession ?: return@apply
            attachSession(session.emulator)
            requestFocus()
            // Forward keyboard input to server
            setOnKeyListener { _, _, event -> ... }
        }
    },
    update = { view ->
        // Re-bind to current emulator (after rotation, reconnect)
        viewModel.terminalSession?.let { view.attachSession(it.emulator) }
    }
)
```

**Focus management**: `TerminalView` needs `requestFocus()` on first composition and after returning from Settings screen. Without focus, the soft keyboard input doesn't reach the terminal.

**Keyboard input**: The Termux `TerminalView` translates Android `KeyEvent`s and `InputConnection` text into terminal byte sequences. Capture these bytes and send via `viewModel.sendInput(bytes)`.

#### 5.5 Passive Resize Behavior

The Android app is a **passive resizer** — it reads pane dimensions from the join reply and renders at that size. It does NOT send resize events when the viewport changes (soft keyboard, rotation). Instead:
- Scale the terminal view to fit via font size adjustment
- When receiving `"resized"` from server: reconfigure `TerminalEmulator` with new dimensions, re-render
- Optional "Fit to screen" button (Phase 6): calculates cols/rows for current viewport, sends resize with confirmation

#### 5.6 Auto-Hide Top Bar

Top bar shows session target and back button. Hides after 3 seconds of inactivity. Tap top edge of screen to reveal. Implemented with `AnimatedVisibility` + `LaunchedEffect` timer.

### Verification
- Join terminal → history renders in TerminalView
- Type on soft keyboard → characters appear in terminal
- Server output streams in real-time (run `ls`, `top`, etc.)
- Rotate device → terminal state preserved (ViewModel survives)
- Pane killed externally → "Session ended" overlay appears
- Session renamed → superseded event navigates to new target
- Back button → returns to session list, leaves channel

---

## Phase 6: Terminal Toolbars

### Goal
Add the special key toolbar (Esc, Tab, Ctrl, arrows, etc.) and quick action bar to the Terminal Screen.

### Dependencies
- Phase 5 complete (terminal screen, input path working)

### Steps

#### 6.1 Special Key Toolbar (`ui/terminal/SpecialKeyToolbar.kt`)

Fixed at the bottom of the Terminal Screen:

```
[ Esc ] [ Tab ] [ Ctrl ] [ Alt ] [ ↑ ] [ ↓ ] [ ← ] [ → ] [ Paste ]
```

- `Ctrl` and `Alt` are **sticky modifiers**: tap to toggle, highlight when active. Next key press combines with the modifier, then modifier deactivates.
- Each button emits the corresponding byte sequence via `viewModel.sendInput()`:
  - `Esc` → `\x1b`
  - `Tab` → `\x09`
  - `Ctrl` + key → bitwise AND with `0x1f` (e.g., Ctrl+C → `\x03`)
  - Arrow keys → `\x1b[A`, `\x1b[B`, `\x1b[C`, `\x1b[D`
- **Swipe up** reveals extended keys row: F1-F12, PgUp/PgDn, Home/End
- **Paste button**: reads from Android `ClipboardManager`, sends text as bytes via `sendInput()`
- **Haptic feedback**: optional vibration on key press (configurable in Settings)

#### 6.2 Quick Action Bar (`ui/terminal/QuickActionBar.kt`)

Horizontally scrollable row above the terminal, below the top bar:

```
[ Status ] [ Push ⚠ ] [ Tests ] [ Deploy ⚠ ] [ Logs ] ►
```

- Fetched from server on Terminal Screen mount via `GET /api/quick-actions` (cached in `ConfigRepository`)
- Color-coded pills matching web styling (green, red, yellow, blue, default)
- `⚠` indicator for `confirm: true` actions
- **Tap**: sends `command + "\n"` as bytes via `viewModel.sendInput()`, or shows confirmation dialog first if `confirm: true`
- **Collapsible**: chevron toggle to hide the bar and reclaim terminal space
- **Hidden when empty**: if no quick actions are configured, bar is not rendered

#### 6.3 Confirmation Dialog

For quick actions with `confirm: true`:

```
┌─────────────────────────────┐
│ Run this command?            │
│                              │
│ ┌──────────────────────────┐ │
│ │ git add . && git commit  │ │
│ │ -m . && git push         │ │
│ └──────────────────────────┘ │
│                              │
│         [Cancel]  [Run]      │
└─────────────────────────────┘
```

Material 3 `AlertDialog` with the command text in a monospace code block.

#### 6.4 Toolbar Auto-Hide with Soft Keyboard

- When the soft keyboard is open: hide the special key toolbar (to maximize terminal space)
- When the soft keyboard closes: show the toolbar again
- Detect keyboard state via `WindowInsets.ime` (Compose) or `ViewTreeObserver.OnGlobalLayoutListener`

### Verification
- Esc, Tab, arrow keys produce correct terminal behavior
- Ctrl+C cancels a running process
- Sticky Ctrl: tap Ctrl, tap C → sends Ctrl+C, Ctrl deactivates
- Paste inserts clipboard content into terminal
- Quick action tap sends command + Enter
- Confirmation dialog appears for `confirm: true` actions
- Toolbar hides when soft keyboard opens

---

## Phase 7: Settings Screen

### Goal
Quick actions management, display preferences, and connection settings.

### Dependencies
- Phase 6 complete (quick action bar exists to test against)

### Steps

#### 7.1 Config Repository (`data/repository/ConfigRepository.kt`)

```kotlin
class ConfigRepository @Inject constructor(
    private val apiClient: ApiClient,
    private val prefs: SharedPreferences
) {
    // Quick actions (synced from server, cached locally)
    val quickActions: StateFlow<List<QuickAction>>

    suspend fun fetchQuickActions(): Result<List<QuickAction>>
    suspend fun createQuickAction(action: QuickAction): Result<List<QuickAction>>
    suspend fun updateQuickAction(id: String, action: QuickAction): Result<List<QuickAction>>
    suspend fun deleteQuickAction(id: String): Result<List<QuickAction>>
    suspend fun reorderQuickActions(ids: List<String>): Result<List<QuickAction>>
}
```

Quick actions cached in plain `SharedPreferences` after each fetch (not sensitive data). Available immediately on app start, synced when the server is reachable.

#### 7.2 Settings ViewModel

```kotlin
@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val configRepo: ConfigRepository,
    private val authRepo: AuthRepository,
    private val appPrefs: AppPreferences
) : ViewModel() {

    data class UiState(
        val quickActions: List<QuickAction> = emptyList(),
        val fontSize: Int = 14,
        val keepScreenOn: Boolean = true,
        val vibrateOnKey: Boolean = true,
        val serverUrl: String = "",
        val isLoading: Boolean = false,
        val editingAction: QuickAction? = null
    )

    val uiState: StateFlow<UiState>

    // Quick action CRUD
    fun onAddAction()
    fun onEditAction(action: QuickAction)
    fun onSaveAction(action: QuickAction)
    fun onDeleteAction(id: String)
    fun onReorderActions(ids: List<String>)

    // Display preferences
    fun onFontSizeChanged(size: Int)
    fun onKeepScreenOnChanged(enabled: Boolean)
    fun onVibrateChanged(enabled: Boolean)

    // Auth
    fun onLogout()
}
```

#### 7.3 Settings Screen (`ui/settings/SettingsScreen.kt`)

Sections:
1. **Quick Actions**: list with edit/delete buttons, "Add" button at bottom, edit form (label, command, confirm toggle, color picker)
2. **Display**: font size slider, keep screen on toggle, vibrate on special keys toggle
3. **Connection**: server URL (read-only display), logout button
4. **About**: app version, link to GitHub

#### 7.4 App Preferences (`data/AppPreferences.kt`)

Wrapper around `SharedPreferences` for local display/connection settings:
- Font size (default: 14)
- Keep screen on (default: true)
- Vibrate on key press (default: true)
- Server URL
- Last username

### Verification
- Add a quick action → appears in Settings list and Terminal quick action bar
- Edit a quick action → changes persist to server and update UI
- Delete a quick action → removed from both views
- Font size change → reflected in terminal on next render
- Logout → clears token, navigates to login, clears back stack

---

## Phase 8: Foreground Service & Notifications

### Goal
Keep the terminal connection alive when the app is backgrounded. Notify the user of important events (pane death, connection lost).

### Dependencies
- Phase 5 complete (terminal connection lifecycle)

### Steps

#### 8.1 Foreground Service (`service/TerminalForegroundService.kt`)

```kotlin
class TerminalForegroundService : Service() {
    // Started when first TerminalChannel topic is joined
    // Stopped when last TerminalChannel topic is left
    // Persistent notification: "Connected to session-name:0.0"
    // Multiple sessions: "Connected to 3 sessions"
}
```

- Service is started from `TerminalRepository` when `connect()` is called
- Service is stopped from `TerminalRepository` when the last `disconnect()` is called
- Uses `startForeground()` with a persistent notification
- Notification channel: "Terminal Connection" (importance: LOW — no sound/vibration, just visible)
- Notification taps → opens the app to the active terminal

#### 8.2 Notification Channels

Create in `App.onCreate()`:
1. **"terminal_connection"** (LOW importance): foreground service notification
2. **"terminal_events"** (DEFAULT importance): pane death, connection lost

#### 8.3 Pane Death Notification

When `"pane_dead"` event received while app is in background:
- Show notification: "Session ended: session-name:0.0"
- Tap → opens session list

#### 8.4 Connection Lost Notification

When WebSocket disconnects and cannot reconnect after 60 seconds while in background:
- Show notification: "Connection lost to server"
- Tap → opens app, which attempts reconnect

#### 8.5 Manifest Permissions

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />  <!-- API 33+ runtime permission -->
<uses-permission android:name="android.permission.INTERNET" />
```

### Verification
- Background the app while terminal is open → notification appears
- Return to app → notification dismissed
- Kill a pane while app is backgrounded → event notification appears
- Tap notification → returns to app
- No terminal sessions active → no foreground service running

---

## Phase 9: Polish & Distribution

### Goal
ProGuard rules, CI/CD pipeline, and distribution via Play Store, F-Droid, and direct APK.

### Dependencies
- All previous phases complete

### Steps

#### 9.1 ProGuard Rules (`app/proguard-rules.pro`)

Keep rules for:
- OkHttp (ships its own rules, verify)
- kotlinx.serialization `@Serializable` data classes and generated serializers
- Ktor client engine and content negotiation plugin
- Termux terminal-emulator (JNI/reflection if used)

Test with `isMinifyEnabled = true` and verify:
- Login flow works
- Session list loads
- Terminal renders and accepts input
- Quick actions serialize/deserialize

#### 9.2 Build Variants

```kotlin
android {
    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
        debug {
            applicationIdSuffix = ".debug"
        }
    }
}
```

#### 9.3 CI/CD (GitHub Actions)

Workflow file at `.github/workflows/android.yml`:

```yaml
on:
  push:
    branches: [main]
    paths: ['android/**']
  pull_request:
    paths: ['android/**']
  push:
    tags: ['v*']

jobs:
  build:
    - Checkout
    - Set up JDK 17
    - Gradle cache
    - Build debug APK
    - Run unit tests
    - Run lint

  release:  # only on tags
    - Build release APK + AAB
    - Sign artifacts
    - Create GitHub Release with APK attached
    - Upload AAB to Play Store internal track (optional)
```

#### 9.4 F-Droid Metadata

```
android/
  metadata/android/en-US/
    full_description.txt
    short_description.txt
    changelogs/
      1.txt
  fdroid/
    org.tamx.tmuxrm.yml    # F-Droid build recipe
```

Requirements for F-Droid:
- No proprietary dependencies (no Google Play Services, Firebase, or proprietary analytics) — already satisfied
- All dependencies are open source (Termux: Apache 2.0, OkHttp: Apache 2.0, Jetpack: Apache 2.0)
- Reproducible builds

#### 9.5 Signing

- **Debug**: auto-generated debug keystore
- **Release**: upload keystore stored as GitHub Actions secret
- **Play Store**: App signing by Google Play (upload key signs AAB, Google manages distribution key)
- **F-Droid + Direct APK**: signed with the same release key

#### 9.6 App Icon

TBD — placeholder icon for initial release.

### Verification
- Release APK installs and runs correctly (ProGuard doesn't break anything)
- CI builds pass on push to main
- Tagged release creates GitHub Release with APK
- F-Droid metadata validates
- Direct APK sideloads and runs

---

## Testing Strategy

### Unit Tests (`src/test/`)

| Component | What to Test |
|-----------|-------------|
| `PhoenixSocket` | JSON framing, heartbeat timing, reconnect backoff, ref matching |
| `PhoenixChannel` | Join/leave lifecycle, event dispatching, push/reply correlation |
| `ApiClient` | Request serialization, response deserialization, error mapping, auth header |
| `SessionRepository` | Channel → StateFlow mapping, fallback to REST on disconnect |
| `TerminalSession` | Emulator receives bytes correctly, output callback fires |
| ViewModels | State transitions, error handling, navigation events |

### Instrumented Tests (`src/androidTest/`)

| Component | What to Test |
|-----------|-------------|
| Login Screen | Form validation, login flow, error display |
| Session List | Cards render, expand/collapse, create dialog, delete confirmation |
| Terminal Screen | TerminalView renders, keyboard input forwarded, toolbar interaction |
| Settings Screen | Quick action CRUD forms, preference toggles |

### Integration Tests

- End-to-end: app → real termigate server → terminal I/O round-trip
- Requires a running termigate server in CI (or mock server)

---

## Key Implementation Notes

### Target Format Conversion

The server uses `"session:window.pane"` format (e.g., `"myapp:0.1"`). The Channel topic uses `"terminal:session:window:pane"` (e.g., `"terminal:myapp:0:1"`). The app must convert between these formats:

```kotlin
fun targetToTopic(target: String): String {
    // "myapp:0.1" → "terminal:myapp:0:1"
    val (session, rest) = target.split(":", limit = 2)
    val (window, pane) = rest.split(".", limit = 2)
    return "terminal:$session:$window:$pane"
}

fun topicToTarget(topic: String): String {
    // "terminal:myapp:0:1" → "myapp:0.1"
    val parts = topic.removePrefix("terminal:").split(":")
    return "${parts[0]}:${parts[1]}.${parts[2]}"
}
```

### Binary Frame Handling

The server sends terminal output as raw binary WebSocket frames (no Channel framing — `{:push, {:binary, data}, socket}` bypasses the serializer). The client receives these via OkHttp's `onMessage(webSocket, bytes: ByteString)` callback. These are terminal output bytes — feed directly into the Termux emulator.

Control messages (pane_dead, resized, superseded) arrive as JSON text frames with standard Channel framing `[join_ref, ref, topic, event, payload]`.

The client must handle both frame types on the same WebSocket connection.

### Session Channel Join Reply

The `"sessions"` channel join reply contains the current session list. The server serializes sessions as a list of maps. Parse with kotlinx.serialization matching the server's JSON format.

### Error Recovery

- **Channel disconnect**: exponential backoff reconnect (1s → 30s cap). On reconnect, rejoin all active topics. Server sends fresh history in join reply.
- **REST API failure**: show error in UI, retry on user action (pull-to-refresh, retry button)
- **Token expired (401)**: clear token, navigate to login
- **Server unreachable**: show "Server unreachable" with cached data where available (session list, quick actions)
