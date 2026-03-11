import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { Socket } from "phoenix";
import { loadPrefs, savePref, resolveTheme } from "../preferences";
import * as PreferencesPanel from "../preferences_panel";

// --- Mobile detection ---
function isMobile() {
  return window.innerWidth < 640;
}

function isTablet() {
  return window.innerWidth >= 640 && window.innerWidth <= 1024;
}

// --- Escape sequences for special keys ---
const KEY_SEQUENCES = {
  Escape: "\x1b",
  Tab: "\x09",
  ArrowUp: "\x1b[A",
  ArrowDown: "\x1b[B",
  ArrowRight: "\x1b[C",
  ArrowLeft: "\x1b[D",
  F1: "\x1bOP",
  F2: "\x1bOQ",
  F3: "\x1bOR",
  F4: "\x1bOS",
  F5: "\x1b[15~",
  F6: "\x1b[17~",
  F7: "\x1b[18~",
  F8: "\x1b[19~",
  F9: "\x1b[20~",
  F10: "\x1b[21~",
  F11: "\x1b[23~",
  F12: "\x1b[24~",
  PageUp: "\x1b[5~",
  PageDown: "\x1b[6~",
  Home: "\x1b[H",
  End: "\x1b[F",
};

const TerminalHook = {
  mounted() {
    const target = this.el.dataset.target;

    // Load preferences from localStorage (Phase 10 full preference system)
    const prefs = loadPrefs();

    // Create xterm.js terminal
    this.term = new Terminal({
      fontSize: prefs.fontSize,
      fontFamily: prefs.fontFamily,
      cursorStyle: prefs.cursorStyle,
      cursorBlink: prefs.cursorBlink,
      scrollback: prefs.scrollback,
      theme: resolveTheme(prefs),
    });

    // Addons
    this.fitAddon = new FitAddon();
    this.term.loadAddon(this.fitAddon);
    this.term.loadAddon(new WebLinksAddon());

    // Open terminal in container
    this.term.open(this.el);
    this.fitAddon.fit();

    // Track mobile state and multi-pane mode
    this._isMobile = isMobile();
    this._isMultiPane = this.el.dataset.mode === "multi";

    // Connect companion Channel for binary I/O
    this._connectChannel(target);

    // Send initial resize to server (only if not mobile and not multi-pane — both are passive)
    if (!this._isMobile && !this._isMultiPane) {
      this.pushEvent("resize", { cols: this.term.cols, rows: this.term.rows });
    }

    // Input handling: buffer keystrokes and flush periodically
    this._inputBuffer = [];
    this._inputTimer = null;
    this._encoder = new TextEncoder();

    // Sticky modifier state
    this._ctrlActive = false;
    this._altActive = false;

    this.term.onData((data) => {
      // Apply sticky modifiers
      if (this._ctrlActive && data.length === 1) {
        const code = data.charCodeAt(0);
        // Ctrl + key = key & 0x1f (for letters a-z / A-Z)
        if (code >= 64 && code <= 127) {
          data = String.fromCharCode(code & 0x1f);
        }
        this._ctrlActive = false;
        this._updateModifierUI();
      }
      if (this._altActive) {
        data = "\x1b" + data;
        this._altActive = false;
        this._updateModifierUI();
      }

      this._inputBuffer.push(data);
      const totalBytes = this._inputBuffer.reduce((s, d) => s + d.length, 0);

      if (totalBytes >= 64) {
        this._flushInput();
      } else if (!this._inputTimer) {
        this._inputTimer = requestAnimationFrame(() => {
          this._inputTimer = null;
          this._flushInput();
        });
      }
    });

    // Resize handling with debounce
    this._resizeTimer = null;
    this._resizeObserver = new ResizeObserver(() => {
      clearTimeout(this._resizeTimer);
      this._resizeTimer = setTimeout(() => {
        this.fitAddon.fit();
        if (!this._isMobile && !this._isMultiPane) {
          this.pushEvent("resize", {
            cols: this.term.cols,
            rows: this.term.rows,
          });
        }
      }, 300);
    });
    this._resizeObserver.observe(this.el);

    // Handle pane_resized from other viewers (via LiveView)
    this.handleEvent("pane_resized", ({ cols, rows }) => {
      this.term.resize(cols, rows);
    });

    // Clipboard: Ctrl+Shift+V to paste
    this.el.addEventListener("keydown", (e) => {
      if (e.ctrlKey && e.shiftKey && e.key === "V") {
        e.preventDefault();
        this._pasteFromClipboard();
      }
    });

    // --- Mobile features (skip in multi-pane mode) ---
    if (!this._isMultiPane) {
      this._setupVirtualToolbar();
      this._setupSoftKeyboard();
      this._setupTouchGestures();
      this._setupAutoHidingHeader();
      this._setupPreferencesPanel();
    }
  },

  // --- Preferences Panel ---
  _setupPreferencesPanel() {
    const gearBtn = document.querySelector(".terminal-prefs-btn");
    if (!gearBtn) return;

    gearBtn.addEventListener("click", (e) => {
      e.preventDefault();
      PreferencesPanel.open(this.term, this.fitAddon, (showToolbar) => {
        // Toolbar visibility toggle callback
        if (this._toolbar) {
          if (showToolbar) {
            this._toolbar.classList.remove("vk-hidden");
          } else {
            this._toolbar.classList.add("vk-hidden");
          }
        }
      });
    });
  },

  // --- Virtual Key Toolbar ---
  _setupVirtualToolbar() {
    // Only render on mobile/tablet
    if (!isMobile() && !isTablet()) return;

    // Respect showToolbar preference
    const prefs = loadPrefs();
    const showToolbar = prefs.showToolbar !== false;

    // Create toolbar container
    this._toolbar = document.createElement("div");
    this._toolbar.className = "virtual-toolbar" + (showToolbar ? "" : " vk-hidden");
    this._toolbar.innerHTML = `
      <div class="vk-main-row">
        <button class="vk-btn" data-key="Escape">Esc</button>
        <button class="vk-btn" data-key="Tab">Tab</button>
        <button class="vk-btn vk-modifier" data-modifier="ctrl">Ctrl</button>
        <button class="vk-btn vk-modifier" data-modifier="alt">Alt</button>
        <button class="vk-btn" data-key="ArrowUp">↑</button>
        <button class="vk-btn" data-key="ArrowDown">↓</button>
        <button class="vk-btn" data-key="ArrowLeft">←</button>
        <button class="vk-btn" data-key="ArrowRight">→</button>
        <button class="vk-btn vk-paste" data-action="paste">Paste</button>
      </div>
      <div class="vk-extended-row vk-hidden">
        <button class="vk-btn vk-sm" data-key="F1">F1</button>
        <button class="vk-btn vk-sm" data-key="F2">F2</button>
        <button class="vk-btn vk-sm" data-key="F3">F3</button>
        <button class="vk-btn vk-sm" data-key="F4">F4</button>
        <button class="vk-btn vk-sm" data-key="F5">F5</button>
        <button class="vk-btn vk-sm" data-key="F6">F6</button>
        <button class="vk-btn vk-sm" data-key="F7">F7</button>
        <button class="vk-btn vk-sm" data-key="F8">F8</button>
        <button class="vk-btn vk-sm" data-key="F9">F9</button>
        <button class="vk-btn vk-sm" data-key="F10">F10</button>
        <button class="vk-btn vk-sm" data-key="F11">F11</button>
        <button class="vk-btn vk-sm" data-key="F12">F12</button>
        <button class="vk-btn vk-sm" data-key="PageUp">PgUp</button>
        <button class="vk-btn vk-sm" data-key="PageDown">PgDn</button>
        <button class="vk-btn vk-sm" data-key="Home">Home</button>
        <button class="vk-btn vk-sm" data-key="End">End</button>
      </div>
      <div class="vk-expand-handle" data-action="toggle-extended">
        <span class="vk-expand-chevron">▲</span>
      </div>
    `;

    // Insert after terminal container's parent (the flex column)
    const termPage = this.el.closest(".terminal-page") || this.el.parentElement;
    termPage.appendChild(this._toolbar);

    // Compact modifier row (visible when soft keyboard is open)
    this._compactToolbar = document.createElement("div");
    this._compactToolbar.className = "vk-compact-row vk-hidden";
    this._compactToolbar.innerHTML = `
      <button class="vk-btn vk-compact" data-key="Escape">Esc</button>
      <button class="vk-btn vk-compact vk-modifier" data-modifier="ctrl">Ctrl</button>
      <button class="vk-btn vk-compact vk-modifier" data-modifier="alt">Alt</button>
      <button class="vk-btn vk-compact" data-key="Tab">Tab</button>
      <button class="vk-btn vk-compact" data-key="ArrowUp">↑</button>
      <button class="vk-btn vk-compact" data-key="ArrowDown">↓</button>
    `;
    termPage.appendChild(this._compactToolbar);

    // Event delegation for toolbar buttons
    const handleToolbarClick = (e) => {
      const btn = e.target.closest("[data-key], [data-modifier], [data-action]");
      if (!btn) return;
      e.preventDefault();
      e.stopPropagation();

      if (btn.dataset.key) {
        const seq = KEY_SEQUENCES[btn.dataset.key];
        if (seq) {
          // If ctrl is active, apply to the key
          let data = seq;
          if (this._ctrlActive && seq.length === 1) {
            data = String.fromCharCode(seq.charCodeAt(0) & 0x1f);
            this._ctrlActive = false;
            this._updateModifierUI();
          }
          if (this._altActive) {
            data = "\x1b" + data;
            this._altActive = false;
            this._updateModifierUI();
          }
          this._sendInput(data);
        }
      } else if (btn.dataset.modifier === "ctrl") {
        this._ctrlActive = !this._ctrlActive;
        this._updateModifierUI();
      } else if (btn.dataset.modifier === "alt") {
        this._altActive = !this._altActive;
        this._updateModifierUI();
      } else if (btn.dataset.action === "paste") {
        this._pasteFromClipboard();
      } else if (btn.dataset.action === "toggle-extended") {
        this._toggleExtendedKeys();
      }
    };

    this._toolbar.addEventListener("pointerdown", handleToolbarClick);
    this._compactToolbar.addEventListener("pointerdown", handleToolbarClick);
  },

  _updateModifierUI() {
    const allCtrl = document.querySelectorAll('[data-modifier="ctrl"]');
    const allAlt = document.querySelectorAll('[data-modifier="alt"]');
    allCtrl.forEach((btn) => btn.classList.toggle("vk-active", this._ctrlActive));
    allAlt.forEach((btn) => btn.classList.toggle("vk-active", this._altActive));
  },

  _toggleExtendedKeys() {
    const extended = this._toolbar?.querySelector(".vk-extended-row");
    const chevron = this._toolbar?.querySelector(".vk-expand-chevron");
    if (extended) {
      extended.classList.toggle("vk-hidden");
      if (chevron) {
        chevron.textContent = extended.classList.contains("vk-hidden") ? "▲" : "▼";
      }
    }
  },

  _sendInput(data) {
    if (this.channel) {
      this.channel.push("input", { data });
    }
  },

  // --- Paste from clipboard ---
  _pasteFromClipboard() {
    if (!navigator.clipboard || !navigator.clipboard.readText) {
      // Show a brief message if clipboard API is unavailable
      this.term?.write("\r\n\x1b[33m[Clipboard requires HTTPS or localhost]\x1b[0m\r\n");
      return;
    }
    navigator.clipboard.readText().then((text) => {
      if (text && this.channel) {
        this.channel.push("input", { data: text });
      }
    }).catch(() => {
      // Permission denied or other error — silently ignore
    });
  },

  // --- Soft Keyboard Handling ---
  _setupSoftKeyboard() {
    if (!isMobile()) return;

    this._keyboardOpen = false;

    if (window.visualViewport) {
      this._onViewportResize = () => {
        const heightRatio = window.visualViewport.height / window.innerHeight;
        const wasOpen = this._keyboardOpen;
        this._keyboardOpen = heightRatio < 0.75;

        if (this._keyboardOpen !== wasOpen) {
          if (this._keyboardOpen) {
            // Keyboard opened: show compact toolbar, hide full toolbar
            this._toolbar?.classList.add("vk-hidden");
            this._compactToolbar?.classList.remove("vk-hidden");
            // Shrink terminal to fit
            this.el.style.maxHeight = `${window.visualViewport.height - 90}px`;
          } else {
            // Keyboard closed: show full toolbar, hide compact
            this._toolbar?.classList.remove("vk-hidden");
            this._compactToolbar?.classList.add("vk-hidden");
            this.el.style.maxHeight = "";
          }
          // Refit terminal after layout change
          setTimeout(() => this.fitAddon?.fit(), 100);
        }
      };
      window.visualViewport.addEventListener("resize", this._onViewportResize);
    }

    // Tap terminal area to focus (opens soft keyboard)
    this.el.addEventListener("touchstart", () => {
      this.term?.focus();
    }, { passive: true });
  },

  // --- Touch Gestures ---
  _setupTouchGestures() {
    if (!isMobile() && !isTablet()) return;

    // Two-finger pinch to zoom (font size)
    this._initialPinchDistance = null;
    this._initialFontSize = null;

    this.el.addEventListener("touchstart", (e) => {
      if (e.touches.length === 2) {
        e.preventDefault();
        const dx = e.touches[0].clientX - e.touches[1].clientX;
        const dy = e.touches[0].clientY - e.touches[1].clientY;
        this._initialPinchDistance = Math.sqrt(dx * dx + dy * dy);
        this._initialFontSize = this.term?.options.fontSize || 14;
      }
    }, { passive: false });

    this.el.addEventListener("touchmove", (e) => {
      if (e.touches.length === 2 && this._initialPinchDistance) {
        e.preventDefault();
        const dx = e.touches[0].clientX - e.touches[1].clientX;
        const dy = e.touches[0].clientY - e.touches[1].clientY;
        const dist = Math.sqrt(dx * dx + dy * dy);
        const scale = dist / this._initialPinchDistance;
        const newSize = Math.round(Math.min(Math.max(this._initialFontSize * scale, 8), 32));
        if (this.term && newSize !== this.term.options.fontSize) {
          this.term.options.fontSize = newSize;
          this.fitAddon?.fit();
        }
      }
    }, { passive: false });

    this.el.addEventListener("touchend", (e) => {
      if (this._initialPinchDistance && e.touches.length < 2) {
        // Save final font size preference
        if (this.term) {
          savePref("fontSize", this.term.options.fontSize);
        }
        this._initialPinchDistance = null;
        this._initialFontSize = null;
      }
    }, { passive: true });

    // Swipe from left edge → navigate back to session list
    this._swipeStartX = null;
    this._swipeStartY = null;

    document.addEventListener("touchstart", (e) => {
      if (e.touches.length === 1 && e.touches[0].clientX < 20) {
        this._swipeStartX = e.touches[0].clientX;
        this._swipeStartY = e.touches[0].clientY;
      }
    }, { passive: true });

    document.addEventListener("touchend", (e) => {
      if (this._swipeStartX !== null && e.changedTouches.length === 1) {
        const dx = e.changedTouches[0].clientX - this._swipeStartX;
        const dy = Math.abs(e.changedTouches[0].clientY - this._swipeStartY);
        // Swipe right from left edge: at least 80px horizontal, less than 50px vertical
        if (dx > 80 && dy < 50) {
          window.history.back();
        }
      }
      this._swipeStartX = null;
      this._swipeStartY = null;
    }, { passive: true });
  },

  // --- Auto-Hiding Header ---
  _setupAutoHidingHeader() {
    if (!isMobile()) return;

    const header = document.querySelector(".terminal-header");
    const actionBar = document.querySelector(".terminal-action-bar");
    if (!header) return;

    this._headerHideTimer = null;
    this._headerVisible = true;

    const showHeader = () => {
      header.classList.remove("-translate-y-full");
      header.classList.add("translate-y-0");
      if (actionBar) {
        actionBar.classList.remove("-translate-y-full", "opacity-0");
        actionBar.classList.add("translate-y-0", "opacity-100");
      }
      this._headerVisible = true;
      clearTimeout(this._headerHideTimer);
      this._headerHideTimer = setTimeout(() => hideHeader(), 3000);
    };

    const hideHeader = () => {
      header.classList.remove("translate-y-0");
      header.classList.add("-translate-y-full");
      if (actionBar) {
        actionBar.classList.remove("translate-y-0", "opacity-100");
        actionBar.classList.add("-translate-y-full", "opacity-0");
      }
      this._headerVisible = false;
    };

    // Start hide timer
    this._headerHideTimer = setTimeout(() => hideHeader(), 3000);

    // Tap top edge to reveal
    document.addEventListener("touchstart", (e) => {
      if (e.touches[0].clientY < 20 && !this._headerVisible) {
        showHeader();
      }
    }, { passive: true });

    // Any interaction with header resets timer
    header.addEventListener("touchstart", () => {
      clearTimeout(this._headerHideTimer);
      this._headerHideTimer = setTimeout(() => hideHeader(), 3000);
    }, { passive: true });

    this._showHeader = showHeader;
    this._hideHeader = hideHeader;
  },

  _connectChannel(target) {
    // Get channel token from meta tag
    const tokenMeta = document.querySelector("meta[name='channel-token']");
    const token = tokenMeta ? tokenMeta.content : "";

    // Convert target "session:window.pane" to topic "terminal:session:window:pane"
    const topic =
      "terminal:" + target.replace(/\./, ":").replace(/^([^:]+):/, "$1:");

    // Use existing socket or create one
    if (!window.userSocket) {
      window.userSocket = new Socket("/socket", { params: { token } });
      window.userSocket.connect();
    }

    this.channel = window.userSocket.channel(topic, {});
    this.channel
      .join()
      .receive("ok", (reply) => {
        // Write history from join reply (base64 encoded)
        if (reply.history) {
          const historyBytes = Uint8Array.from(atob(reply.history), (c) =>
            c.charCodeAt(0)
          );
          this.term.write(historyBytes);
        }
      })
      .receive("error", (reason) => {
        this.term.write(
          `\r\n\x1b[31mFailed to connect: ${reason.reason || "unknown"}\x1b[0m\r\n`
        );
      });

    // Output from server
    this.channel.on("output", (msg) => {
      if (msg.data) {
        const bytes = Uint8Array.from(atob(msg.data), (c) =>
          c.charCodeAt(0)
        );
        this.term.write(bytes);
      }
    });

    // Reconnected — reset and write fresh history
    this.channel.on("reconnected", (msg) => {
      this.term.reset();
      if (msg.data) {
        const bytes = Uint8Array.from(atob(msg.data), (c) =>
          c.charCodeAt(0)
        );
        this.term.write(bytes);
      }
    });

    // Pane died
    this.channel.on("pane_dead", () => {
      this.term.write("\r\n\x1b[33m[Session ended]\x1b[0m\r\n");
    });

    // Pane superseded
    this.channel.on("superseded", (_msg) => {
      // LiveView handles navigation
    });
  },

  _flushInput() {
    if (this._inputBuffer.length === 0) return;

    const combined = this._inputBuffer.join("");
    this._inputBuffer = [];

    if (this.channel) {
      this.channel.push("input", { data: combined });
    }
  },

  destroyed() {
    if (this.channel) {
      this.channel.leave();
      this.channel = null;
    }
    if (this._resizeObserver) {
      this._resizeObserver.disconnect();
    }
    if (this._resizeTimer) {
      clearTimeout(this._resizeTimer);
    }
    if (this._inputTimer) {
      cancelAnimationFrame(this._inputTimer);
    }
    if (this._headerHideTimer) {
      clearTimeout(this._headerHideTimer);
    }
    if (this._onViewportResize && window.visualViewport) {
      window.visualViewport.removeEventListener("resize", this._onViewportResize);
    }
    // Remove toolbar elements
    this._toolbar?.remove();
    this._compactToolbar?.remove();

    if (this.term) {
      this.term.dispose();
      this.term = null;
    }
  },
};

export { TerminalHook };
