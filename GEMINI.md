# FTI PC Inventory Tool - Development Guidelines & Safety Guardrails

## 1. Embedded Web UI & JavaScript Invariants
* **Zero Syntax Errors**: All JavaScript in `src/web/index.html` runs directly in the embedded Edge/WebView2 client without a bundler or Babel transpile step.
* **No Duplicate Declarations**: Never redeclare variables with `let` or `const` at script scope (e.g. duplicate `let timer`, `let isScanning`).
* **Pre-Build Headless Syntax Verification**: Before releasing or rebuilding `dist/FTI_PC_Inventory.exe`, always verify that the embedded `<script>` parses with zero `SyntaxError` by executing an automated headless browser check.
* **Visual Error Banner**: Keep the global `window.addEventListener('error')` banner in `src/web/index.html` active to immediately display any runtime errors on-screen instead of silently freezing.
* **Responsive Layout & Viewport Resilience**:
  * **No Hard-Coded Desktop Assumptions**: The main workspace width fluctuates dynamically between ~400px and 1920px depending on window size and sidebar toggles.
  * **Grid Column Safety**: Always use `minmax(0, 1fr)` instead of raw `1fr` to prevent min-content blowout and horizontal text collisions.
  * **Container Query Adaptation**: Multi-zone headers and strips (such as `.scan-strip`) must define `container-type: inline-size` and provide `@container` rules to collapse spacing, scale fonts, or transition from a 1-row layout to a 2-tier stacked layout at narrow widths (< 750px) without content collision.

## 2. Build Pipeline Integrity
* **Fail-Fast Build**: `build.ps1` must validate source scripts and HTML syntax integrity before compiling the native executable. If a syntax error is detected, the build must abort immediately with a descriptive error.
* **UTF-8 Encoding Without BOM**: All PowerShell (`.ps1`) and Web (`.html`, `.css`, `.js`) files must maintain UTF-8 without BOM encoding to prevent character corruption and parser errors.
* **Digital Signature**: Executable builds must be Authenticode signed (SHA256) and verified with `Get-AuthenticodeSignature`.
* **Post-Build Git Push**: Every time a successful build or release of `dist/FTI_PC_Inventory.exe` is completed, automatically stage all modified files, commit with a concise descriptive message including the build version, and push to GitHub (`git push origin main`).
