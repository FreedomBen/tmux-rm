# Phase 10: User Preferences

## Goal
Implement client-side user preferences for terminal display settings (font size, font family, color theme, cursor style, cursor blink, scrollback limit, virtual toolbar visibility). All settings stored in `localStorage` — no server involvement.

## Dependencies
- Phase 5 complete (terminal view with xterm.js)
- Phase 9 complete (virtual toolbar)

## Steps

### 10.1 Preference Schema

| Setting | Options | Default | Storage Key |
|---------|---------|---------|-------------|
| Font size | 8-24px, or "fit to screen" | 14px | `rca-preferences.fontSize` |
| Font family | Monospace font selection | `"monospace"` | `rca-preferences.fontFamily` |
| Color theme | Dark, light, solarized, custom | Dark (xterm.js default) | `rca-preferences.theme` |
| Cursor style | Block, underline, bar | Block | `rca-preferences.cursorStyle` |
| Cursor blink | On/off | On | `rca-preferences.cursorBlink` |
| Scrollback limit | 1k-100k lines | 10000 | `rca-preferences.scrollback` |
| Virtual toolbar | Show/hide, key selection | Show | `rca-preferences.showToolbar` |

Note: scrollback here is the xterm.js client-side buffer (how many lines the browser retains for scroll-up). Independent of server-side ring buffer and tmux `history-limit`.

### 10.2 Preference Loading in TerminalHook

Update `terminal_hook.js` — load preferences before creating Terminal:

```javascript
const DEFAULTS = {
  fontSize: 14,
  fontFamily: 'monospace',
  theme: {},  // xterm.js default dark theme
  cursorStyle: 'block',
  cursorBlink: true,
  scrollback: 10000,
  showToolbar: true,
};

function loadPrefs() {
  try {
    const saved = JSON.parse(localStorage.getItem('rca-preferences') || '{}');
    return { ...DEFAULTS, ...saved };
  } catch {
    return DEFAULTS;
  }
}

function savePrefs(prefs) {
  localStorage.setItem('rca-preferences', JSON.stringify(prefs));
}
```

Apply on terminal creation:
```javascript
const prefs = loadPrefs();
const term = new Terminal({
  fontSize: prefs.fontSize,
  fontFamily: prefs.fontFamily,
  theme: prefs.theme,
  cursorStyle: prefs.cursorStyle,
  cursorBlink: prefs.cursorBlink,
  scrollback: prefs.scrollback,
});
```

### 10.3 Settings Panel (Client-Side Preferences Section)

Add a preferences section to the Settings page (or a slide-out panel accessible from the gear icon in the terminal header):

- **Font size**: slider or number input (8-24px range), with live preview
- **Font family**: dropdown with common monospace fonts (monospace, Fira Code, JetBrains Mono, Source Code Pro, Courier New)
- **Color theme**: dropdown/cards showing preview swatches:
  - Dark (default xterm.js)
  - Light
  - Solarized Dark
  - Solarized Light
  - Custom (opens color picker for foreground, background, cursor, selection colors)
- **Cursor style**: radio buttons (Block, Underline, Bar) with visual preview
- **Cursor blink**: toggle switch
- **Scrollback limit**: dropdown (1k, 5k, 10k, 25k, 50k, 100k)
- **Virtual toolbar**: toggle show/hide

All changes apply immediately to the terminal (no save button needed — auto-save to localStorage on change).

### 10.4 Live Preview

When the settings panel is open and the terminal is visible:
- Font size changes: `term.options.fontSize = newSize; fitAddon.fit();`
- Font family changes: `term.options.fontFamily = newFamily; fitAddon.fit();`
- Theme changes: `term.options.theme = newTheme;`
- Cursor changes: `term.options.cursorStyle = newStyle; term.options.cursorBlink = newBlink;`
- Scrollback changes: applied on next terminal creation (can't change live — note this in UI)

### 10.5 Theme Definitions

Pre-built theme objects:

```javascript
const THEMES = {
  dark: {}, // xterm.js default
  light: {
    foreground: '#333333',
    background: '#ffffff',
    cursor: '#333333',
    selectionBackground: '#add6ff',
  },
  solarizedDark: {
    foreground: '#839496',
    background: '#002b36',
    cursor: '#839496',
    selectionBackground: '#073642',
    // ... full solarized palette
  },
  solarizedLight: {
    foreground: '#657b83',
    background: '#fdf6e3',
    cursor: '#657b83',
    selectionBackground: '#eee8d5',
  },
};
```

### 10.6 Per-Device Behavior

Since preferences are in `localStorage`:
- Mobile and desktop naturally have different settings
- No server sync needed
- Clearing browser data resets to defaults (acceptable trade-off)

### 10.7 Pinch-to-Zoom Integration

Update the two-finger pinch handler (from Phase 9) to persist the font size:
```javascript
// On pinch end:
savePrefs({ ...loadPrefs(), fontSize: currentFontSize });
```

### 10.8 Implementation Approach

The preferences UI can be implemented as:
1. **LiveView + JS interop**: Settings page is a LiveView, but preference changes are handled client-side via a JS hook that reads/writes localStorage and updates xterm.js options
2. **Pure client-side panel**: A JS-rendered slide-out panel (no LiveView involvement) triggered by the gear icon. Simpler since no server interaction is needed.

Recommend option 2 for simplicity — this is purely a client feature.

## Files Created/Modified
```
assets/js/hooks/terminal_hook.js (update — preference loading/saving)
assets/js/preferences.js (new — preference management, theme definitions)
assets/js/preferences_panel.js (new — settings panel UI)
assets/css/app.css (update — settings panel styles)
lib/remote_code_agents_web/live/terminal_live.html.heex (update — gear icon trigger)
```

## Exit Criteria
- Terminal loads with user's saved preferences (font, theme, cursor)
- Settings panel accessible from gear icon
- Font size slider changes terminal font live
- Theme selector applies immediately with visual preview
- Cursor style/blink toggleable
- All preferences persist across page reloads (localStorage)
- Mobile and desktop can have different settings independently
- Pinch-to-zoom persists the font size change
- Scrollback limit applied correctly
- Virtual toolbar show/hide preference works
