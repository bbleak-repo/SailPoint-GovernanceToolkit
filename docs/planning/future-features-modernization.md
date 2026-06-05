# Future Features — Platform Modernization

> **Living document.** Update this when decisions are made, options are ruled out,
> or new information surfaces. Sections marked `[OPEN]` are unresolved; `[DECIDED]`
> have a committed direction; `[FUTURE]` are deferred but scoped.

**Created:** 2026-06-05  
**Context:** After completing the SP.Sdk / Phase 7 SDK GUI tab on `feature/phase7-sdk-gui-tab`,
a conversation surfaced the full picture of what a PS7 + .NET 8 modernization would
actually involve — and why the sequencing is more nuanced than "CLI first" or "GUI first."
This document captures that analysis as a standing reference.

---

## 1. Current state (what we actually have)

| Layer | Technology | Status |
|---|---|---|
| CLI scripts (24) | PowerShell 5.1 Desktop | Working, all 1062 Pester tests green |
| Core modules | PowerShell 5.1, `#Requires -Version 5.1` (106 files) | Working |
| GUI dashboard | WPF (.NET Framework 4.8) driven by PS 5.1 | Windows-only, working |
| Test suite | Pester 5.7.1 on PS 5.1 | 1062/1062 green on Windows |
| Mock server | Pode 2.13.3 on PS 5.1 | Working, SailPoint-ISC profile |
| Mac (MacBook) | pwsh (PS 7.x) + .NET (Core) | CLI runs with ~55 test failures; GUI not possible |
| Windows box | powershell.exe 5.1 + .NET Framework 4.8 | Full CLI + GUI |
| .NET runtime present | .NET 8.0.27 (runtime only, no SDK) | Installed as dependency of other apps |

**Why PS 5.1 was chosen:** At project start the developer only saw `powershell.exe`
in Windows search; `pwsh` (PS 7) was not installed and was deliberately kept off to
avoid version conflicts. The toolkit was purpose-built for what was actually available.

---

## 2. The ecosystem split you need to know

There are two completely separate .NET lineages. This distinction matters for every
migration decision below.

```
.NET Framework (Windows only, frozen)          .NET (formerly Core, cross-platform)
──────────────────────────────────────         ──────────────────────────────────────
Versions: 1.0 → 4.8.1 (done, maintenance)     Versions: 5 → 6 → 7 → 8 → 9 → ...
Host:     powershell.exe (Windows PS 5.1)      Host: pwsh.exe (PS 7+)
WPF:      Ships inbox with Windows             WPF: Available on Windows via
          C:\Windows\Microsoft.NET\...              Windows Desktop Runtime
          (your dashboard uses this)               C:\Program Files\dotnet\...
Mac:      NOT AVAILABLE                        Mac: pwsh works; WPF still NOT available
                                                    (WPF is Windows-only in BOTH lineages)
```

**The critical insight that surprises people:**
Porting the WPF GUI from PS 5.1 + .NET Framework to PS 7 + .NET 8 does **not** make
the GUI run on a Mac. WPF is Windows-only in both lineages. The only path to a Mac GUI
is replacing WPF with a cross-platform UI framework (see §5).

---

## 3. The three independent migration tracks

These are separable. You can do any of them independently, in any order.

| Track | What it means | Mac benefit | Windows benefit | Effort |
|---|---|---|---|---|
| **A — CLI to PS7** | Re-target 106 `#Requires` files; fix ~55 PS7 test failures | Full CLI parity on Mac | Modern language, active security patches | Medium |
| **B — GUI to PS7 + .NET 8 WPF** | Switch GUI from powershell.exe/.NET Framework to pwsh/.NET 8 WPF; still Windows-only | None (WPF = Windows-only regardless) | Modern runtime, active WPF development, stepping stone to Track C | Low–Medium |
| **C — Cross-platform GUI** | Replace WPF entirely (Avalonia, Pode web, or MAUI); requires Track B first or in parallel | Full GUI on Mac | Cross-platform deployment | High–Very High |

---

## 4. Track A — CLI port to PS7

### What needs to change

**106 files** contain `#Requires -Version 5.1`. The mechanical changes are straightforward
(sed-style replacement). The substantive work is the ~55 Pester test failures.

The known PS7 incompatibilities (from ~55 failures under pwsh on the MacBook):

| Category | Root cause | Fix approach |
|---|---|---|
| `Mock -ModuleName` targeting | PS7 is **stricter** about nested module scope; the mock reaches a different call site | Re-target mocks; some require flat-import instead of psd1 load |
| `@(ConvertFrom-Json)` wrapping | PS7's `ConvertFrom-Json` returns typed objects differently; single-element behavior changed | Already fixed once (session history); review all callsites |
| `&&` / `\|\|` pipeline chains | Do NOT exist in PS 5.1, so we never used them — but PS7 scripts from other sources may | No issue in our code; safe |
| Ternary `? :` | Not in PS 5.1 — we never used it | No issue |
| `[ordered]@{}` coercions | Minor edge cases in hashtable-to-PSCustomObject casts | Review per failure |
| `CmdletBinding()` SupportsShouldProcess + WhatIf | Minor propagation differences | Review per failure |
| `Measure-Object` return type | Already fixed in product (OC-07); verify test side | Likely clean |

**How to get the exact list:**
```powershell
# On the MacBook (has pwsh):
cd /path/to/SailPoint-GovernanceToolkit
$cfg = New-PesterConfiguration
$cfg.Run.Path = './Tests'
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg 2>&1 | Out-File pester-ps7.log
# Count: grep -c FAILED pester-ps7.log
```

**Language features gained (relevant to this codebase):**

```powershell
# Current PS 5.1 defensive patterns → PS7 equivalents
if ($null -ne $obj) { $obj.Property } else { $default }   →  $obj?.Property ?? $default
if (-not $r.Success) { return }; DoNext                    →  $r.Success || return
$val = if ($cond) { 'a' } else { 'b' }                    →  $val = $cond ? 'a' : 'b'
Invoke-RestMethod + hand-rolled retry                      →  -RetryIntervalSec, -MaximumRetryCount
ForEach-Object { ... }  (serial batch ops)                 →  ForEach-Object -Parallel { ... } -ThrottleLimit N
```

**`Invoke-RestMethod` improvements for the toolkit specifically:**

PS7's `Invoke-RestMethod` adds `-RetryIntervalSec` and `-MaximumRetryCount`. The current
`SP.ApiClient.psm1` hand-rolls retry + exponential backoff because PS 5.1 gives you
nothing. Some of that complexity simplifies on PS7 — though the ISC rate-limit handling
(client-side token bucket) is custom logic that stays.

**Recommended starting point:**
1. Create `feature/ps7-compat` branch.
2. Change ONE script's `#Requires` to `#Requires -Version 7.2`, run Pester under pwsh.
3. The failure list is the task list. Most failures will cluster in 3–4 root cause categories.
4. Fix module by module, not test by test.

---

## 5. Track B — GUI to PS7 + .NET 8 WPF (Windows-only, modernized)

### What changes and what doesn't

The GUI stays Windows-only. The only thing that changes is the runtime:
- `powershell.exe` (5.1 + .NET Framework 4.8) → `pwsh.exe` (7.x + .NET 8)
- `PresentationFramework` loads from `.NET Framework` → from `.NET 8 Desktop Runtime`
- All WPF XAML, events, controls stay the same (WPF API is stable across both)

**Required on the Windows box:** .NET 8 Desktop Runtime (already installed as
`Microsoft.WindowsDesktop.App 8.0.27`). No user install needed.

**Code changes:**
- `Show-SPDashboard.ps1` pre-flight: change edition check from `Desktop` → `Core`;
  remove .NET Framework registry check; add `dotnet --list-runtimes` check for
  `Microsoft.WindowsDesktop.App 8.*` or later.
- All `#Requires -Version 5.1` → `7.2` in GUI-facing files.
- STA apartment: `pwsh -STA` works the same as `powershell -STA`. No change needed.
- `Add-Type -AssemblyName PresentationFramework` still works; .NET 8 resolves it from
  `C:\Program Files\dotnet\` instead of `C:\Windows\Microsoft.NET\`.

**What you gain:**
- Active WPF development (better accessibility, improved high-DPI, bug fixes).
- .NET 8 LTS security patches through Nov 2026, then .NET 10 LTS.
- Eliminates dependency on .NET Framework (maintenance-mode).
- Stepping stone: once on PS7 + .NET 8, swapping WPF for Avalonia (Track C-1) is a
  cleaner migration than going directly from .NET Framework.

**Why do this before Track C?**
Track B is the foundation Track C-1 (Avalonia) needs. Avalonia targets .NET 6+ — it
cannot run on .NET Framework. Doing B before C-1 means one migration at a time.

---

## 6. Track C — Cross-platform GUI (the Mac GUI path)

This is where it gets interesting. Three realistic options:

### C-1: Avalonia UI (recommended if Mac GUI is a goal)

[Avalonia](https://avaloniaui.net/) is an open-source, XAML-based UI framework for
.NET that runs on Windows, macOS, and Linux. It is the closest spiritual successor to
WPF for cross-platform .NET development.

**Why it's the best WPF replacement for this codebase:**
- XAML-based — our `MainWindow.xaml`, `AuditTab.xaml`, `DeltaCertTab.xaml` etc. port
  with modification, not a complete rewrite.
- `AvaloniaUIShell 0.0.2` is already present in the PS module gallery (confirmed on this
  box), providing a PowerShell → Avalonia bridge.
- Dark-theme styling, DataGrid, TabControl, ComboBox all exist.
- Actively maintained with .NET 8/9 support.

**What changes from WPF:**
- XAML namespace: `xmlns="https://github.com/avaloniaui"` instead of WPF's namespace.
- Some control names differ (`Window.Content` works the same; `DataGrid` has differences).
- Event model: mostly the same; `RoutedEvent` works but some event names differ.
- `System.Windows.*` → `Avalonia.*` namespace imports.
- No `System.Windows.Application`; `Avalonia.Application` replaces it.
- The STA threading model is replaced by Avalonia's own dispatcher.
- FlaUI for UI testing does NOT support Avalonia — would need to switch to
  Avalonia's own test harness or `appium`/`FlaUI successor`.

**Effort estimate:** High. Each XAML file and its PS handler code needs review and
adjustment. The GUI test harness (W-02 through W-08) would need rebuilding.
Expect 4–6 focused development sprints.

**Prerequisite:** Track B (PS7 + .NET 8) should be complete first.

---

### C-2: Pode Web Dashboard (lowest new-technology risk)

Pode 2.13.3 is **already in this project** as the API-MockServer framework. Pode ships
a built-in web dashboard and real-time UI capability via WebSockets — no additional
framework needed.

**The concept:** Replace the WPF window with a local `http://localhost:PORT` web app
served by Pode. The browser is the UI. Works on Windows, macOS, Linux — anything with
a browser.

**What Pode web gives you:**
- Self-contained HTML/CSS/JS dashboard served from PS.
- Real-time updates via Pode's SSE (Server-Sent Events) or WebSockets.
- REST API backend in PS — the existing bridge functions become API endpoints.
- The existing CLI modules become the backend; no new language needed.
- Dashboards can be fully styled (dark theme, tables, badges) with standard CSS.

**What you lose from WPF:**
- Native OS look/feel (now it's a browser tab).
- FlaUI GUI testing (replaced by browser automation — Playwright, which is already
  referenced in the `Test-W06-Playwright.ps1` harness!).
- Modal dialogs become browser modal popups or in-page panels.

**Effort estimate:** Medium–High. The PS bridge layer stays; the XAML UI is completely
replaced by HTML templates. The existing `SP.GuiBridge.psm1` and `SP.SdkBridge.psm1`
functions become Pode route handlers. Playwright test coverage is already sketched in
`Tests/Harness/Test-W06-Playwright.ps1`.

**This is the option that leverages the most existing investment** (Pode knowledge,
bridge layer, CLI modules). It would also unify the mock server and dashboard under
one framework.

---

### C-3: MAUI (Microsoft's official cross-platform)

.NET MAUI is Microsoft's blessed cross-platform successor for mobile + desktop UI.
It is NOT XAML-compatible with WPF (different paradigm, different controls). This would
be a complete rewrite with no XAML reuse. Realistic effort: Very High.

**Recommendation: Do not pursue MAUI for this project.** The WPF-to-MAUI gap is too
large; Avalonia is a better fit for "WPF but cross-platform."

---

## 7. Recommended sequencing (with honest tradeoffs)

Two coherent paths depending on the primary goal:

### Path 1: "Mac CLI parity first" (pragmatic, lower risk)

```
Track A (CLI → PS7)  →  Track B (GUI → PS7+.NET8 WPF)  →  Track C-1 or C-2 (Mac GUI, someday)
    ~3–5 sessions            ~2–3 sessions                      Major effort, future decision
```

**Best if:** You want the MacBook to become a full development platform quickly.
The ~55 test failures are the work; Mac CLI parity is the reward.

### Path 2: "GUI modernization first" (the user's instinct — valid for different reason)

```
Track B (GUI → PS7+.NET8)  →  Track A (CLI → PS7)  →  Track C-1 (Avalonia, Mac GUI)
    ~2–3 sessions                  ~3–5 sessions           Major effort
```

**Best if:** The end goal is eventually replacing WPF with Avalonia (Track C-1).
Doing B first means you're already on .NET 8 + PS7 when you start the Avalonia port.
Going `.NET Framework → Avalonia` in one step is a harder jump than
`.NET Framework → .NET 8 WPF → Avalonia`.

### The sequencing point that tripped us up

"Port GUI first because it doesn't work on Mac" is only correct if the goal is
**eventually getting a Mac GUI** (Path 2). If the goal is **Mac CLI parity**, the
GUI port doesn't help at all — WPF is Windows-only in every case.

---

## 8. Known PS7 compatibility issues (catalogued)

Documented here so a future developer doesn't have to rediscover them.

### Module scoping (`Mock -ModuleName`)

PS7 is stricter about nested module scope. Our `Import-TestModules.ps1` already
flat-imports `.psm1` files directly (bypassing `.psd1` aggregators) specifically to
work around this. The ~55 failures are likely in tests that weren't migrated to the
flat-import pattern. Fix: extend `Import-TestModules.ps1` to cover remaining modules
and re-target mocks.

### `@(ConvertFrom-Json)` single-element arrays

PS 5.1: single-element JSON arrays unwrap to the element; wrapping in `@(...)` re-arrays.
PS 7: behavior changed. The toolkit already has documented fixes (SP.DisconnectedAppRunner
session history). A PS7 port needs to audit all `ConvertFrom-Json` callsites.
Search: `grep -rn "ConvertFrom-Json" Modules/`.

### `Measure-Object` return types

`(... | Measure-Object -Maximum).Maximum` returns a type that doesn't hash-match `int`
in PS 5.1 (bug OC-07, fixed with `[int]` cast). PS7 may handle this differently — verify
the cast is still correct or can be simplified.

### `$PSEdition` checks

Our new pre-flight check in `Show-SPDashboard.ps1` requires `$PSEdition -eq 'Desktop'`.
For a PS7 GUI port this becomes `'Core'`. That's a one-line change, but it's a flag to
remember.

### `[System.Windows.Forms]` in `SP.MainWindow.psm1`

`Add-Type -AssemblyName System.Windows.Forms` is called for `DialogResult` types. In
PS7 + .NET 8 on Windows, WinForms is available (part of `Microsoft.WindowsDesktop.App`)
so this should still work. Verify with a quick `Add-Type` test under pwsh.

### WPF STA apartment in pwsh

`pwsh -STA` is supported. The `Show-SPDashboard.ps1` STA self-relaunch pattern works
the same way — just replace `powershell.exe` with `pwsh.exe` in the `Start-Process` call.
`[System.Threading.Thread]::CurrentThread.ApartmentState` still works.

---

## 9. What we have that gives us a head start

These things do NOT need to be rebuilt for any of the three tracks:

| Asset | Why it survives migration |
|---|---|
| All 24 CLI scripts (logic) | PS7-compatible with `#Requires` change + ~55 test fixes |
| `SP.Core`, `SP.Api`, `SP.Sdk` modules | Pure PS logic; PS7-compatible with minor scoping fixes |
| `SP.GuiBridge.psm1`, `SP.SdkBridge.psm1` | Bridge pattern works in PS7 + becomes API handlers in C-2 |
| `SP.MainWindow.psm1` handler logic | Ported wholesale to Track B; reusable for Track C-1 |
| All Pester unit tests (core logic) | Fix ~55 failures, rest survive |
| API-MockServer (Pode) | Already PS7 on Mac; no changes needed |
| `docs/playbook/*.md` | Language-agnostic; HTML re-generates |
| Build + packaging scripts | `build-dist.ps1` logic survives; zip structure unchanged |
| Settings, vault, config system | No PS version dependency |
| The complete SDK bridge functions | All 14 bridge functions are pure PS logic |

---

## 10. Environment facts (as of 2026-06-05)

Recorded so a future developer knows the starting conditions.

| Machine | OS | PowerShell | .NET Framework | .NET Runtime | pwsh |
|---|---|---|---|---|---|
| Windows dev box | Win11 Pro 10.0.26200 | 5.1.26100 Desktop | 4.8 (release 533509) | 8.0.27 (runtime only, no SDK) | Not installed (intentional) |
| MacBook | macOS | pwsh 7.x | N/A | Available | Installed |

**Important:** The Windows box has `.NET 8.0.27 runtime` but **no .NET SDK**. Building
Avalonia apps or compiling .NET code requires the SDK. If Track C-1 is pursued, install
the .NET 8 SDK first: `winget install Microsoft.DotNet.SDK.8`.

**Pode 2.13.3** is installed and working (drives API-MockServer). This is the key
enabler for Track C-2 (Pode web dashboard) — no new framework install needed.

**FlaUI 4.0 DLLs** are vendored in `Tests\Tools\FlaUI\`. These are UIA3 + .NET 4.x
compiled. They load under PS 5.1 + .NET Framework. Under PS7 + .NET 8 they may need
recompilation or the newer FlaUI NuGet package targeting .NET 6+. Verify before
committing to Track B GUI test migration.

---

## 11. Decision log

| Date | Decision | Rationale |
|---|---|---|
| 2026-06-05 | Built on PS 5.1 | Only PS version available at project start; `pwsh` not installed |
| 2026-06-05 | .NET Framework minimum set to 4.8 | Pre-installed on Win10 1903+/Win11; no API requires it specifically but it's the modern inbox runtime |
| 2026-06-05 | No migration started | Toolkit complete and green; migration is future work |
| 2026-06-05 | Identified Pode web (C-2) as lowest-risk cross-platform GUI path | Pode 2.13.3 already in project; bridge layer survives; Playwright test harness already sketched |
| *(future)* | *(record decisions here as they are made)* | |

---

## 12. First steps when ready to start (copy-paste ready)

**Track A — CLI to PS7:**
```powershell
git checkout -b feature/ps7-compat
# Confirm PS7 is installed: winget install Microsoft.PowerShell
pwsh -Command { $PSVersionTable }
# Run the suite under pwsh and capture failures:
pwsh -Command {
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = '.\Tests'
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'Detailed'
    $r = Invoke-Pester -Configuration $cfg
    $r.Failed | ForEach-Object { $_.ExpandedPath } | Out-File .\Tests\_ps7-failures.txt
    "Failed: $($r.FailedCount) / $($r.TotalCount)"
}
# The failures file is the task list.
```

**Track B — GUI to PS7 + .NET 8:**
```powershell
git checkout -b feature/ps7-gui
# Verify Windows Desktop Runtime present:
dotnet --list-runtimes | Select-String 'WindowsDesktop'
# Test that WPF loads under pwsh:
pwsh -STA -Command { Add-Type -AssemblyName PresentationFramework; "WPF loaded OK" }
# Then update Show-SPDashboard.ps1 pre-flight and #Requires, run GUI manually.
```

**Track C-2 — Pode web dashboard (prototype):**
```powershell
# Pode is already installed. A minimal proof-of-concept:
pwsh -Command {
    Import-Module Pode
    Start-PodeServer {
        Add-PodeEndpoint -Address localhost -Port 9090 -Protocol Http
        Add-PodeRoute -Method Get -Path '/' -ScriptBlock {
            Write-PodeHtmlResponse -Value '<h1>Governance Toolkit</h1>'
        }
    }
}
# Then open http://localhost:9090 — that's the starting point.
```
