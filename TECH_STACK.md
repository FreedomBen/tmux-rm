# Tech Stack

## Server / Web App

| Layer | Choice | Notes |
|-------|--------|-------|
| Language | Elixir 1.17+ | Concurrency model ideal for streaming terminal I/O |
| Framework | Phoenix 1.8 | Latest stable. LiveView ~1.0 for real-time web UI, Channels for native app |
| Real-time UI | Phoenix LiveView (latest) | Terminal rendering, session management, settings |
| Native app protocol | Phoenix Channels | Raw WebSocket for Android app |
| Terminal backend | tmux `pipe-pane` + FIFO | Streaming output, send-keys for input |
| Terminal emulator (browser) | xterm.js 5.x | Addons: `@xterm/addon-fit`, `@xterm/addon-web-links` |
| CSS framework | Tailwind CSS 4 | CSS-first config, `@theme` directive. Tailwind Plus license at `~/gitclone/tailwind-ui-tailwind-plus/tailwindplus/` |
| UI components | Tailwind Plus (application-ui) | Shells, navigation, forms, overlays, feedback, data-display, lists, headings, layout, page-examples |
| JS bundler | esbuild | Phoenix default, fast, zero-config. Sufficient for xterm.js |
| JS package manager | npm | Standard `assets/package.json` for xterm.js and addons |
| Auth | bcrypt_elixir 3.x | Password hashing (+ optional `RCA_AUTH_TOKEN` env var) |
| Config format | YAML | Human-editable. `yaml_elixir` (read) + `ymlr` (write) |
| Process management | DynamicSupervisor + Registry | Built-in Elixir — one PaneStream per active pane |
| Pub/Sub | Phoenix.PubSub | Connects PaneStreams to viewers, config change broadcast |
| Database | None | tmux is source of truth; config in YAML; prefs in localStorage |
| Deployment | Mix release | Single binary, zero infra dependencies beyond tmux |
| Testing | ExUnit + Floki + Mox + Wallaby | Unit, LiveView, mocks, and browser E2E (Chromedriver) |
| CI/CD | GitHub Actions | Automated test runs, linting, release builds |

## Android App

| Layer | Choice | Notes |
|-------|--------|-------|
| Language | Kotlin | Coroutines for async WebSocket I/O, modern Android standard |
| Min API level | 26 (Android 8.0) | ~95% device coverage, full coroutine/Compose support |
| UI toolkit | Jetpack Compose | Declarative UI for session list, quick actions, settings |
| Terminal renderer | Termux terminal-emulator library | Battle-tested VT100/xterm emulator (Java). Handles escape sequences, 256-color, scrollback, selection. Wired to receive bytes from Phoenix Channel instead of a local process |
| Networking | OkHttp WebSocket | Thin Phoenix Channel client on top — protocol is simple JSON framing |
| Server communication | Phoenix Channels | Same channel/topic API as the web app (`terminal_channel.ex`) |
| Auth | Token-based | Obtain token via REST login endpoint, attach to Channel join params |
| Dependency injection | Hilt | Standard Android DI, works well with ViewModel/Compose |
| Build system | Gradle (Kotlin DSL) | Standard Android build tooling |
| Testing | JUnit 5 + Espresso + Compose UI tests | Unit, integration, and UI testing |
| Distribution | Google Play, F-Droid, Direct APK | All three channels from the start |
| CI/CD | GitHub Actions | Shared repo workflow — build APK, run tests, sign release |

### Architecture Notes

- **Terminal rendering**: The Termux `terminal-emulator` library does all the heavy lifting — ANSI/xterm escape sequence parsing, cursor management, color rendering, scrollback buffer. The app feeds it raw bytes from the Phoenix Channel and renders the resulting screen state. No need to write a terminal emulator from scratch.
- **UI shell**: Jetpack Compose handles everything outside the terminal view — session list, quick action buttons, settings, connection status. The terminal view itself is a custom `AndroidView` wrapping Termux's `TerminalView`.
- **Channel protocol**: The Android app connects to the same `TerminalChannel` as the web app. Messages: `key_input` (client→server), `output` (server→client), `resize` (bidirectional). Auth token is passed in channel join params.
- **Offline behavior**: App shows last-known session list from local cache. Reconnects automatically when network is restored. No local terminal state — the server + tmux are the source of truth.
- **Quick actions**: Fetched via REST API (`GET /api/quick_actions`), cached locally. Synced on app foreground. CRUD operations via the same REST endpoints the web settings UI uses.
- **Distribution**: APKs are signed with a single key. Google Play uses Android App Bundle (AAB). F-Droid requires reproducible builds (no proprietary dependencies — Termux's library and all deps are open source, so this is clean). Direct APK hosted on GitHub Releases.
