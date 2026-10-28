# FTI PC Inventory Tool - Development Guidelines & Safety Guardrails

## 1. Embedded Web UI & JavaScript Invariants
* **Zero Syntax Errors**: All JavaScript in `src/web/index.html` runs directly in the embedded Edge/WebView2 client without a bundler or Babel transpile step.
* **No Duplicate Declarations**: Never redeclare variables with `let` or `const` at script scope (e.g. duplicate `let timer`, `let isScanning`).
* **Pre-Build Headless Syntax Verification**: Before releasing or rebuilding `dist/FTI_PC_Inventory.exe`, always verify that the embedded `<script>` parses with zero `SyntaxError` by executing an automated headless browser check.
* **Visual Error Banner**: Keep the global `window.addEventListener('error')` banner in `src/web/index.html` active to immediately display any runtime errors on-screen instead of silently freezing.

## 2. Build Pipeline Integrity
* **Fail-Fast Build**: `build.ps1` must validate source scripts and HTML syntax integrity before compiling the native executable. If a syntax error is detected, the build must abort immediately with a descriptive error.
* **UTF-8 Encoding Without BOM**: All PowerShell (`.ps1`) and Web (`.html`, `.css`, `.js`) files must maintain UTF-8 without BOM encoding to prevent character corruption and parser errors.
* **Digital Signature**: Executable builds must be Authenticode signed (SHA256) and verified with `Get-AuthenticodeSignature`.

