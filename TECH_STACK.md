# Tech Stack

## Decided

| Layer | Choice | Notes |
|-------|--------|-------|
| Language | Elixir | Concurrency model ideal for streaming terminal I/O |
| Framework | Phoenix 1.7+ | LiveView for real-time web UI, Channels for native app |
| Real-time UI | Phoenix LiveView | Terminal rendering, session management, settings |
| Native app protocol | Phoenix Channels | Raw WebSocket for Android app |
| Terminal backend | tmux `pipe-pane` + FIFO | Streaming output, send-keys for input |
| Terminal emulator (browser) | xterm.js 5.x | De facto standard; addons: `@xterm/addon-fit`, `@xterm/addon-web-links` |
| CSS framework | Tailwind CSS 4.x | Utility-first, responsive. Tailwind Plus license available at `~/gitclone/tailwind-ui-tailwind-plus/tailwindplus/` |
| UI components | Tailwind Plus (application-ui) | Pre-built shells, navigation, forms, overlays, feedback, data-display, lists, headings, layout, page-examples |
| Auth | bcrypt_elixir 3.x | Password hashing (+ optional `RCA_AUTH_TOKEN` env var) |
| Config format | YAML | Human-editable. `yaml_elixir` (read) + `ymlr` (write) |
| Process management | DynamicSupervisor + Registry | Built-in Elixir — one PaneStream per active pane |
| Pub/Sub | Phoenix.PubSub | Connects PaneStreams to viewers, config change broadcast |
| Database | None | tmux is source of truth; config in YAML; prefs in localStorage |
| Deployment | Mix release | Single binary, zero infra dependencies beyond tmux |

## To Discuss

### 1. Tailwind CSS version: 3.x vs 4.x?

The design doc says "Tailwind CSS 3.x (ships with Phoenix 1.7+)". However, Tailwind CSS 4.0 was released in January 2025 and Phoenix 1.8 ships with Tailwind 4. Key differences:

- **v4**: CSS-first config (no `tailwind.config.js`), faster builds, new color system, `@theme` directive
- **v3**: Stable, well-documented, more community examples

Since this is a new project, **v4 is the recommendation** — no migration burden, and Phoenix 1.8 defaults to it. The Tailwind Plus components support both versions.

**Decision needed**: Tailwind 3 or 4?

### 2. Phoenix version: 1.7 vs 1.8?

Phoenix 1.8 (released late 2024) brings:
- Tailwind 4 as default
- Improved LiveView (~1.0)
- Better asset pipeline (esbuild integration improvements)
- Verified routes improvements

Since we're starting fresh, **1.8 is the recommendation**.

**Decision needed**: Phoenix 1.7 or 1.8?

### 3. JavaScript bundler: esbuild vs another?

Phoenix defaults to esbuild (fast, zero-config). Alternatives:
- **esbuild** (default): Fast, simple, works out of the box with Phoenix. Handles xterm.js fine.
- **Vite**: More features (HMR, plugin ecosystem), but adds complexity we may not need.

Recommendation: **esbuild** — we only have xterm.js as a JS dependency, no complex frontend build needed.

**Decision needed**: esbuild or something else?

### 4. Elixir version constraint?

Current stable is Elixir 1.18. We should pick a minimum version. Elixir 1.16+ gives us:
- Better diagnostics
- `Duration` type
- Improved `dbg`

Recommendation: **Elixir 1.17+** (good balance of features and availability).

**Decision needed**: Minimum Elixir version?

### 5. Node.js / npm for JS dependencies?

xterm.js is an npm package. Options:
- **npm/yarn via assets/package.json**: Standard Phoenix approach. Required for xterm.js and addons.
- **CDN imports**: Avoids npm but loses version pinning and offline builds.

Recommendation: **npm via assets/package.json** — standard, reliable, already in the design doc's project structure.

**Decision needed**: Any preference here, or go with npm?

### 6. Testing libraries?

Standard Phoenix testing stack:
- **ExUnit** (built-in): Unit and integration tests
- **Floki**: HTML parsing for LiveView tests (ships with Phoenix)
- **Mox**: Behaviour-based mocks (useful for mocking CommandRunner in tmux tests)
- **Wallaby** (optional): Browser-based E2E tests — useful for xterm.js integration but adds Chromedriver dependency

Recommendation: **ExUnit + Floki + Mox** to start, add Wallaby later if E2E testing of the terminal becomes valuable.

**Decision needed**: Include Wallaby from the start, or defer?

### 7. CI/CD?

Not specified in the design doc. Options:
- GitHub Actions (if hosted on GitHub)
- None initially (personal project, run tests locally)

**Decision needed**: Set up CI now or later?
