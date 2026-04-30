# termigate — Tech Stack

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
| JS package manager | npm | Standard `server/assets/package.json` for xterm.js and addons |
| Auth | bcrypt_elixir 3.x | Password hashing (+ optional `TERMIGATE_AUTH_TOKEN` env var) |
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

### Key Decisions

- **Termux library**: Fork `terminal-emulator` and `terminal-view` modules into a standalone library. Publish to GitHub Packages.
- **Phoenix Channel client**: Custom minimal Kotlin implementation (~200 lines) on top of OkHttp WebSocket.
- **Hardware keyboard**: Use Termux's built-in handling (Ctrl+key, function keys, Alt combos). Custom mappings deferred.
- **App name**: termigate
- **Package ID**: `org.tamx.tmuxrm`
- **Domain**: `tmuxrm.tamx.org` (temporary)
