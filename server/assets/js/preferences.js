// Terminal display preference definitions and theme data.
// Settings are stored server-side in config.yaml, not localStorage.

const DEFAULTS = {
  fontSize: 14,
  fontFamily: "monospace",
  theme: "dark",
  customTheme: {},
  cursorStyle: "block",
  cursorBlink: true,
  showToolbar: true,
  mobileKeyboardEnabled: true,
  toolbarButtons: null,
};

const THEMES = {
  dark: {},
  light: {
    foreground: "#333333",
    background: "#ffffff",
    cursor: "#333333",
    cursorAccent: "#ffffff",
    selectionBackground: "#add6ff",
    selectionForeground: "#333333",
    black: "#000000",
    red: "#cd3131",
    green: "#00bc00",
    yellow: "#949800",
    blue: "#0451a5",
    magenta: "#bc05bc",
    cyan: "#0598bc",
    white: "#555555",
    brightBlack: "#666666",
    brightRed: "#cd3131",
    brightGreen: "#14ce14",
    brightYellow: "#b5ba00",
    brightBlue: "#0451a5",
    brightMagenta: "#bc05bc",
    brightCyan: "#0598bc",
    brightWhite: "#a5a5a5",
  },
  solarizedDark: {
    foreground: "#839496",
    background: "#002b36",
    cursor: "#839496",
    cursorAccent: "#002b36",
    selectionBackground: "#073642",
    selectionForeground: "#93a1a1",
    black: "#073642",
    red: "#dc322f",
    green: "#859900",
    yellow: "#b58900",
    blue: "#268bd2",
    magenta: "#d33682",
    cyan: "#2aa198",
    white: "#eee8d5",
    brightBlack: "#002b36",
    brightRed: "#cb4b16",
    brightGreen: "#586e75",
    brightYellow: "#657b83",
    brightBlue: "#839496",
    brightMagenta: "#6c71c4",
    brightCyan: "#93a1a1",
    brightWhite: "#fdf6e3",
  },
  solarizedLight: {
    foreground: "#657b83",
    background: "#fdf6e3",
    cursor: "#657b83",
    cursorAccent: "#fdf6e3",
    selectionBackground: "#eee8d5",
    selectionForeground: "#586e75",
    black: "#073642",
    red: "#dc322f",
    green: "#859900",
    yellow: "#b58900",
    blue: "#268bd2",
    magenta: "#d33682",
    cyan: "#2aa198",
    white: "#eee8d5",
    brightBlack: "#002b36",
    brightRed: "#cb4b16",
    brightGreen: "#586e75",
    brightYellow: "#657b83",
    brightBlue: "#839496",
    brightMagenta: "#6c71c4",
    brightCyan: "#93a1a1",
    brightWhite: "#fdf6e3",
  },
};

const FONT_FAMILIES = [
  { label: "System Monospace", value: "monospace" },
  { label: "Fira Code", value: "'Fira Code', monospace" },
  { label: "JetBrains Mono", value: "'JetBrains Mono', monospace" },
  { label: "Source Code Pro", value: "'Source Code Pro', monospace" },
  { label: "Courier New", value: "'Courier New', monospace" },
];

// Convert server config (snake_case) to local camelCase prefs
function serverToLocal(serverPrefs) {
  return {
    fontSize: serverPrefs.font_size ?? DEFAULTS.fontSize,
    fontFamily: serverPrefs.font_family ?? DEFAULTS.fontFamily,
    theme: serverPrefs.theme ?? DEFAULTS.theme,
    customTheme: serverPrefs.custom_theme ?? DEFAULTS.customTheme,
    cursorStyle: serverPrefs.cursor_style ?? DEFAULTS.cursorStyle,
    cursorBlink: serverPrefs.cursor_blink ?? DEFAULTS.cursorBlink,
    showToolbar: serverPrefs.show_toolbar ?? DEFAULTS.showToolbar,
    mobileKeyboardEnabled:
      serverPrefs.mobile_keyboard_enabled ?? DEFAULTS.mobileKeyboardEnabled,
    toolbarButtons: serverPrefs.toolbar_buttons ?? DEFAULTS.toolbarButtons,
  };
}

// Convert local camelCase prefs to server config (snake_case)
function localToServer(prefs) {
  const result = {
    font_size: prefs.fontSize,
    font_family: prefs.fontFamily,
    theme: prefs.theme,
    custom_theme: prefs.customTheme || {},
    cursor_style: prefs.cursorStyle,
    cursor_blink: prefs.cursorBlink,
    show_toolbar: prefs.showToolbar,
    mobile_keyboard_enabled: prefs.mobileKeyboardEnabled,
  };
  if (prefs.toolbarButtons) {
    result.toolbar_buttons = prefs.toolbarButtons;
  }
  return result;
}

function resolveTheme(prefs) {
  const themeName = prefs.theme || "dark";
  if (themeName === "custom") {
    return prefs.customTheme || {};
  }
  return THEMES[themeName] || {};
}

export {
  DEFAULTS,
  THEMES,
  FONT_FAMILIES,
  serverToLocal,
  localToServer,
  resolveTheme,
};
