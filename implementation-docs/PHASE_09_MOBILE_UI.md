# Phase 9: Mobile UI & Virtual Key Toolbar

## Goal
Polish the mobile experience: virtual key toolbar for special keys, soft keyboard handling, touch gestures, responsive breakpoints, and mobile-specific terminal behavior (passive resize, auto-hiding header). After this phase, the app is fully usable on phone browsers.

## Dependencies
- Phase 5 complete (terminal view)
- Phase 8 complete (quick action bar)

## Steps

### 9.1 Virtual Key Toolbar

Fixed bottom toolbar providing keys that don't exist on mobile keyboards:

```
[ Esc ] [ Tab ] [ Ctrl ] [ Alt ] [ ↑ ] [ ↓ ] [ ← ] [ → ] [ Paste ]
```

**Implementation** (in `terminal_hook.js` or a separate component):
- Render as HTML buttons below the terminal container
- Each button emits the corresponding escape sequence / control code:
  - `Esc` → `\x1b`
  - `Tab` → `\x09`
  - `Ctrl` → sticky modifier (toggle active state, highlight when active)
  - `Alt` → sticky modifier
  - Arrow keys → ANSI escape sequences (`\x1b[A`, `\x1b[B`, `\x1b[C`, `\x1b[D`)
  - `Paste` → call `navigator.clipboard.readText()`, send as `"key_input"` event
- `Ctrl` + next key tap → bitwise AND with `0x1f` (e.g., Ctrl+C → `\x03`), then unstick Ctrl
- `Alt` + next key → prepend `\x1b` to the key sequence, then unstick Alt
- Swipe-up on toolbar reveals extended key row: `F1-F12`, `PgUp`, `PgDn`, `Home`, `End`

**Styling**:
- Dark theme buttons matching terminal aesthetic
- Min touch target 44px × 44px
- Horizontal scroll with momentum if all keys don't fit
- When soft keyboard is open: the full toolbar hides to save space, but a compact modifier row (Esc, Ctrl, Alt) remains visible above the keyboard so users can send Ctrl+C etc. without dismissing the keyboard first.

### 9.2 Soft Keyboard Handling

- Tapping terminal area opens device soft keyboard
- Use a hidden `<textarea>` overlay to capture mobile keyboard input, forward to xterm.js
- `visualViewport` API to detect soft keyboard open/close:
  ```javascript
  window.visualViewport.addEventListener('resize', () => {
    // When viewport height shrinks significantly → keyboard opened
    // Resize terminal, show compact modifier row, hide full toolbar
  });
  ```
- When soft keyboard open: terminal shrinks to fit above keyboard, full toolbar collapses to compact modifier row (Esc, Ctrl, Alt)
- When soft keyboard closes: terminal expands to full viewport, full toolbar reappears

### 9.3 Touch Gestures

- **Tap**: focus terminal (opens soft keyboard)
- **Long press**: text selection (native xterm.js behavior)
- **Two-finger pinch**: zoom/font size adjustment (CSS transform on terminal container). Save via `savePref('fontSize', newSize)` helper (see below). Phase 10 replaces this helper with the full preference system — the interface is the same.
- **Swipe from left edge**: back to session list (use browser back or custom gesture handler with `touchstart`/`touchmove` detection)

### 9.3a Preference Helper (Minimal)

Phase 9 introduces a minimal `savePref`/`loadPref` helper that Phase 10 later replaces with the full preference system. This avoids a circular dependency:

```javascript
// In terminal_hook.js (Phase 9 addition):
function savePref(key, value) {
  const prefs = JSON.parse(localStorage.getItem('rca-preferences') || '{}');
  prefs[key] = value;
  localStorage.setItem('rca-preferences', JSON.stringify(prefs));
}
function loadPref(key, defaultValue) {
  const prefs = JSON.parse(localStorage.getItem('rca-preferences') || '{}');
  return prefs[key] ?? defaultValue;
}
```

Phase 10 replaces these with `loadPrefs()`/`savePrefs()` from `preferences.js`. The localStorage key (`rca-preferences`) is the same, so Phase 9 preferences carry over seamlessly.

### 9.4 Auto-Hiding Header

- Header bar with session info and back button
- Auto-hides after 3 seconds of inactivity
- Tap top edge of screen (top 20px) to reveal
- CSS transition for smooth show/hide
- Quick action bar follows the header (both hide/show together on mobile)

Implementation:
```javascript
let hideTimer;
function showHeader() {
  header.classList.remove('translate-y-[-100%]');
  clearTimeout(hideTimer);
  hideTimer = setTimeout(() => {
    header.classList.add('translate-y-[-100%]');
  }, 3000);
}
// Touch listener on top edge
document.addEventListener('touchstart', (e) => {
  if (e.touches[0].clientY < 20) showHeader();
});
```

### 9.5 Mobile Terminal Resize Behavior

Mobile viewers are **passive resizers**:
- On connect, read pane dimensions from PaneStream subscribe response
- Set xterm.js to those dimensions
- Do NOT send resize events when mobile viewport changes
- Instead, scale terminal via CSS transform or font-size adjustment to fit the viewport
- Optional: "Fit to screen" button in settings/header that sends a resize matching the mobile viewport (with confirmation since it affects other viewers)
- When receiving `{:pane_resized, cols, rows}` from server: resize xterm.js to match

### 9.6 Responsive Layout Refinements

- `< 640px` (mobile):
  - Single column card list on session page
  - Full-viewport terminal with bottom toolbar
  - Quick action bar: horizontal scroll with snap
  - Header: auto-hiding with tap-to-reveal
  - Settings: full-screen panel

- `640px - 1024px` (tablet):
  - Sidebar session list + terminal split
  - Virtual toolbar optional (many tablets have keyboard cases)

- `> 1024px` (desktop):
  - Sidebar + terminal + optional status panel
  - No virtual toolbar (physical keyboard assumed)
  - Quick action bar always visible (no auto-hide)

### 9.7 Terminal Container Sizing

Use `100dvh` (dynamic viewport height) for the terminal page to properly account for mobile browser chrome (URL bar, bottom navigation):

```css
.terminal-page {
  height: 100dvh;
  display: flex;
  flex-direction: column;
}

.terminal-container {
  flex: 1;
  min-height: 0; /* Allow shrinking */
}
```

### 9.8 Paste Button (Mobile)

The "Paste" button in the virtual toolbar:
1. Calls `navigator.clipboard.readText()`
2. Encodes the text as UTF-8 bytes → base64
3. Sends as `"key_input"` event (same path as keyboard input)
4. Requires secure context (HTTPS or localhost)
5. If Clipboard API unavailable, show a toast explaining HTTPS requirement

### 9.9 Tests

- Test virtual toolbar renders on mobile viewport
- Test Ctrl/Alt sticky modifier behavior
- Test soft keyboard detection (mock `visualViewport`)
- Test auto-hiding header timing
- Test passive resize behavior (no resize event sent on viewport change)
- Visual regression tests at each breakpoint (if Wallaby E2E is set up)

## Files Created/Modified
```
assets/js/hooks/terminal_hook.js (update — keyboard handling, toolbar, gestures)
assets/css/app.css (update — mobile styles, breakpoints, toolbar, auto-hide)
lib/remote_code_agents_web/live/terminal_live.html.heex (update — toolbar markup)
lib/remote_code_agents_web/live/session_list_live.html.heex (update — mobile card layout)
lib/remote_code_agents_web/components/core_components.ex (update — mobile-friendly components)
```

## Exit Criteria
- Virtual key toolbar renders on mobile with Esc, Tab, Ctrl, Alt, arrows, Paste
- Ctrl/Alt sticky modifiers work (tap Ctrl, tap C → sends Ctrl+C)
- Extended keys (F1-F12, PgUp/PgDn) accessible via swipe-up
- Soft keyboard opens on terminal tap, toolbar hides when keyboard is open
- Auto-hiding header: hides after 3s, tap top edge to reveal
- Two-finger pinch adjusts font size
- Terminal uses `100dvh` and fills available space correctly
- Paste button reads clipboard and sends to terminal
- Mobile viewers don't send resize events on viewport change
- Session list is single-column with large touch targets on mobile
- All breakpoints (mobile/tablet/desktop) render correctly
