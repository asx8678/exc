"""Textual CSS theme for Code Puppy TUI.

Color palette matches the original Code Puppy CLI spirit:
  - Deep blue primary (deep_sky_blue4)
  - Muted purple secondary (medium_purple4)
  - Soft, desaturated accents — easy on the eyes
  - Black background, just like a terminal
"""

from textual.theme import Theme

# ---------------------------------------------------------------------------
# Custom theme — muted, eye-friendly palette on black
# ---------------------------------------------------------------------------

CODE_PUPPY_THEME = Theme(
    name="code-puppy",
    primary="#005faf",  # deep_sky_blue4 — the signature CLI blue
    secondary="#7878af",  # muted lavender — AI responses, previews
    accent="#6a9fb5",  # dusty steel blue — selections, highlights
    warning="#c0a36e",  # muted sand — warnings, token rate
    error="#b05070",  # soft rose — errors (not screaming pink)
    success="#87a987",  # sage green — success, agent name
    foreground="#b0b0b0",  # soft gray — readable, not harsh
    background="#000000",  # pure black — like the old terminal
    surface="#121212",  # barely lifted from black
    panel="#1c1c1c",  # subtle panel elevation
    dark=True,
    luminosity_spread=0.15,
    text_alpha=0.9,
)

# ---------------------------------------------------------------------------
# Shared CSS variables and component styles
# ---------------------------------------------------------------------------

APP_CSS = """
/* ============================================
   Code Puppy TUI Theme
   ============================================ */

/* Screen backgrounds */
Screen {
    background: $surface;
}

/* Split panel defaults */
SplitPanel {
    height: 1fr;
}

SplitPanel > .split-panel--left {
    width: 35%;
    min-width: 25;
    border-right: solid $primary;
}

SplitPanel > .split-panel--right {
    width: 1fr;
    padding: 1 2;
}

/* Searchable list */
SearchableList {
    height: 1fr;
}

SearchableList > Input {
    dock: top;
    margin: 0 1;
    height: 3;
}

SearchableList > ListView {
    height: 1fr;
}

/* List items */
.list-item {
    padding: 0 1;
    height: 1;
}

.list-item.--selected {
    background: $accent;
    color: $text;
    text-style: bold;
}

.list-item.--active {
    color: $success;
}

.list-item.--disabled {
    color: $text-muted;
    text-style: italic;
}

/* Navigation hints at bottom of panels */
.nav-hints {
    dock: bottom;
    height: auto;
    padding: 1;
    color: $text-muted;
    background: $surface;
    border-top: solid $primary;
}

/* Preview panel content */
.preview-title {
    text-style: bold;
    color: $secondary;
    padding-bottom: 1;
}

.preview-label {
    text-style: bold;
    padding-right: 1;
}

.preview-value {
    color: $accent;
}

.preview-dim {
    color: $text-muted;
}
"""


def get_banner_css() -> str:
    """Generate CSS classes for banner colors from current config.

    Reads the banner color configuration and generates CSS classes
    that match the existing Rich color names used throughout the app.
    """
    try:
        from code_puppy.config import get_all_banner_colors

        colors = get_all_banner_colors()
    except Exception:
        colors = {}

    css_lines = ["/* Banner color classes (from config) */"]
    for name, color in colors.items():
        safe_name = name.replace("_", "-")
        css_lines.append(
            f".banner-{safe_name} {{ background: {color}; color: white; text-style: bold; padding: 0 1; }}"
        )

    return "\n".join(css_lines)
