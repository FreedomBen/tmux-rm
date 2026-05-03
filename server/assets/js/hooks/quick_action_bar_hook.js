// Toggles `data-fade-left` / `data-fade-right` on the Quick Action Bar
// based on its current scroll position so the matching CSS mask-image
// reveals only the edges that have more pills to scroll into.
export const QuickActionBarHook = {
  mounted() {
    this._update = () => {
      const el = this.el;
      const left = el.scrollLeft > 0;
      const right = el.scrollLeft + el.clientWidth < el.scrollWidth - 1;
      el.dataset.fadeLeft = left ? "true" : "false";
      el.dataset.fadeRight = right ? "true" : "false";
    };
    this._update();
    this.el.addEventListener("scroll", this._update, { passive: true });
    this._resizeObserver = new ResizeObserver(this._update);
    this._resizeObserver.observe(this.el);
  },
  updated() {
    if (this._update) this._update();
  },
  destroyed() {
    if (this._resizeObserver) this._resizeObserver.disconnect();
    if (this._update) this.el.removeEventListener("scroll", this._update);
  },
};
