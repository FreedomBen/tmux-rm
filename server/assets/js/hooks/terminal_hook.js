import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { Socket } from "phoenix";

const TerminalHook = {
  mounted() {
    const target = this.el.dataset.target;

    // Load preferences from localStorage
    const prefs = JSON.parse(localStorage.getItem("rca-preferences") || "{}");

    // Create xterm.js terminal
    this.term = new Terminal({
      fontSize: prefs.fontSize || 14,
      fontFamily: prefs.fontFamily || "monospace",
      cursorStyle: prefs.cursorStyle || "block",
      cursorBlink: prefs.cursorBlink !== false,
      scrollback: prefs.scrollback || 10000,
      theme: prefs.theme || {},
    });

    // Addons
    this.fitAddon = new FitAddon();
    this.term.loadAddon(this.fitAddon);
    this.term.loadAddon(new WebLinksAddon());

    // Open terminal in container
    this.term.open(this.el);
    this.fitAddon.fit();

    // Connect companion Channel for binary I/O
    this._connectChannel(target);

    // Send initial resize to server
    this.pushEvent("resize", { cols: this.term.cols, rows: this.term.rows });

    // Input handling: buffer keystrokes and flush periodically
    this._inputBuffer = [];
    this._inputTimer = null;
    this._encoder = new TextEncoder();

    this.term.onData((data) => {
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
        this.pushEvent("resize", {
          cols: this.term.cols,
          rows: this.term.rows,
        });
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
        navigator.clipboard.readText().then((text) => {
          if (text && this.channel) {
            this.channel.push("input", { data: text });
          }
        });
      }
    });
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
    this.channel.on("superseded", (msg) => {
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
    if (this.term) {
      this.term.dispose();
      this.term = null;
    }
  },
};

export { TerminalHook };
