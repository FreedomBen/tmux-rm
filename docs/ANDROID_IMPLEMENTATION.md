# Android App Implementation Plan

## Overview

Native Android app for termigate — connects to the termigate server via Phoenix Channels (WebSocket) for real-time terminal I/O and REST API for session management. The app does **not** bundle tmux; the server is the source of truth for all terminal state.

**Package ID**: `org.tamx.termigate`
**Min API**: 26 (Android 8.0)
**Language**: Kotlin

## Server Prerequisites

The termigate server already has all required infrastructure:
- Phoenix Channels: `TerminalChannel` (base64-encoded terminal I/O over JSON), `SessionChannel` (real-time session list)
- REST API: `/api/login`, `/api/sessions`, `/api/panes`, `/api/quick-actions`, `/api/config`
- Auth: `POST /api/login` returns a `Phoenix.Token` bearer token (context `"api_token"`); `UserSocket` validates it on connect (accepts both `"channel"` and `"api_token"` token contexts)
- Terminal output: base64-encoded data in JSON text frames (`"output"` event with `{data: "<base64>"}`)
- Terminal input: accepts both JSON text frames (`"input"` event with `{data: "<bytes>"}`) and raw binary WebSocket frames

No server changes are needed for the Android app.

## Phase Overview

| Phase | Name | Description | Effort | Status |
|-------|------|-------------|--------|--------|
| 1 | Project Setup & Dependencies | Gradle project, Termux library fork, Hilt DI shell | Medium | Done |
| 2 | Network Layer | Phoenix Channel client, REST API client (Ktor), auth | Large | Done |
| 3 | Login Screen | Auth flow, token storage, server URL config | Small | Done |
| 4 | Session List Screen | Session/pane listing via Channel + REST, CRUD actions | Medium | Done |
| 5 | Terminal Screen (Core) | Termux TerminalView + Channel integration, keyboard input | Large | Done |
| 6 | Terminal Toolbars | Special key toolbar, quick action bar | Medium | Done |
| 7 | Settings Screen | Quick actions CRUD, display preferences, connection settings | Small | Done |
| 8 | Foreground Service & Notifications | Background connection persistence, pane death alerts | Medium | Done |
| 9 | Polish & Distribution | ProGuard, CI/CD, Play Store, F-Droid, direct APK | Medium | Done |

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
      java/org/tamx/termigate/
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
- `applicationId = "org.tamx.termigate"`
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
org/tamx/termigate/
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

### Checklist

- [x] 1.1 Create Gradle project (`android/` directory structure, root `build.gradle.kts`, `settings.gradle.kts`, `gradle.properties`, Gradle wrapper)
- [x] 1.2 Version catalog (`gradle/libs.versions.toml`)
- [x] 1.3 Fork Termux terminal library (`terminal-lib/` module with `com.termux.terminal` and `com.termux.view`)
- [x] 1.4 App module setup (`app/build.gradle.kts` with Compose, Hilt, KSP, serialization, `implementation(project(":terminal-lib"))`)
- [x] 1.5 Hilt application class (`App.kt` with `@HiltAndroidApp`)
- [x] 1.6 Create package structure (`di/`, `data/{network,repository,model}/`, `ui/{login,sessions,terminal,settings,navigation,theme}/`, `service/`)
- [x] Verification: Project builds (`./gradlew assembleDebug` passes)
- [x] Verification: Hilt compiles without errors
- [x] Verification: `terminal-lib` module compiles (Termux classes available in app module)

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
    private val baseUrl: String,       // e.g. "https://myserver:8888"
    private val params: Map<String, String>,  // {"token": "..."} — sent as URL query params
    private val client: OkHttpClient
) {
    val connectionState: StateFlow<ConnectionState>  // Connected, Disconnected, Reconnecting

    // Connects to: ws(s)://<baseUrl>/socket/websocket?token=...&vsn=2.0.0
    fun connect()
    fun disconnect()
    fun channel(topic: String): PhoenixChannel
}
```

Protocol details:
- **WebSocket URL**: `ws(s)://<host>:<port>/socket/websocket?token=<token>&vsn=2.0.0` — the `vsn=2.0.0` parameter is **required** for the v2 wire protocol
- **All frames are JSON text frames**: `[join_ref, ref, topic, event, payload]` (v2 protocol) — including terminal output, control messages, join/leave, heartbeat, replies
- **Terminal output**: arrives as `"output"` event with `{"data": "<base64>"}` payload — must base64-decode before feeding to emulator
- **Heartbeat**: send `"heartbeat"` event every 30 seconds, expect `"phx_reply"` within 10 seconds or reconnect
- **Reconnection**: exponential backoff 1s → 2s → 4s → 8s → 16s → 30s cap, reset on successful connect

Key implementation notes:
- Use `ref` counter (AtomicLong) to match push replies
- Client-to-server input: send as JSON text frame `["join_ref", "ref", "terminal:...", "input", {"data": "<bytes>"}]`. The server `handle_in("input")` accepts the data field as a binary string. Alternatively, raw binary WebSocket frames are also accepted by the server.
- **Max input size**: the server rejects input messages larger than 131,072 bytes (128 KB). Large paste operations must be chunked.

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
    data class Message(val event: String, val payload: Map<String, Any?>) : ChannelEvent()
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

    // Sessions — GET /api/sessions returns {"sessions": [...]}
    suspend fun listSessions(): Result<List<Session>>
    suspend fun createSession(name: String, command: String? = null): Result<Unit>
    suspend fun deleteSession(name: String): Result<Unit>
    suspend fun renameSession(name: String, newName: String): Result<Unit>  // PUT /api/sessions/:name body: {"new_name": "..."}
    suspend fun createWindow(sessionName: String): Result<Unit>

    // Panes (target format: "session:window.pane", e.g. "myapp:0.1")
    suspend fun splitPane(target: String, direction: String): Result<Unit>
    suspend fun deletePane(target: String): Result<Unit>

    // Quick Actions — GET/POST/PUT return {"quick_actions": [...]}, DELETE returns {"status": "ok"}
    suspend fun getQuickActions(): Result<List<QuickAction>>
    suspend fun createQuickAction(action: QuickAction): Result<List<QuickAction>>
    suspend fun updateQuickAction(id: String, action: QuickAction): Result<List<QuickAction>>
    suspend fun deleteQuickAction(id: String): Result<Unit>
    suspend fun reorderQuickActions(ids: List<String>): Result<List<QuickAction>>

    // Config
    suspend fun getConfig(): Result<Config>
}
```

All REST responses are wrapped in a top-level key. The `ApiClient` must unwrap them:
- `GET /api/sessions` → `{"sessions": [...]}`
- `GET /api/quick-actions` → `{"quick_actions": [...]}`
- `POST /api/quick-actions` → `{"quick_actions": [...]}` (201 status)
- `PUT /api/quick-actions/:id` → `{"quick_actions": [...]}`
- `DELETE /api/quick-actions/:id` → `{"status": "ok"}`
- `PUT /api/quick-actions/order` → `{"quick_actions": [...]}`

Use wrapper data classes for deserialization:

```kotlin
@Serializable
data class SessionsResponse(val sessions: List<Session>)

@Serializable
data class QuickActionsResponse(@SerialName("quick_actions") val quickActions: List<QuickAction>)
```

#### 2.4 Auth Plugin (`data/network/AuthPlugin.kt`)

Ktor plugin that adds `Authorization: Bearer <token>` header from `AuthRepository` to all API requests (except `/api/login`). On 401 response, clear the token and signal re-authentication. Handle 429 responses from rate-limited endpoints (e.g., `/api/login`) by showing a "too many attempts" error.

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
    val windows: Int,               // window COUNT, not a list
    val attached: Boolean,
    val created: Long? = null,      // Unix timestamp (seconds), nullable (tmux may have no creation time)
    val panes: List<Pane> = emptyList()  // flat list of all panes across all windows
)

@Serializable
data class Pane(
    @SerialName("session_name")
    val sessionName: String,
    @SerialName("window_index")
    val windowIndex: Int,
    val index: Int,
    val width: Int,
    val height: Int,
    val command: String,
    @SerialName("pane_id")
    val paneId: String
) {
    /** Target format used by REST API and Channel topics: "session:window.pane" */
    val target: String get() = "$sessionName:$windowIndex.$index"
}

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
data class LoginResponse(
    val token: String,
    @SerialName("expires_in")
    val expiresIn: Long             // TTL in seconds (default: 604800 = 7 days)
)
```

**`created` field**: Both the REST API and Session Channel serialize `created` as a Unix timestamp (integer seconds). The field is nullable because tmux sessions may have no creation time.

### Checklist

- [x] 2.1 Phoenix Channel client (`data/network/PhoenixSocket.kt` — v2 protocol, heartbeat, reconnect, ref counter)
- [x] 2.2 Phoenix Channel abstraction (`data/network/PhoenixChannel.kt` — join/leave/push, event flow, reply correlation)
- [x] 2.3 REST API client (`data/network/ApiClient.kt` — Ktor + OkHttp, all endpoints, response unwrapping)
- [x] 2.4 Auth plugin (`data/network/AuthInterceptor.kt` — bearer token injection, 401/429 handling)
- [x] 2.5 Hilt network module (`di/NetworkModule.kt` — shared OkHttpClient, Ktor HttpClient, ApiClient)
- [x] 2.6 Data models (`data/model/Session.kt` — Session, Pane, QuickAction, LoginResponse, request/response wrappers)
- [x] 2.6+ App preferences (`data/repository/AppPreferences.kt` — EncryptedSharedPreferences for token, regular prefs for URL/username)
- [ ] Verification: Unit test PhoenixSocket/Channel with mock WebSocket
- [ ] Verification: Unit test ApiClient with mock HTTP responses
- [ ] Verification: Integration test against running termigate server

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
    val authRequired: StateFlow<Boolean?>  // null = unknown, true/false after probe

    suspend fun login(serverUrl: String, username: String, password: String): Result<Unit>
    suspend fun probeAuthRequired(serverUrl: String): Boolean  // try unauthenticated GET /api/sessions
    fun getToken(): String?
    fun clearToken()
    fun getServerUrl(): String?
    fun getLastUsername(): String?
}
```

- Token stored in `EncryptedSharedPreferences` (Android Keystore-backed)
- Server URL and last username stored in regular `SharedPreferences`
- On 401 anywhere in the app → `clearToken()` and navigate to Login
- On 503 with `error: "setup_required"` → server has no admin account yet; show a "complete setup in your browser" message and stay on Login

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

**Server URL port resolution** (`data/network/ServerUrl.kt`): when the user enters a URL with no explicit port, the auth probe tries the scheme-default port first (80 for `http`, 443 for `https`) and falls back to `:8888` if that fails. If the URL specifies a port, only that URL is tried. The winning URL is saved to preferences so subsequent API calls and WebSocket connections use the resolved address.

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

- Start destination: "sessions" if a stored token validates against the server, "login" otherwise
- Global 401 handling: navigate to "login", clear back stack
- Global 503 `setup_required` handling: navigate to "login" and surface the "complete setup in browser" message

#### 3.5 Theme (`ui/theme/`)

Material 3 dark theme (matches termigate web dark terminal aesthetic):
- Dark surface colors
- Terminal-green accent
- Monospace font for terminal-related text

### Checklist

- [x] 3.1 Auth repository (`data/repository/AuthRepository.kt` — login, token storage, probe auth, clear token)
- [x] 3.2 Login ViewModel (`ui/login/LoginViewModel.kt`)
- [x] 3.3 Login screen (`ui/login/LoginScreen.kt` — server URL, username, password fields, error display)
- [x] 3.4 Navigation setup (`ui/navigation/AppNavigation.kt` — login/sessions/terminal/settings routes, start destination logic)
- [x] 3.5 Theme (`ui/theme/` — Material 3 dark theme, terminal-green accent)
- [ ] Verification: Login with valid credentials → token stored, navigates to sessions
- [ ] Verification: Login with invalid credentials → error shown
- [ ] Verification: Login with unreachable server → timeout error
- [ ] Verification: App restart with valid token → skips login
- [ ] Verification: Server before first-run setup → login screen shows "complete setup in browser" message (503 `setup_required`)
- [ ] Verification: Rate-limited login attempt → shows "too many attempts" error

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
- Also handle `"tmux_status"` events: `{"status": "ok" | "no_server" | "not_found" | "error: ..."}` — show appropriate banner when tmux is unavailable
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
        val tmuxStatus: String? = null,  // null = ok, "no_server", "not_found", "error: ..."
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
  - Expand to show panes (flat list grouped by `windowIndex`): pane index, dimensions, running command
  - Tap pane → navigate to Terminal Screen with target (`"session:window.pane"`)
- **FAB**: "New Session" → bottom sheet with name input (validated: `^[a-zA-Z0-9_-]+$`) and optional command
- **Session actions** (long-press or kebab menu): rename, create window, kill (with confirmation dialog)
- **Pane actions** (long-press on pane): split horizontal, split vertical, kill pane (with confirmation)
- **Pull-to-refresh**: calls REST API as fallback
- **Empty state**: "No sessions. Create one to get started."
- **Error state**: "Server unreachable" banner with retry

Session name validation: `^[a-zA-Z0-9_-]+$` — enforced in the create/rename dialogs, matching the server's validation.

#### 4.4 Swipe-to-Delete

Implement `SwipeToDismiss` on session cards for quick delete, with a confirmation dialog.

### Checklist

- [x] 4.1 Session repository (`data/repository/SessionRepository.kt` — Channel-based real-time sessions, REST mutations, fallback refresh)
- [x] 4.2 Session list ViewModel (`ui/sessions/SessionListViewModel.kt`)
- [x] 4.3 Session list screen (`ui/sessions/SessionListScreen.kt` — session cards, pane list, FAB, dialogs)
- [x] 4.4 Swipe-to-delete on session cards
- [ ] Verification: Sessions appear from Channel join reply
- [ ] Verification: Real-time updates when sessions change
- [ ] Verification: Create/delete/rename session works
- [ ] Verification: Split pane → new pane appears
- [ ] Verification: Pull-to-refresh works
- [ ] Verification: Tap pane → navigates to terminal screen

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
    // Join terminal channel, return history
    // Pass cols/rows as join params to resize pane on join and get correctly-sized history
    suspend fun connect(target: String, cols: Int, rows: Int): Result<TerminalConnection>

    // Disconnect from terminal channel
    suspend fun disconnect(target: String)

    // Send keyboard input
    suspend fun sendInput(target: String, data: ByteArray)

    // Send resize
    suspend fun sendResize(target: String, cols: Int, rows: Int)
}

data class TerminalConnection(
    val history: ByteArray,       // ring buffer contents from join reply (base64-decoded)
    val cols: Int,                // from join params (passed through)
    val rows: Int,                // from join params (passed through)
    val events: Flow<TerminalEvent>  // streaming events from server
)

sealed class TerminalEvent {
    data class Output(val data: ByteArray) : TerminalEvent()   // already base64-decoded
    data class Reconnected(val buffer: ByteArray) : TerminalEvent()
    data class Resized(val cols: Int, val rows: Int) : TerminalEvent()
    data object PaneDead : TerminalEvent()
    data class Superseded(val newTarget: String) : TerminalEvent()
}
```

Channel topic format: `"terminal:{session}:{window}:{pane}"` — convert from the `"session:window.pane"` target format used in the UI.

Join reply: `{"history": "<base64>"}` — decode base64 history into ByteArray. The join reply does **not** include cols/rows. To get correctly-sized history, pass `cols` and `rows` as **channel join payload params** (not socket URL params) — the server will resize the pane and recapture the buffer before replying. Server validates: cols 1-500, rows 1-200. Pane dimensions can be read from the session list (`Pane.width`, `Pane.height`) before joining.

Join errors: the server may reject with `{"reason": "pane_not_ready"}` or `{"reason": "..."}`. Handle `pane_not_ready` with a short retry delay — the PaneStream may still be starting.

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

- `connect()`: calculates cols/rows from the viewport, calls `terminalRepo.connect(target, cols, rows)`, creates `TerminalSession` with those dimensions, feeds history into it, then launches a coroutine to collect the event Flow and dispatch to `TerminalSession`. The `"output"` events arrive with base64-encoded data — `TerminalRepository` decodes them before emitting `TerminalEvent.Output`.
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

#### 5.5 Resize Behavior

On initial connect, the app sends `cols` and `rows` as channel join params (calculated from viewport size and font metrics). The server resizes the pane and returns correctly-sized history.

After joining, the app **does** send resize events when the viewport changes. Termux's `TerminalView` handles this automatically:
- `TerminalView.onSizeChanged()` fires on any view dimension change (soft keyboard show/hide, rotation, multi-window)
- It calls `updateSize()` which recalculates cols/rows from the view dimensions and font metrics
- It notifies the host via the `TerminalViewClient.onEmulatorSet()` callback
- The app hooks `onEmulatorSet()` to read the new cols/rows from the emulator and calls `viewModel.sendResize(cols, rows)`
- **Debounce**: resize events should be debounced (~100-200ms) to avoid flooding the server during animated transitions (keyboard slide, rotation animation)

When receiving `"resized"` from the server (another viewer resized): reconfigure `TerminalEmulator` with new dimensions via `emulator.resize(cols, rows)`, re-render. To avoid a resize loop, skip sending a resize back to the server when the resize originated from a server push.

#### 5.6 Auto-Hide Top Bar

Top bar shows session target and back button. Hides after 3 seconds of inactivity. Tap top edge of screen to reveal. Implemented with `AnimatedVisibility` + `LaunchedEffect` timer.

### Checklist

- [x] 5.1 Terminal repository (`data/repository/TerminalRepository.kt` — connect/disconnect, sendInput, sendResize, event Flow)
- [x] 5.2 Terminal session bridge (`ui/terminal/RemoteTerminalSession.kt` — TerminalEmulator ↔ Channel bridge, extends TerminalSession)
- [x] 5.3 Terminal ViewModel (`ui/terminal/TerminalViewModel.kt`)
- [x] 5.4 Terminal screen (`ui/terminal/TerminalScreen.kt` — AndroidView wrapping TerminalView, keyboard input)
- [x] 5.5 Resize behavior (join params with cols/rows, server-initiated resize without echo loop)
- [x] 5.6 Auto-hide top bar (AnimatedVisibility, 3s timer, tap to toggle)
- [ ] Verification: Join terminal → history renders
- [ ] Verification: Keyboard input → characters appear
- [ ] Verification: Server output streams in real-time
- [ ] Verification: Rotate device → terminal state preserved
- [ ] Verification: Pane killed externally → overlay appears
- [ ] Verification: Back button → returns to session list

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

#### 6.4 Toolbar Visibility with Soft Keyboard

- When the soft keyboard is open: show the special key toolbar above it as an extra row (Esc, Ctrl, arrows are most useful alongside the keyboard)
- When the soft keyboard closes: hide the toolbar (tap the terminal to bring up keyboard + toolbar together)
- Detect keyboard state via `WindowInsets.ime` (Compose) or `ViewTreeObserver.OnGlobalLayoutListener`

### Checklist

- [x] 6.1 Special key toolbar (`ui/terminal/SpecialKeyToolbar.kt` — Esc, Tab, Ctrl, Alt, arrows, Paste, extended keys)
- [x] 6.2 Quick action bar (`ui/terminal/QuickActionBar.kt` — scrollable pills, color-coded, confirm indicator)
- [x] 6.3 Confirmation dialog (for `confirm: true` quick actions)
- [x] 6.4 Toolbar visibility with soft keyboard (show toolbar when keyboard open, hide when closed)
- [ ] Verification: Esc, Tab, arrow keys produce correct behavior
- [ ] Verification: Ctrl+C cancels a running process
- [ ] Verification: Sticky Ctrl works (tap Ctrl, tap C → Ctrl+C)
- [ ] Verification: Paste inserts clipboard content
- [ ] Verification: Quick action tap sends command + Enter
- [ ] Verification: Confirmation dialog for `confirm: true` actions
- [ ] Verification: Toolbar appears/hides with soft keyboard

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

### Checklist

- [x] 7.1 Config repository (`data/repository/ConfigRepository.kt` — quick actions CRUD, local cache)
- [x] 7.2 Settings ViewModel (`ui/settings/SettingsViewModel.kt`)
- [x] 7.3 Settings screen (`ui/settings/SettingsScreen.kt` — quick actions, display prefs, connection, about)
- [x] 7.4 App preferences (`data/repository/AppPreferences.kt` — font size, keep screen on, vibrate, quick actions cache)
- [ ] Verification: Quick action CRUD works (add/edit/delete)
- [ ] Verification: Font size change reflected in terminal
- [ ] Verification: Logout clears token and navigates to login

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

### Checklist

- [x] 8.1 Foreground service (`service/TerminalForegroundService.kt`)
- [x] 8.2 Notification channels (create in `App.onCreate()` — `terminal_connection`, `terminal_events`)
- [x] 8.3 Pane death notification (background `pane_dead` event → notification)
- [x] 8.4 Connection lost notification (WebSocket disconnect after 60s → notification)
- [x] 8.5 Manifest permissions (`FOREGROUND_SERVICE_DATA_SYNC`, `POST_NOTIFICATIONS`)
- [ ] Verification: Background app → notification appears
- [ ] Verification: Return to app → notification dismissed
- [ ] Verification: Pane killed in background → event notification
- [ ] Verification: No active sessions → no foreground service

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
    tags: ['v*']
    paths: ['android/**']
  pull_request:
    paths: ['android/**']

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
    org.tamx.termigate.yml    # F-Droid build recipe
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

### Checklist

- [x] 9.1 ProGuard rules (`app/proguard-rules.pro` — keep rules for serialization, Ktor, OkHttp, Termux)
- [x] 9.2 Build variants (release with minify + shrinkResources, debug with `.debug` suffix)
- [x] 9.3 CI/CD (`.github/workflows/android.yml` — build, test, lint, release)
- [x] 9.4 F-Droid metadata (`metadata/android/en-US/` + `fdroid/org.tamx.termigate.yml`)
- [x] 9.5 Signing (debug keystore, release keystore via env vars / GitHub secrets)
- [ ] 9.6 App icon (final design — TBD)
- [ ] Verification: Release APK installs and runs correctly
- [ ] Verification: CI builds pass on push to main
- [ ] Verification: Tagged release creates GitHub Release with APK
- [ ] Verification: F-Droid metadata validates
- [ ] Verification: Direct APK sideloads and runs

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

### Terminal Data Encoding

All server-to-client communication uses standard Phoenix Channel JSON text frames `[join_ref, ref, topic, event, payload]`. Terminal output arrives as `"output"` events with base64-encoded data:

```json
[null, null, "terminal:myapp:0:1", "output", {"data": "bHMgLWxhCg=="}]
```

The client must base64-decode the `data` field before feeding bytes into the Termux emulator. Control messages (`pane_dead`, `resized`, `superseded`, `reconnected`) use the same JSON text frame format with their respective event names and payloads.

For client-to-server input, the app sends JSON text frames with the `"input"` event. The server also accepts raw binary WebSocket frames for input, but JSON is simpler and sufficient.

### Session Channel Join Reply

The `"sessions"` channel join reply contains the current session list wrapped in `{"sessions": [...]}`. The `"sessions_updated"` push events use the same format: `{"sessions": [...]}`. Parse with kotlinx.serialization matching the server's JSON format. Both Channel and REST serialize `created` as a Unix timestamp (integer seconds).

### Error Recovery

- **Channel disconnect**: exponential backoff reconnect (1s → 30s cap). On reconnect, rejoin all active topics. Server sends fresh history in join reply.
- **REST API failure**: show error in UI, retry on user action (pull-to-refresh, retry button)
- **Token expired (401)**: clear token, navigate to login
- **Rate limited (429)**: show "Too many attempts, try again later" — applies to `/api/login`
- **Server unreachable**: show "Server unreachable" with cached data where available (session list, quick actions)

### Pre-Setup Mode

Before an admin account exists (`Termigate.Auth.auth_enabled?()` returns false), the server fails closed: `/api/*`, `/mcp`, and the WebSocket all reject requests. The API and MCP return `503` with body `{"error": "setup_required"}`; the WebSocket refuses the upgrade. Only `/healthz`, `POST /api/login` (which simply returns an auth error), and the token-gated `/setup` page are reachable.

The Android client cannot complete first-run setup itself — that flow runs over the token-gated `/setup` LiveView. When the app receives `503 setup_required`, it stays on the login screen and shows a message instructing the user to finish setup in a browser on the host. Once setup completes and an admin exists, normal `POST /api/login` flow takes over.
