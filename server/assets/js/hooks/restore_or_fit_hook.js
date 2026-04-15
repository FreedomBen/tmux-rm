// RestoreOrFitHook
//
// On the maximized-pane "Restore" button:
//   * Desktop/tablet (>= 640px): pushes "restore_pane" to exit the maximized
//     state and return the pane to its grid position.
//   * Mobile (< 640px): pushes "fit_pane_width" with the column count that
//     fits the viewport, so tmux shrinks the pane to match the screen width.
//
// The button uses this hook instead of phx-click so the decision happens
// on the client where viewport width and xterm cell metrics are known.

const RestoreOrFitHook = {
  mounted() {
    this._onClick = (e) => {
      e.preventDefault();
      const target = this.el.dataset.target;
      if (window.innerWidth < 640 && target) {
        const paneEl = document.getElementById(`pane-${target}`);
        const cols = paneEl?._termHook?.viewportFitCols?.();
        if (cols) {
          this.pushEvent("fit_pane_width", { target, cols });
          return;
        }
        // Fall through to restore if we couldn't measure the terminal.
      }
      this.pushEvent("restore_pane", {});
    };
    this.el.addEventListener("click", this._onClick);
  },

  destroyed() {
    if (this._onClick) {
      this.el.removeEventListener("click", this._onClick);
    }
  },
};

export { RestoreOrFitHook };
