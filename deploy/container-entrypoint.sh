#!/bin/sh
set -eu

if [ -z "${TERMIGATE_TMUX_SOCKET:-}" ]; then
  # No host tmux socket mounted — start a container-local tmux session
  # so termigate has something to attach to on first load.
  tmux new-session -d -s main 2>/dev/null || true
fi

exec /app/bin/termigate start
