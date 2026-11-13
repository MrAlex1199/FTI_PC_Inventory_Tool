# FTI PC Inventory Tool — Code Quality, Architecture & Security Remediation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate critical security vulnerabilities, fix broken runtime/path-handling bugs, harden concurrency/atomicity in the inventory engine and HTTP server, and improve build pipeline integrity across `AppServer.ps1`, `Program.cs`, `Get-PCInventory.Core.ps1`, `index.html`, and `build.ps1`.

**Architecture:** The tool runs as an elevated (`requireAdministrator`) native C# WinExe launcher (`Program.cs`) hosting an embedded PowerShell HTTP server (`AppServer.ps1`), an inventory engine (`Get-PCInventory.Core.ps1`), and a single-file Edge/WebView2 UI (`index.html`). Remediation preserves this zero-dependency deployment architecture while securing IPC/filesystem boundaries (per-session API token + Origin validation + admin-only ACL extraction dir), making Master CSV updates atomic via temp-file swap + named `Mutex`, parallelizing hardware scans via `RunspacePool`, and fixing XSS/escaping defects in the UI.

**Tech Stack:** C# (.NET Framework 4.x), PowerShell 5.1 (`System.Net.HttpListener`, `RunspacePool`, CIM/WMI), Embedded HTML5/CSS/Vanilla JS (WebView2), Node.js (headless verification), `csc.exe` + Authenticode (`build.ps1`).

**Spec:** Senior Code Review Findings (2026-11-13) & `GEMINI.md` invariants.

## Global Constraints

- **Zero Syntax Errors (`GEMINI.md`):** All JavaScript in `src/web/index.html` must parse with zero `SyntaxError` in a headless check before building `dist/FTI_PC_Inventory.exe`.
- **No Duplicate Declarations (`GEMINI.md`):** Never redeclare `let` or `const` variables at script scope in `src/web/index.html`.
- **Visual Error Banner (`GEMINI.md`):** Keep `window.addEventListener('error')` active in `src/web/index.html` (while safely escaping error text).
- **UTF-8 Without BOM (`GEMINI.md`):** All `.ps1`, `.html`, `.css`, `.js`, and `.cs` files must remain UTF-8 without BOM.
- **Fail-Fast Build (`GEMINI.md`):** `build.ps1` must abort immediately on syntax/validation failure and produce an Authenticode-signed executable.
- **No Breaking Changes to CLI/UI Contract:** Preserve existing `/Silent`, `/ScheduledRun`, `-OutDir`, `-ComputerListFile`, `-ScanLocalhost` parameters and all Web UI features.

## Review Focus

- **Elevated Localhost CSRF / Port Probing:** Unauthenticated `POST /api/*` or `GET /api/fs/browse` requests without a valid `X-FTI-Token` header or from a non-`127.0.0.1` `Host`/`Origin` must return `403 Forbidden`.
- **User-Writable Extraction Hijacking:** Non-admin processes must not be able to pre-plant or overwrite `app_engine.ps1` or `lid_power_backup.json` in `%LOCALAPPDATA%`.
- **Special Characters in Paths, Hostnames, and Error Messages:** Computer names containing `'`/`"`/`<`/`>`/`*`/`(`/`\`, or directory paths ending in `\` or containing spaces must not cause XSS, LDAP injection, or command-line argument splitting.
- **Concurrent Master CSV Read/Write:** Calling `/api/master/status` or `/api/master/action` while a scan writes `Hardware_Master.csv` or `Software_Master.csv` must never return empty/truncated data or throw file-in-use exceptions.
- **Laptop Lid-Close Power Restore:** If `AppServer.ps1` terminates unexpectedly while scanning, `Program.cs` `RestoreLidActionFallback` must find the exact same backup JSON path and restore the user's original AC/DC `LIDACTION`.

---

### Task 1: Fix Critical Startup & Lid-Close Backup Bugs in `src/AppServer.ps1`

**Files:**
- Modify: `src/AppServer.ps1:9-20`
- Modify: `src/AppServer.ps1:105-107`

**Interfaces:**
- Produces: Valid `$scriptDir` resolution when running standalone, clean UTF-8 BOM trimming on `$CoreScript`, and initialized `$localApp` (`$env:LOCALAPPDATA`) shared with `Program.cs` (`lid_power_backup.json`).

- [ ] **Step 1: Verify the current failure with a PowerShell AST & standalone syntax test**

Run:
```powershell
powershell -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'src/AppServer.ps1'), [ref]`$null, [ref]`$null).EndBlock.Extent.Text.Substring(0, 450)"
```
Expected: Shows lines 10–13 with `if ($CoreScript)` nested inside `if (-not $CoreScript)` and `$localApp` uninitialized at line 106.

- [ ] **Step 2: Fix `$scriptDir` and `$CoreScript` BOM trimming in `src/AppServer.ps1:9-20`**

Replace the corrupted `if (-not $CoreScript)` block so `$scriptDir` properly resolves `$PSScriptRoot` or `(Get-Location).Path`, and perform `$CoreScript = $CoreScript.TrimStart([char]0xFEFF)` in a separate `if ($CoreScript)` statement after loading.

- [ ] **Step 3: Initialize `$localApp` before line 106 in `src/AppServer.ps1`**

Set `$localApp = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [Environment]::GetFolderPath('LocalApplicationData') }` immediately before `$script:lidBackupFile = Join-Path $localApp 'FTI_PC_Inventory_Tool\lid_power_backup.json'`, and remove or deduplicate the later assignment at line ~1054.

- [ ] **Step 4: Verify AST parse and `$script:lidBackupFile` path resolution**

Run:
```powershell
powershell -NoProfile -Command "$errors = $null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'src/AppServer.ps1'), [ref]$null, [ref]$errors); if ($errors.Count -gt 0) { throw $errors[0].Message }; Write-Host 'AppServer.ps1 AST OK'"
```
Expected: `AppServer.ps1 AST OK` with 0 parse errors.

- [ ] **Step 5: Commit**

```bash
git add src/AppServer.ps1
git commit -m "fix(server): repair corrupted scriptDir logic and initialize localApp for lid-power backup"
```

---

### Task 2: Secure Elevated Extraction & Argument Quoting in `src/host/Program.cs`

**Files:**
- Modify: `src/host/Program.cs:25-105`

**Interfaces:**
- Produces: `Program.cs` extracting `app_engine.ps1` into an Administrators-only ACL directory (`%ProgramData%\FTI_PC_Inventory_Tool` or an ACL-hardened directory owned by `BUILTIN\Administrators`) with safely escaped command-line argument forwarding.

- [ ] **Step 1: Inspect `Program.cs` directory creation and argument forwarding**

Confirm lines 27–36 (`Environment.SpecialFolder.LocalApplicationData`) and lines 85–99 (`argBuilder`) lack ACL hardening and quote/backslash escaping.

- [ ] **Step 2: Harden engine extraction directory with Administrators-only ACL**

Extract `app_engine.ps1` into `Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "FTI_PC_Inventory_Tool")` (`%ProgramData%`) and apply `DirectorySecurity` granting `FullControl` only to `BUILTIN\Administrators` and `NT AUTHORITY\SYSTEM` (removing inheritance / non-admin write access) before writing `app_engine.ps1`. Keep `RestoreLidActionFallback` reading from `LocalApplicationData` (`%LOCALAPPDATA%\FTI_PC_Inventory_Tool\lid_power_backup.json`) to match `AppServer.ps1` (or align both to `%ProgramData%\FTI_PC_Inventory_Tool`).

- [ ] **Step 3: Implement proper Windows command-line argument quoting helper in `Program.cs`**

Add `private static string EscapeProcessArgument(string arg)` that wraps in double quotes and escapes embedded `"` and trailing `\` (per Windows C runtime parsing rules) for all forwarded `args` and `scriptPath`.

- [ ] **Step 4: Compile test `Program.cs` with `csc.exe`**

Run:
```powershell
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /out:$env:TEMP\test_host.exe src\host\Program.cs
```
Expected: Exit code `0` with zero compiler errors. Clean up `$env:TEMP\test_host.exe` afterward.

- [ ] **Step 5: Commit**

```bash
git add src/host/Program.cs
git commit -m "security(host): harden engine extraction ACL and fix command-line argument escaping"
```

---

### Task 3: Add Per-Session Token Auth, CSRF Protection & Path Validation to `src/AppServer.ps1` & `src/web/index.html`

**Files:**
- Modify: `src/AppServer.ps1` (startup token generation, HTML token injection, `/api/*` auth middleware, `folder`/`outDir` validation, quoting in `explorer.exe` and scheduled task args)
- Modify: `src/web/index.html` (inject `window.__FTI_TOKEN__` and wrap `fetch()` so every `/api/*` request sends `X-FTI-Token`)

**Interfaces:**
- Produces: Server variable `$script:ApiSessionToken` (32-byte cryptographically random hex/base64url token via `RNGCryptoServiceProvider`), HTTP header `X-FTI-Token`, and `Test-SafeDirectoryPath` helper in `AppServer.ps1`.
- Consumes: `window.__FTI_TOKEN__` injected into `index.html` `<head>` at HTTP response time for `GET /`.

- [ ] **Step 1: Generate `$script:ApiSessionToken` at `AppServer.ps1` startup**

Use `[System.Security.Cryptography.RNGCryptoServiceProvider]` to generate a 32-byte random hex token stored in `$script:ApiSessionToken`. Inject `<meta name="fti-api-token" content="$($script:ApiSessionToken)">` into `$HtmlContent` when serving `/` (`GET /`).

- [ ] **Step 2: Enforce `Host`, `Origin`/`Sec-Fetch-Site`, and `X-FTI-Token` validation on all `/api/*` endpoints**

Before dispatching any `/api/*` route in `AppServer.ps1`:
- Verify `Host` matches `127.0.0.1:<port>` or `localhost:<port>`.
- For state-changing methods (`POST`, `PUT`, `DELETE`), verify `Origin` (if present) starts with `http://127.0.0.1:<port>` or `http://localhost:<port>`.
- Verify `$req.Headers['X-FTI-Token'] -ceq $script:ApiSessionToken`; otherwise return HTTP `403 Forbidden` JSON error.

- [ ] **Step 3: Validate path parameters and fix quoting in `/api/open-folder`, `/api/fs/*`, `/api/master/*`, and Task Scheduler**

- Add `Test-SafeLocalPath` to reject UNC/arbitrary control chars, normalize via `[System.IO.Path]::GetFullPath`, and use `-LiteralPath` on all `Test-Path` calls.
- In `/api/open-folder`: pass `"$dir"` cleanly via `ProcessStartInfo` (`UseShellExecute = $true`, quoted argument) after verifying `Test-Path -LiteralPath $dir -PathType Container`.
- In Task Scheduler registration (`AppServer.ps1:1496`): strip trailing backslash from `$script:lastOutDir` before embedding in quoted `-OutDir`.

- [ ] **Step 4: Update `src/web/index.html` to attach `X-FTI-Token` automatically to all `/api/` `fetch` calls**

Read `<meta name="fti-api-token">` once at boot and install a lightweight `window.fetch` wrapper (or `apiFetch` helper) that automatically attaches `'X-FTI-Token': token` on same-origin `/api/*` requests.

- [ ] **Step 5: Verify PowerShell AST & JS Headless Syntax**

Run:
```powershell
powershell -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'src/AppServer.ps1'), [ref]`$null, [ref]`$null) | Out-Null; Write-Host 'AppServer OK'"
node -e "const fs=require('fs');const h=fs.readFileSync('src/web/index.html','utf8');for(const m of h.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)) new Function(m[1]); console.log('JS OK');"
```
Expected: `AppServer OK` and `JS OK`.

- [ ] **Step 6: Commit**

```bash
git add src/AppServer.ps1 src/web/index.html
git commit -m "security(api): add per-session X-FTI-Token auth, Origin checks, and safe path quoting"
```

---

### Task 4: Fix XSS Sinks & Inline `onclick` Escaping in `src/web/index.html`

**Files:**
- Modify: `src/web/index.html:15-35` (error banner)
- Modify: `src/web/index.html:6054-6218` (dashboard chart click handlers)
- Modify: `src/web/index.html:6965-7000` (`showToast`, `appendLogLine`)
- Modify: `src/web/index.html:7480-7810` (file browser modal & table actions)
- Modify: `src/web/index.html:8080-8480` (TDZ `btnRunDemo` ordering)

**Interfaces:**
- Produces: Safe DOM rendering using `textContent` / `escapeHtml()` and `data-*` delegated click handlers instead of raw string interpolation in `innerHTML` and inline `onclick`.

- [ ] **Step 1: Fix XSS in error banner, `showToast`, `appendLogLine`, and folder browser modal**

- Update `window.addEventListener('error')` banner (`line 33`) to build elements or escape `e.message` / `e.filename` with `escapeHtml()`.
- Update `showToast()` (`line 6969`) and `appendLogLine()` (`line 6989`) to set `.textContent` or wrap dynamic strings with `escapeHtml()`.
- Update folder browser rendering (`lines 7717, 7745, 7799`) to escape `item.name`, `item.path`, and `data.error`.

- [ ] **Step 2: Replace fragile inline `onclick="... '${escapeHtml(name)}' ..."` with `data-*` attributes + delegated event listeners**

Convert chart rows/slices/tiles (`renderBarGroup`, `renderDonutChart`, `renderColumnChart`, `renderTreemapGrid`) and folder browser items to store `data-drill-type`, `data-drill-val`, `data-drill-label` (escaped for HTML attribute) and attach delegated click handlers on the container elements. This prevents single-quote or backslash breakage when CPU/OS/folder names contain `'` or `\`.

- [ ] **Step 3: Fix `btnRunDemo` TDZ reference**

Move `const btnRunDemo = document.getElementById('btnRunDemo');` declaration above its first usage at line `8082` (group all DOM element constants together cleanly).

- [ ] **Step 4: Verify JS Headless Syntax & no duplicate `let`/`const`**

Run:
```powershell
node -e "const fs=require('fs');const h=fs.readFileSync('src/web/index.html','utf8');for(const m of h.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)) new Function(m[1]); console.log('JS OK');"
```
Expected: `JS OK` with 0 errors.

- [ ] **Step 5: Commit**

```bash
git add src/web/index.html
git commit -m "security(ui): eliminate innerHTML XSS sinks, replace inline onclick with data-* delegation, fix btnRunDemo TDZ"
```

---

### Task 5: Atomic Master CSV Persistence, Named `Mutex`, LDAP Escaping & Resource Cleanup

**Files:**
- Modify: `src/Get-PCInventory.Core.ps1` (`Export-CsvAtomic`, `Get-ADInfo` LDAP escaping, `Ping`/`RegistryKey` `try/finally` disposal, `$Throttle` `RunspacePool` parallelization)
- Modify: `src/AppServer.ps1` (use `Mutex` + cached Master CSV reads in `/api/master/status`, `try/finally` disposal for `StreamReader`, remove blocking `Start-Sleep` in HTTP loop, log non-trivial `catch` blocks)

**Interfaces:**
- Produces: `Save-CsvAtomic -Data <object[]> -Path <string>` synchronized via `Global\FTI_PC_Inventory_MasterCsvMutex` (or `Local\...`), and `Escape-LdapFilterValue -Value <string>` in `Get-PCInventory.Core.ps1`.
- Produces: In-memory cache `$script:masterCache` keyed by `LastWriteTimeUtc` in `AppServer.ps1` so `/api/master/status` never blocks the HTTP thread with repeated `Import-Csv` + `Group-Object` calls.

- [ ] **Step 1: Add `Escape-LdapFilterValue` to `src/Get-PCInventory.Core.ps1` and apply it in `Get-ADInfo`**

Escape `\`, `*`, `(`, `)`, and `\0` per RFC 4515 before interpolating `$pc` into `"(&(objectCategory=computer)(name=$escapedPc))"`.

- [ ] **Step 2: Implement `Save-CsvAtomic` with temp-file write + `[System.IO.File]::Replace` / atomic move + named `Mutex`**

Replace direct `Export-Csv` calls on `Hardware_Master.csv` and `Software_Master.csv` (both in `Get-PCInventory.Core.ps1` and `AppServer.ps1` `deleteMachine`/`resetMaster`) with atomic temp-file write + mutex lock.

- [ ] **Step 3: Add `LastWriteTimeUtc` cache for `/api/master/status` and fix HTTP thread blocking / `StreamReader` disposal in `src/AppServer.ps1`**

- Wrap all `StreamReader`, `Ping`, and `RegistryKey` creations in `try { ... } finally { if ($obj) { $obj.Dispose() } }`.
- Remove blocking `Start-Sleep -Seconds 2` inside the HTTP handler (`line 1540`) and replace with async/state check.
- Cache parsed Master DB rows & summary in `$script:masterCache` invalidated by `LastWriteTimeUtc` + `Length`.
- Replace silent `catch {}` blocks on critical I/O/CSV operations with `Write-SystemLog` warnings.

- [ ] **Step 4: Parallelize Pass 1 & Pass 2 scanning in `src/Get-PCInventory.Core.ps1` using `RunspacePool`**

Respect `$Throttle` (default `20`) using `[runspacefactory]::CreateRunspacePool(1, $Throttle)` so scanning 200+ PCs runs concurrently instead of sequentially.

- [ ] **Step 5: Verify PowerShell AST on both `.ps1` files**

Run:
```powershell
powershell -NoProfile -Command "foreach ($f in @('src/AppServer.ps1','src/Get-PCInventory.Core.ps1')) { $e=$null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$null, [ref]$e) | Out-Null; if ($e.Count -gt 0) { throw $e[0].Message }; Write-Host \"$f AST OK\" }"
```
Expected: Both `AppServer.ps1` and `Get-PCInventory.Core.ps1` pass with `0` errors.

- [ ] **Step 6: Commit**

```bash
git add src/Get-PCInventory.Core.ps1 src/AppServer.ps1
git commit -m "perf(core): parallelize scan with RunspacePool, make Master CSV atomic, escape LDAP, dispose resources"
```

---

### Task 6: Enforce Fail-Fast Headless Build Check & Clean Build Pipeline in `build.ps1`

**Files:**
- Modify: `build.ps1:88-185` (make headless JS syntax verification fail-fast; stop mutating tracked source files in place if unnecessary or isolate build staging)
- Modify: `build.ps1:410-425` (remove unexpected drive-root copy `E:\FTI_PC_Inventory.exe` unless explicitly requested)

**Interfaces:**
- Produces: Strict fail-fast `build.ps1` compliant with `GEMINI.md` rules.

- [ ] **Step 1: Make headless JS verification fail hard if no headless engine (Edge/Node) succeeds or if any `SyntaxError` occurs**

Ensure `build.ps1` throws a terminating error instead of `Write-Warning` when JS validation cannot run or fails.

- [ ] **Step 2: Perform version string injection on the temporary merged build artifact (`$tempDir`) rather than mutating tracked `src/web/index.html` and `src/host/Program.cs` in place**

Keep `version.json` as the single source of truth updated during build, while injecting build version metadata into the staged copies inside `$tempDir` so `git status` stays clean of noisy version-string diffs on source files.

- [ ] **Step 3: Remove hard-coded drive root copy (`E:\FTI_PC_Inventory.exe`)**

Keep deployment strictly inside `dist\` (`$OutputDir`).

- [ ] **Step 4: Run full `build.ps1` verification**

Run:
```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
Get-AuthenticodeSignature .\dist\FTI_PC_Inventory.exe | Format-List Status, SignerCertificate
```
Expected: Build completes cleanly (`v2026.11.13.x`), JS syntax check passes strictly, and `dist\FTI_PC_Inventory.exe` is signed.

- [ ] **Step 5: Commit & Push**

```bash
git add -A
git commit -m "build: enforce fail-fast JS verification, stage version injection, and remove drive-root copy"
git push origin main
```

