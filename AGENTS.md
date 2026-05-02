# Repository Guidelines

## Project Structure & Module Organization

Termigate combines a Phoenix LiveView server with an Android client. Server code lives in `server/lib/termigate` for tmux, config, and MCP logic, and `server/lib/termigate_web` for controllers, LiveViews, channels, plugs, and components. Server tests mirror that layout under `server/test`. Frontend assets are in `server/assets`, with static output in `server/priv/static`. Android app code is in `android/app/src/main`, shared terminal code is in `android/terminal-lib/src/main`, and JVM tests live under each module's `src/test`. Root `docs`, `implementation-docs`, `deploy`, and `packaging` directories support design and releases.

## Build, Test, and Development Commands

- `cd server && mix setup`: install Elixir deps and build assets.
- `cd server && mix phx.server`: run the dev server at `http://localhost:8888`.
- `cd server && mix test`: run the ExUnit suite.
- `cd server && mix precommit`: compile with warnings as errors, check unused deps, format, and test.
- `make build`: create a production server release.
- `make test`: run server tests from the repo root.
- `make android`: build the Android debug APK.
- `make android-test`: run Android JVM unit tests.

## Coding Style & Naming Conventions

Format Elixir, HEEx, and config files with `mix format`; `server/.formatter.exs` includes Phoenix LiveView HTML formatting. Use `Termigate` modules and snake_case Elixir file names. Keep LiveViews named with a `Live` suffix, and place web code under `TermigateWeb`. Android code uses Kotlin/Java conventions, package `org.tamx.termigate` for the app and `com.termux.*` for terminal library code. In shell scripts and Makefiles, write variable interpolation as `"${VAR}"`; keep Makefile help accurate.

## Testing Guidelines

Add tests for code changes when the existing infrastructure covers the area. Put server tests in matching `server/test/.../*_test.exs` files. Prefer focused runs such as `cd server && mix test test/termigate/tmux_manager_test.exs:42` while iterating, then run `mix precommit` before finishing server work. Android tests use JUnit/Robolectric; name test classes with `Test` and run them with `make android-test`.

## Commit & Pull Request Guidelines

Use clear commit subjects that describe the change without `feat:` or `bug:` prefixes. Include a body explaining what changed and why. Do not add Claude co-author lines. Never push from an agent session. Pull requests should summarize behavior changes, list tests run, link related issues, and include screenshots or recordings for UI changes.

## Agent-Specific Instructions

Do not read `TODO.md` or other TODO files. Update documentation when code changes affect documented behavior. Follow the nested `server/AGENTS.md` guidance for Phoenix work inside `server/`.
