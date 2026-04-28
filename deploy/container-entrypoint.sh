#!/bin/sh
set -eu

if [ -z "${TERMIGATE_TMUX_SOCKET:-}" ]; then
  # No host tmux socket mounted — start a container-local tmux session
  # so termigate has something to attach to on first load.
  tmux new-session -d -s main 2>/dev/null || true
fi

# Run the release in the background so the shell stays alive to translate
# SIGTERM/SIGINT into a graceful 'bin/termigate stop'. plain `exec start`
# leaves the BEAM as PID 1; OTP does handle SIGTERM there, but only after
# its own shutdown_time, which routinely exceeded podman's 10s default and
# fell back to SIGKILL.
/app/bin/termigate start &
PID=$!

shutdown() {
  if kill -0 "${PID}" 2>/dev/null; then
    /app/bin/termigate stop >/dev/null 2>&1 || kill -TERM "${PID}" 2>/dev/null || true
  fi
}

trap shutdown TERM INT

# `wait` returns early on signal delivery; loop until the BEAM is gone.
while kill -0 "${PID}" 2>/dev/null; do
  wait "${PID}" 2>/dev/null || true
done

wait "${PID}" 2>/dev/null || true
exit $?
