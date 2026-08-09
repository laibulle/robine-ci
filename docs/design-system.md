# Robine web design system

Robine uses Tailwind CSS 4 and daisyUI, with a small semantic token layer in `assets/css/app.css`. Product components MUST use semantic intent rather than binding behavior to a light- or dark-theme palette.

## Tokens

| Intent | Tailwind token | Source |
|---|---|---|
| Primary surface | `surface` | daisyUI `base-100` |
| Muted surface | `surface-muted` | daisyUI `base-200` |
| Subtle boundary | `border-subtle` | daisyUI `base-300` |
| Default content | `content` | daisyUI `base-content` |
| Primary action | `action` / `action-content` | daisyUI `primary` pair |
| Positive outcome | `positive` | daisyUI `success` |
| Warning or interruption | `caution` | daisyUI `warning` |
| Failure or destructive action | `negative` | daisyUI `error` |
| Active/informational state | `informative` | daisyUI `info` |
| Controls and panels | `rounded-control` / `rounded-panel` | shared radius scale |
| Elevated panel | `shadow-panel` | theme-aware content color |
| Page and section rhythm | `px-page-x` / `gap-section` | shared spacing scale |

The light and dark daisyUI themes are the palette implementations. New product code should not introduce raw hex, RGB, or OKLCH colors outside those theme definitions.

## Component contracts

- Buttons and links use the shared `button/1` component or daisyUI `btn` variants and retain a visible global `:focus-visible` outline.
- Form controls have a programmatically associated label. Validation text is visible, uses the error semantic color, and is never represented by color alone.
- `status_badge/1` owns execution-state colors and always renders the state as text plus a decorative marker.
- Flash and degraded/error callouts use `role="alert"`; non-urgent success or progress messages use `role="status"` or an `aria-live="polite"` container.
- Tables use real `table`, `thead`, `th`, and `tbody` semantics. Horizontal overflow belongs to a labelled surrounding region when content exceeds the viewport.
- Empty states name the missing resource and provide the next available action. Loading, disconnected, degraded, and retrying states use plain language and never expose internal exception terms.

`ui_state/1` is the state boundary for empty, loading, degraded, and error content. Empty means a successful read with no records. Error means the requested local data could not be read. Degraded means an optional external capability failed while durable local behavior remains usable. Loading sets `aria-busy`; LiveView navigation also toggles `aria-busy` on the main region and announces completion. The layout owns disconnected and server-error recovery notices so every LiveView receives the same reconnect behavior.

## Accessibility baseline

Every interactive control MUST be keyboard reachable and have an accessible name. Icons that repeat adjacent text are hidden from assistive technology. Information cannot depend on color alone. Motion is reduced to effectively zero when the operating system requests reduced motion. Page headings remain hierarchical, and destructive actions require explicit confirmation.

Before release, representative setup, repository, pipeline, job-log, and administration pages are checked at 200% zoom, narrow viewport, light/dark themes, keyboard-only navigation, and with automated WCAG 2.2 AA checks.
