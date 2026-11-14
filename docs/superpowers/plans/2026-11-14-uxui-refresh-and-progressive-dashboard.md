# FTI PC Inventory Tool — UX/UI Refresh & Progressive Dashboard Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all critical responsive/layout overflow bugs (`1440px`, `750px`, `420px`), restore Light/Dark theme contrast on Dashboard, make Donut legend swatches visible, switch Dashboard defaults to broad high-level categories (`Series` / OS Family) with on-demand drilldown to details, and polish typography (`tabular-nums`), copyability (`user-select: text`), and keyboard accessibility (`:focus-visible` + `Escape` modal dismissal).

**Architecture:** All UI changes live in `src/web/index.html` (embedded Vanilla HTML5/CSS3/JS served in Edge/WebView2 with zero bundler). Changes are purely surgical CSS, markup, and lightweight JS state/render refinements that preserve all existing DOM IDs, API contracts (`X-FTI-Token`), and `data-*` event delegation. Verification runs via Node.js `<script>` AST parsing and headless Edge (`msedge.exe`) multi-viewport DOM/bounding-rect layout assertions at `1440px`, `750px`, and `420px`.

**Tech Stack:** HTML5, CSS3 (`@container`, `@media`, CSS Grid `minmax(min(100%, ...), 1fr)`, CSS Custom Properties), Vanilla JS (ES6+), Headless Chromium (`msedge.exe`), `build.ps1`.

**Spec:** Open Design Critique & Design Taste Audit (2026-11-14) + User Request (Approach A + Broad-first Dashboard defaults).

## Global Constraints

- **Zero Syntax Errors (`GEMINI.md`):** Every `<script>` block in `src/web/index.html` must parse cleanly via Node `new Function(...)` and headless Edge without triggering `#fatalJsBanner`.
- **No Duplicate Declarations (`GEMINI.md`):** Never redeclare `let` or `const` variables at script scope.
- **UTF-8 Without BOM (`GEMINI.md`):** `src/web/index.html` must maintain UTF-8 without BOM.
- **Responsive Viewport Resilience (`GEMINI.md`):** Zero horizontal page overflow (`scrollWidth <= clientWidth`) and zero clipped/colliding controls across `420px`, `750px`, and `1440px`.
- **Preserve All Functional Contracts:** Keep all existing element IDs, `X-FTI-Token` auth wrapper, `data-drill-type` delegation, and `build.ps1` staging intact.

## Review Focus

- **Light vs. Dark Mode Parity:** Default `html.light` mode must have crisp, WCAG-readable contrast on `.dash-kpi-card`, `.dash-seg-toggle`, `.dash-bar-track`, `.dash-unscanned-footer`, and `.kpi-sub-pill.off` (no white-on-light or pale-gray-on-light text).
- **Both Sidebars Open at `1440px` & Narrow `< 1024px`:** `.table-toolbar` must wrap cleanly instead of clipping at `1440px`, and sidebars must auto-collapse cleanly below `1024px` so `.main-workspace` is never crushed to `28px`.
- **Broad-First Dashboard Defaults:** Startup Dashboard CPU card must default to **`Series`** (`Intel Core i5`, `Intel Core i7`, `Intel Core Ultra`, `Apple MacBook`, etc.) and OS card to broad OS versions, while clicking `Exact Model` / `Build` or clicking any chart item reveals exact details on demand.
- **Donut Swatches & `tabular-nums`:** Donut legend dots (`.dash-donut-legend-dot`) must render with non-zero size (`10px x 10px`) and matching slice colors; numeric/timer/IP cells must not jitter.
- **Copyability & Keyboard Navigation:** Users must be able to highlight/copy IP/PCName/logs (`user-select: text`), close any active modal with `Escape`, and see `:focus-visible` rings when tabbing.

---

### Task 1: Fix Responsive Layout, Sidebars Auto-Collapse & Table Toolbar Wrapping

**Files:**
- Modify: `src/web/index.html` (CSS around `.top-header`, `.app-body`/sidebars, `.table-toolbar`, `.dash-grid-2`, `.dash-grid-3`; HTML `#filterPillsHw` removal/consolidation & `colspan="14"`)

**Interfaces:**
- Preserves: `#resultsTable`, `#tableBody`, `#btnToggleSidebar`, `#btnToggleSidebarRight`, `.scan-strip-kpis` status filtering.

- [ ] **Step 1: Fix `.table-toolbar` wrapping and remove duplicate `#filterPillsHw`**

Inspect `src/web/index.html` around lines `1705-1755` and `4624-4700`:
- Add `flex-wrap: wrap; gap: 8px;` (or `container-type: inline-size` + `@container`) on `.table-toolbar` and `.table-actions-wrap` so controls never clip at `850px` (`1440px` with sidebars open).
- Remove the redundant `#filterPillsHw` container in `.table-toolbar` (since `.scan-strip-kpis` directly above already filters `all / ok / offline / error` — verify no JS throws if `#filterPillsHw` is removed by checking all references to `filterPillsHw` in `index.html`).
- Fix `#tableBody` initial empty row `<td colspan="13">` -> `<td colspan="14">` to match all 14 `<th>` columns.

- [ ] **Step 2: Add responsive auto-collapse for sidebars below `1024px` and wrap `.top-header` below `750px`**

- Add `@media (max-width: 1024px)` rules (and/or initial responsive check on load/resize) so `.left-sidebar` and `.right-drawer` collapse or behave as clean overlay drawers when viewport width `<= 1024px`, preventing `.main-workspace` from being crushed to `190px`/`28px`.
- Add `flex-wrap: wrap; min-width: 0;` on `.top-header` and compact secondary header badges below `750px` so `#topScheduleBanner` and right-side header buttons never collide or overflow.

- [ ] **Step 3: Fix Dashboard Grid `minmax` overflow `< 400px`**

Update `.dash-grid-2` (`grid-template-columns: repeat(auto-fit, minmax(min(100%, 320px), 1fr))`) and `.dash-grid-3` / `.dash-zone-kpis` (`minmax(min(100%, 240px), 1fr)`), ensuring `minmax(0, ...)` safety on all layout grids.

- [ ] **Step 4: Verify JS syntax and run headless Edge layout check**

Run Node syntax check on all `<script>` blocks and verify `src/web/index.html` has 0 errors.

- [ ] **Step 5: Commit**

```bash
git add src/web/index.html
git commit -m "fix(ui): resolve toolbar clipping, sidebar narrow-viewport crush, and grid overflow"
```

---

### Task 2: Fix Light/Dark Theme Contrast & Donut Legend Swatches on Dashboard

**Files:**
- Modify: `src/web/index.html` (CSS around lines `115-185`, `2208`, `3604-4103`)

**Interfaces:**
- Preserves: `html.light` / `:root` theme toggle and all `.dash-*` class names.

- [ ] **Step 1: Replace hardcoded dark-mode colors in Dashboard CSS (`lines 3604-4103`) with semantic theme tokens**

- Replace `rgba(255, 255, 255, 0.03–0.08)` on `.dash-ring-bg`, `.dash-bar-track`, `.dash-card-badge`, `.dash-watchlist-item`, `.dash-unscanned-footer:hover` with theme tokens (`var(--bg-track)`, `var(--bg-surface-elevated)`, `var(--border-subtle)`) + explicit `html.light` overrides where needed.
- Fix `.kpi-sub-pill.off` (`color: var(--text-secondary)` instead of `#cbd5e1`) and `.dash-seg-toggle` (`background: var(--bg-surface-elevated)` instead of `rgba(0,0,0,0.25)`).
- Darken `html.light` `--text-muted` slightly (e.g. `#475569`) so `0.67rem–0.75rem` muted labels meet readable contrast on `#e8eef5` / `#ffffff`.

- [ ] **Step 2: Fix `.dash-donut-legend-dot` invisible swatches**

Inspect line `2208` (`.dash-donut-legend-color`) vs JS lines `6157-6159` (`.dash-donut-legend-dot`, `.dash-donut-legend-label`, `.dash-donut-legend-val`).
Add/alias `.dash-donut-legend-dot` (`width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0; display: inline-block;`), `.dash-donut-legend-label` (`flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;`), and `.dash-donut-legend-val` (`font-variant-numeric: tabular-nums; flex-shrink: 0; font-weight: 600;`).

- [ ] **Step 3: Verify syntax & commit**

```bash
git add src/web/index.html
git commit -m "fix(ui): restore light-theme dashboard contrast and donut legend color swatches"
```

---

### Task 3: Broad-First Dashboard Defaults (Progressive Disclosure) & Visual Hierarchy

**Files:**
- Modify: `src/web/index.html` (HTML CPU toggle buttons, JS `cpuViewMode`, `classifyOs` `'ver'` vs `'build'`, chart mode SVG icons, Dashboard empty state)

**Interfaces:**
- Modifies: `cpuViewMode` default (`'series'` instead of `'model'`), CPU toggle button active state (`Series` active by default, `Exact Model` secondary).

- [ ] **Step 1: Set CPU Breakdown default to `Series` (broad overview) with `Exact Model` on demand**

- In HTML (`#btnCpuModeSeries` / `#btnCpuModeModel`): place `Series` first with `class="dash-seg-btn active"` and `Exact Model` second (`class="dash-seg-btn"`).
- In JS: set `let cpuViewMode = 'series'; // 'series' | 'model'`.
- Verify `applyDashboardDrilldown` and `filterData` handle `cpuSeries` (`Intel Core Ultra`, `Intel Core i9`, `Intel Core i7`, `Intel Core i5`, `Intel Core i3`, `Apple MacBook`, etc.) and `cpuModel` cleanly!

- [ ] **Step 2: Make OS Version mode (`osViewMode = 'ver'`) concise & broad by default (`Windows 11`, `Windows 10`, `macOS`, `Windows Server`), keeping Build details in `Build` mode**

- In `classifyOs(os, osBuild, mode = osViewMode)`:
  - When `mode === 'ver'` (default): group cleanly into broad OS versions (`Windows 11`, `Windows 10`, `Windows Server`, `macOS`, `Linux`, `Legacy Windows`) without long `(24H2 • Build 26100)` suffixes cluttering the broad overview.
  - When `mode === 'build'` (user clicks `Build` toggle): show exact feature update & build (`Build 26100 (Win 11 24H2)`, etc.).

- [ ] **Step 3: Replace mixed emoji/glyph chart mode icons (`📊`) with crisp inline SVGs & polish empty state**

- Update `getChartToolsHtml(cardKey)` to use clean `13x13` inline SVG icons for `bar`, `donut`, `col`, `treemap` instead of mixing `📊` emoji with Unicode glyphs.
- Replace inline `style="width:26px;height:26px;"` on icon buttons with a `.btn-icon-sm` CSS class.

- [ ] **Step 4: Verify JS syntax & commit**

```bash
git add src/web/index.html
git commit -m "feat(dashboard): default to broad CPU series & OS family with on-demand detail toggles"
```

---

### Task 4: Typography (`tabular-nums`), Copyability (`user-select: text`), Keyboard Accessibility & Browser Verification

**Files:**
- Modify: `src/web/index.html` (CSS `tabular-nums`, `user-select: text`, `:focus-visible`, JS `Escape` modal listener + backdrop click)

**Interfaces:**
- Preserves: Existing modal open/close buttons (`masterModalBackdrop`, `schedModalBackdrop`, `pcSwModalBackdrop`, `fsModalBackdrop`, `confirmModalBackdrop`).

- [ ] **Step 1: Add `font-variant-numeric: tabular-nums` and `user-select: text`**

- Add `font-variant-numeric: tabular-nums;` to `.dash-kpi-val`, `.dash-bar-count`, `.dash-donut-total`, `.dash-col-val`, and numeric/IP/RAM/Disk/Date/Fails table cells.
- Add `user-select: text;` on `.live-grid td`, `.log-content-body`, and modal detail text so admins can copy PC names, IPs, builds, and logs.

- [ ] **Step 2: Add `:focus-visible` keyboard focus rings & global `Escape` modal dismissal**

- Add clear `:focus-visible` outline (`2px solid var(--accent-primary); outline-offset: 2px;`) for buttons, inputs, tabs, and interactive `.dash-*` items (removing bare `outline: none` without replacement).
- Add a global `keydown` listener for `Escape` that closes whichever `.modal-backdrop.active` is currently open, and ensure `masterModalBackdrop` and `schedModalBackdrop` close on backdrop click.

- [ ] **Step 3: Multi-Viewport Verification via Headless Edge (`1440px`, `750px`, `420px`) & Build**

Run:
1. Node `<script>` syntax verification (`new Function(...)` -> 0 errors).
2. Headless Edge / Playwright check across `1440x900`, `750x900`, and `420x800` verifying:
   - `document.documentElement.scrollWidth <= document.documentElement.clientWidth`
   - Zero `#fatalJsBanner` / zero console errors
   - `.table-toolbar` buttons not clipped at `1440px`
   - Sidebars auto-collapsed at `750px` and `420px`
   - Donut legend dots have non-zero bounding rect (`width > 0 && height > 0`)
   - Default CPU card renders `Series` active (`Intel Core i5`, etc.)
3. Run `powershell -ExecutionPolicy Bypass -File .\build.ps1` and verify `Get-AuthenticodeSignature .\dist\FTI_PC_Inventory.exe`.

- [ ] **Step 4: Commit & Push**

```bash
git add -A
git commit -m "feat(ui): complete UX/UI refresh, tabular-nums, accessibility, and browser verification"
git push origin main
```

