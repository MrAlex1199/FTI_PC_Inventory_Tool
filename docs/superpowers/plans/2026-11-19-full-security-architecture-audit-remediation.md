# Full Security, Architecture & Data Integrity Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remediate all 6 Critical, 9 Important, and 6 Minor verified findings from the `fe1e96f` full-codebase audit while preserving 100% of real-time UI streaming (`[LIVE_PC]`, `[LIVE_SW]`, `[STAGE:HW]`, `[STAGE:SW]`) via TDD regression tests.

**Architecture:** Fixes are partitioned into 6 self-contained component tasks (Native Launcher, Core Scan Engine, Core Data Integrity & Leaks, Backend Server & API Contracts, Embedded Web UI, and Build Pipeline). Each task begins with a failing automated test covering the bug/exploit and ends with a green test run plus real-time regression verification.

**Tech Stack:** C# (.NET Framework 4 / `csc.exe`), PowerShell 5.1 (WinRM, DCOM/CIM, Remote Registry, `HttpListener`), Vanilla HTML/CSS/JS (Edge/WebView2), Authenticode SHA256.

**Spec:** Full-Codebase Security & Architecture Audit Report at commit `fe1e96f` (6 Critical, 9 Important, 6 Minor verified findings).

## Global Constraints
- **Zero JS Syntax Errors**: All JS in `src/web/index.html` runs directly in Edge/WebView2 without bundling; verified via headless Edge across `1440x900`, `750x900`, `420x800`.
- **UTF-8 Without BOM**: All `.ps1`, `.cs`, `.html` files must remain UTF-8 without BOM.
- **No Real-Time UI Regression**: `ScanLocalhost` stream test (`[LIVE_PC] Scanning -> OK`, `[STAGE:HW|1|1]`, `[LIVE_SW] Scanning -> OK`, `[STAGE:SW|1|1]`) must pass after every Core/Server task.
- **Authenticode Signing & Fail-Fast Build**: `build.ps1` must abort on any AST, headless JS, C#, or signing failure (unless `-SkipSign` is explicitly passed).
- **Post-Build Git Push**: After final verified build of `dist/FTI_PC_Inventory.exe`, commit and push to `origin main`.

## Review Focus
1. **Targeted `NameFilter` with `MasterMode = $true`**: Scanning with `NameFilter = '*Chrome*'` must filter snapshot exports (`Software_*.csv`) without wiping non-Chrome apps from `Software_Master.csv`.
2. **Pass 2 Rescued & VNC `'Online'` Hosts in Master DB**: Rescued hosts must preserve `First_Seen` and increment `Scan_Count`; VNC `'Online'` hosts must NOT be downgraded to `'Offline (Was OK)'`.
3. **Single-IPv4 DNS + ARP Array Outputs in PS 5.1**: Scalar `[IPAddress]` indexing must not throw in `Resolve-PCTargets`, and `arp.exe -a` must extract MAC addresses properly.
4. **Concurrent Multi-Instance Launch (UI + Scheduled `-Silent`)**: Simultaneous launches must not collide on `C:\ProgramData\FTI_PC_Inventory_Tool\app_engine.ps1` or fail on Master CSV mutex reads.
5. **UI ↔ Backend API Parity**: Custom `OutDir` open-folder, open-report toast, Master Hub Software actions/paths/counts, `excludeServerFile`, `#selSortBy` sorting, and `btnRunDemo` re-enable must all work cleanly with zero XSS sinks.

---

### Task 1: Native Launcher Security & Multi-Instance Safety (`src/host/Program.cs`)

**Files:**
- Modify: `src/host/Program.cs:38-185, 355-372`
- Test: `scratch/test_task1_launcher.ps1`

**Interfaces:**
- Produces: Hardened `FTI.PCInventory.Launcher` resolving absolute System32 paths for `powershell.exe` and `powercfg.exe`, using a hash-versioned engine filename under `ProgramData\FTI_PC_Inventory_Tool\` to prevent multi-instance extraction races, and removing duplicate `if (isSilent)` dead code.

- [ ] **Step 1: Write failing static & compilation verification test (`test_task1_launcher.ps1`)**
  Assert `Program.cs` does not contain bare `FileName = "powershell.exe"` or `ProcessStartInfo("powercfg.exe")`, uses `Environment.SpecialFolder.System`, uses a hash/version-scoped engine filename instead of static `"app_engine.ps1"`, checks reparse point before writing, and has no duplicate `isSilent` branch.
- [ ] **Step 2: Run test to verify it fails**
  Run: `powershell -ExecutionPolicy Bypass -File "...\scratch\test_task1_launcher.ps1"`
  Expected: FAIL on C-1, I-7, M-6 assertions.
- [ ] **Step 3: Implement fixes in `src/host/Program.cs`**
  - Resolve `string sysDir = Environment.GetFolderPath(Environment.SpecialFolder.System);`
  - Use `Path.Combine(sysDir, @"WindowsPowerShell\v1.0\powershell.exe")` and `Path.Combine(sysDir, "powercfg.exe")`.
  - Compute SHA256 prefix (8 hex chars) of the embedded `FTI.Engine` stream to write `app_engine_<hash>.ps1`; acquire a named Mutex (`Global\FTI_PC_Inventory_ExtractMutex`) during extraction and skip overwrite if already present, non-reparse-point, and hash-verified.
  - Collapse duplicate `if (isSilent) / else` block (`167-179`).
- [ ] **Step 4: Run test + compile `Program.cs` with `csc.exe` to verify PASS**
  Expected: PASS (0 compiler errors, all assertions green).

---

### Task 2: Core Engine Discovery & Network Probe Fixes (`src/Get-PCInventory.Core.ps1`)

**Files:**
- Modify: `src/Get-PCInventory.Core.ps1:325-415, 500-540, 630-690, 930-1045, 1340-1710`
- Test: `scratch/test_task2_core_discovery.ps1`

**Interfaces:**
- Produces: Fixed `Resolve-PCTargets` (scalar `[IPAddress]` safe), `Test-PCConnection` & VNC ARP parsing (joined string `-match`), `Get-ADInfo` + AD discovery populating `AD_DNSHostName`, and `try/finally` disposal for `RegistryKey`, `CimSession`, `DirectorySearcher`, `UdpClient`, `TcpClient`.

- [ ] **Step 1: Write failing unit test (`test_task2_core_discovery.ps1`)**
  - Test single-IPv4 scalar `[IPAddress]` handling in `Resolve-PCTargets` (must invoke `Find-GhostDnsTrueIP` without throwing).
  - Test `arp.exe` array output parsing extracts MAC into `$Matches[1]`.
  - Test `Get-ADInfo` includes `AD_DNSHostName` property.
  - AST/pattern check that Remote Registry Uninstall loop (`$uKey`, `$sub`) and `CimSession` calls have `finally` disposal.
- [ ] **Step 2: Run test to verify it fails**
  Expected: FAIL on C-6, I-2, I-3, I-6.
- [ ] **Step 3: Implement fixes in `src/Get-PCInventory.Core.ps1`**
  - Wrap `[System.Net.Dns]::GetHostAddresses($cleanPc) | Where-Object ...` in `@(...)` (`line 974`).
  - Join `$arpOutput` with ``"`n"`` before `-match` (`lines 404, 1679`).
  - Add `dnshostname` to `Get-ADInfo` `PropertiesToLoad` and store `AD_DNSHostName` in `$adCache` (`lines 514-534, 679-683`).
  - Add `try/finally` disposal for `$uKey`/`$sub` in `Get-HardwareFromRemoteRegistry`, `$s`/`$sess` in `Invoke-DeepPenetrationScan` & `Invoke-RemoteDnsSelfHeal`, `[adsisearcher]`/`FindAll()`, and `UdpClient`/`TcpClient`.
- [ ] **Step 4: Run test + PowerShell AST check to verify PASS**
  Expected: PASS (0 AST errors, all assertions green).

---

### Task 3: Core Engine Master DB Integrity & Concurrency (`src/Get-PCInventory.Core.ps1`)

**Files:**
- Modify: `src/Get-PCInventory.Core.ps1:110-175, 560-570, 1685-1708, 1718-1732, 2130-2185, 2250-2325, 2750-2815`
- Test: `scratch/test_task3_master_integrity.ps1` + `scratch/test_realtime_core.ps1`

**Interfaces:**
- Produces: `Invoke-WithMasterCsvMutex` in Core wrapping all Master CSV reads (`Import-Csv`), preserved `Software_Master.csv` under `NameFilter`, clean Pass 2 → Master Sync handoff supporting `'Online'` VNC hosts, and normalized NetBIOS/FQDN key deduplication in `Hardware_Master.csv`.

- [ ] **Step 1: Write failing unit test (`test_task3_master_integrity.ps1`)**
  - Case A (C-4): Scan with `NameFilter = '*Chrome*'` and `MasterMode = $true` → `Software_$stamp.csv` contains only Chrome, while `Software_Master.csv` retains Chrome + 7-Zip (all installed apps on that PC).
  - Case B (C-5): Pass 2 rescues a PC and detects a VNC `'Online'` host → `Hardware_Master.csv` preserves `First_Seen`, increments `Scan_Count`, and keeps VNC host as `'Online'` (NOT `'Offline (Was OK)'`).
  - Case C (I-4): Master DB has `PC-01`, scan targets `PC-01.corp.local` → merges into single `PC-01` row with no duplicate rows.
- [ ] **Step 2: Run test to verify it fails**
  Expected: FAIL on C-4, C-5, I-4.
- [ ] **Step 3: Implement fixes in `src/Get-PCInventory.Core.ps1`**
  - Add `Invoke-WithMasterCsvMutex` helper and wrap Master `Import-Csv` reads (`563, 1722, 2753`).
  - Remove premature `$masterDict[$sPc.ToUpper()] = ...` mutations from `Harvest-Pass2Jobs` (`2141, 2178`), match `$hw[$k]` by normalized short name, and fix `Disk_Info` → `Disks`/`Disk_C_Free` in VNC Stage 6 (`1698`).
  - In Hardware Master Sync (`2252-2325`): normalize lookup/dedup by short name + IP, handle `$r.Status -eq 'Online'` without downgrading to `'Offline (Was OK)'`.
  - In Software Master Sync (`2770`): group `$all` (full unfiltered inventory) instead of `$final` (`$NameFilter`-filtered).
- [ ] **Step 4: Run `test_task3_master_integrity.ps1` AND `test_realtime_core.ps1`**
  Expected: Both PASS (zero real-time streaming regression).

---

### Task 4: Backend HTTP Server Security, API Contracts & Performance (`src/AppServer.ps1`)

**Files:**
- Modify: `src/AppServer.ps1:25-60, 200-210, 790-850, 870-935, 1235-1260, 1295-1355, 1410-1490, 1610-1630, 1705-1995, 2185-2250`
- Test: `scratch/test_task4_appserver.ps1`

**Interfaces:**
- Consumes: `src/Get-PCInventory.Core.ps1`
- Produces: Hardened `AppServer.ps1` enforcing `Host` check on all routes (`/` + `/api/*`), `Test-SafeLocalPath` + quote rejection on `outDir`/`listFile`/`excludeServerFile`/scheduled task args, full System32 paths for `powershell.exe`/`explorer.exe`, fixed UI↔API contracts (`open-folder`, `open-report`, Master Hub `sw`/`software`, `path`, `total`, `excludeServerFile`), mutex-protected `backupMaster`, null-safe `deleteMachine`, lightweight `/api/status` (omitting `SoftwareList`), capped `$script:lastLogs`, targeted browser-profile exit check, and Silent mode `$ps` disposal.

- [ ] **Step 1: Write failing unit/contract test (`test_task4_appserver.ps1`)**
  Verify `Test-SafeLocalPath` rejects UNC/quotes/control chars, `Host` validation runs before `/`, `Start-ExecutionScan` validates paths and forwards `-ExcludeServerFile`, `/api/master/status` includes `path` and `total`, `open-folder` accepts `path` or `folder`, `open-report` returns `status = 'ok'` (or 404 when absent), `master/action` accepts `'software'` and `'sw'`, `deleteMachine` handles blank `PCName`, `/api/status` omits `SoftwareList` from `swScannedPCs`, and `$script:swDetailsCache` dead code is removed.
- [ ] **Step 2: Run test to verify it fails**
  Expected: FAIL on C-2, I-1, I-5, I-9, M-1..M-4, M-6.
- [ ] **Step 3: Implement fixes in `src/AppServer.ps1`**
  Apply all verified server fixes while keeping `Update-ScanProgress` real-time stream parsing intact.
- [ ] **Step 4: Run `test_task4_appserver.ps1` + PowerShell AST check**
  Expected: PASS (0 AST errors, all assertions green).

---

### Task 5: Embedded Web UI XSS Elimination & Control Fixes (`src/web/index.html`)

**Files:**
- Modify: `src/web/index.html:4960-4978, 6120-6140, 8110-8122, 8185-8215, 8975-8990, 9200-9215, 9920-9940`
- Test: `scratch/verify_edge.js` + `scratch/test_task5_web_ui.js`

**Interfaces:**
- Consumes: Updated `/api/open-folder`, `/api/open-report`, `/api/master/status`, `/api/master/action`, `/api/status` from Task 4.
- Produces: XSS-free `renderTable()` (`Disk_C_Free`) and `renderSwTable()` (`Status`), working `#selSortBy` dropdown without double-fire, `btnRunDemo` re-enabled after scans.

- [ ] **Step 1: Write failing headless Edge test (`test_task5_web_ui.js`)**
  - Inject `<img src=x onerror="window.__xssFired=true">` into mock `pc.Disk_C_Free` and `pc.Status`, render both tables, assert `window.__xssFired !== true`.
  - Test `#selSortBy` options (`pc_asc`, `pc_desc`, `status`, `osbuild_desc`, `fail_desc`) sort properly and fire once.
  - Test `btnRunDemo.disabled` resets to `false` when `serverIsScanning` becomes `false`.
- [ ] **Step 2: Run test to verify it fails**
  Expected: FAIL on C-3, I-1 (#6, #7).
- [ ] **Step 3: Implement fixes in `src/web/index.html`**
  - Escape `Disk_C_Free` (`escapeHtml(pc.Disk_C_Free || '-')`) and `stDisplay` (`escapeHtml(stDisplay)`).
  - Align `onSortSelectChange` option values with `#selSortBy` and remove duplicate `addEventListener('change')`.
  - Re-enable `if (btnRunDemo) btnRunDemo.disabled = false;` in `pollTick()` idle and completion branches.
- [ ] **Step 4: Run `test_task5_web_ui.js` and `verify_edge.js` across `1440x900`, `750x900`, `420x800`**
  Expected: PASS (`fatalBannerActive: false`, zero XSS, all controls working).

---

### Task 6: Build Pipeline Integrity & Final Verification (`build.ps1`)

**Files:**
- Modify: `build.ps1:75-100, 310-325, 400-460`
- Test: `powershell -ExecutionPolicy Bypass -File .\build.ps1` + `Get-AuthenticodeSignature`

**Interfaces:**
- Produces: Fail-fast `build.ps1` that refuses to deploy unsigned binaries unless `-SkipSign` is explicitly set, bumps `version.json` only after validation/compilation succeed, respects `-ExeName`, and frees GDI `hIcon` handle.

- [ ] **Step 1: Implement fixes in `build.ps1`**
  - Defer writing `version.json` until after AST, headless Edge, and `csc.exe` succeed.
  - Fail the build (`throw`) on Authenticode signing failure or invalid signature status (`NotSigned`/`HashMismatch`) unless `-SkipSign` is set.
  - Preserve `$requestedExeName` for `$finalTargetExe` and call `DestroyIcon` after saving `.ico`.
- [ ] **Step 2: Run full verification suite (`verification-before-completion`)**
  - Run all task tests (`test_task1` through `test_task5`, `test_realtime_core.ps1`, `verify_edge.js`).
  - Run `powershell -ExecutionPolicy Bypass -File .\build.ps1`.
  - Verify `Get-AuthenticodeSignature dist\FTI_PC_Inventory.exe` shows `CN=Function International (FTI)`.
- [ ] **Step 3: Stage, commit, and push to `origin main`**
  Commit all modified files with the new build version and push to GitHub per `GEMINI.md`.
