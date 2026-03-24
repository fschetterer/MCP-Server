---
name: delphi-build-cmd
description: Use when creating or modifying Delphi MSBuild scripts (~Build.cmd),
  diagnosing stale-DCU or timestamp issues, or setting up build parameters for RTL
  version, config, clean vs incremental, or warning visibility.
---

# Delphi Build Script

## Core Rule: Clean + Build vs Build-only

| Goal | MSBuild invocation | When to use |
|------|--------------------|-------------|
| **Real build** | `/t:clean` then `/t:Build` (two calls) | First build, after source changes, CI, release |
| **Incremental** | `/t:Build` only | Fast iteration — only recompiles changed files |

> **A build is not a real build until you clean first.**
> `/t:Build` on stale DCUs silently produces wrong binaries. When in doubt, clean first.

> **Do not use `/t:Rebuild`.**
> Recommended in Delphi 10.4 release notes (and confirmed in practice): run
> `/t:clean` as a separate MSBuild invocation before `/t:Build`. The combined
> `/t:Rebuild` has known sequencing issues in some Delphi versions and is
> less reliable than the two-step approach.
>
> ```cmd
> MSBuild MyProject.dproj /nologo /v:q /t:clean
> MSBuild MyProject.dproj %CONSOLE% %LOGTO% /p:Config=%CONFIG% /p:Platform=%PLATFORM% /t:Build
> ```

### The Previous-Library Exception

If your project links against **pre-compiled DCUs** (third-party libs, shared framework
DCUs not in this project), **never use `/t:Rebuild`** — it will delete those DCUs and
break the build. Use `/t:Build` (SKIPCLEAN) in that case.

---

## Script Location and Naming

- Place alongside the `.dproj` (project root)
- Name: `~Build.cmd` — single parameterized script, all args required
- The `~` prefix sorts it to the top of directory listings

---

## Parameters

| Parameter | Values | Purpose |
|-----------|--------|---------|
| `RTL` | `23` (Delphi 12 Athens), `37` (Delphi 13 Florence) | **Required.** Locates `rsvars.bat` |
| `CONFIG` | `Debug`, `Release`, `NoCodeSite`, etc. | **Required.** Build configuration from `.dproj` |
| `PLATFORM` | `Win32`, `Win64` | **Required.** Target platform |
| `SKIPCLEAN` | flag present/absent | Optional. Skip clean for incremental build |
| `SHOWWARNINGS` | flag present/absent | Optional. Show warnings on console |

---

## Template

```cmd
@echo off
setlocal

:: ── Parameters (RTL, CONFIG, PLATFORM required) ──────────────────────────────
:: %1 RTL version: 23 = Delphi 12 Athens  |  37 = Delphi 13 Florence
:: %2 CONFIG:      Debug, Release, NoCodeSite, etc.
:: %3 PLATFORM:    Win32, Win64
:: %4 SKIPCLEAN:   any value = skip clean (incremental build)
:: %5 SHOWWARNINGS: any value = show warnings on console
set RTL=%1
set CONFIG=%2
set PLATFORM=%3
set SKIPCLEAN=%4
set SHOWWARNINGS=%5

if "%RTL%"=="" (echo Usage: ~Build.cmd RTL CONFIG PLATFORM [SKIPCLEAN] [SHOWWARNINGS] & exit /b 1)
if "%CONFIG%"=="" (echo Usage: ~Build.cmd RTL CONFIG PLATFORM [SKIPCLEAN] [SHOWWARNINGS] & exit /b 1)
if "%PLATFORM%"=="" (echo Usage: ~Build.cmd RTL CONFIG PLATFORM [SKIPCLEAN] [SHOWWARNINGS] & exit /b 1)

:: ── rsvars ────────────────────────────────────────────────────────────────────
:: Save CONFIG/PLATFORM — rsvars.bat overwrites them
set _CONFIG=%CONFIG%
set _PLATFORM=%PLATFORM%
call "C:\Program Files (x86)\Embarcadero\Studio\%RTL%.0\bin\rsvars.bat"
if errorlevel 1 (echo rsvars.bat not found for RTL %RTL% & exit /b 1)
set CONFIG=%_CONFIG%
set PLATFORM=%_PLATFORM%

:: ── Console output ────────────────────────────────────────────────────────────
:: Default: quiet — errors only, no banner, no summary
set CONSOLE=/nologo /v:q /clp:NoSummary;ErrorsOnly
if not "%SHOWWARNINGS%"=="" set CONSOLE=/nologo /v:m /clp:NoSummary

:: ── File log (always full verbosity) ─────────────────────────────────────────
:: /fl  - enable file logger
:: /flp - file logger parameters:
::   logfile=  file path (use project name, not generic, to avoid cross-project noise)
::   verbosity=normal  override for file (console stays quiet)
:: Split logs example: /fl1 /fl2 /flp2:logfile=JustErrors.log;errorsonly
if not exist "..\logs" mkdir "..\logs"
set LOGTO=/fl /flp:logfile=..\logs\MyProject.log;verbosity=normal

:: ── Clean + Build (or Build-only if SKIPCLEAN) ───────────────────────────────
:: Recommended per Delphi 10.4 release notes: separate /t:clean then /t:Build
:: is more reliable than the combined /t:Rebuild
if "%SKIPCLEAN%"=="" (
    msbuild "MyProject.dproj" /nologo /v:q /t:clean
    if errorlevel 1 (echo Clean failed & exit /b 1)
)
msbuild "MyProject.dproj" %CONSOLE% %LOGTO% /p:Config=%CONFIG% /p:Platform=%PLATFORM% /t:Build
exit /b %errorlevel%
```

---

## My 2 Cents

**Always log to `../logs/`** (relative to the script). Keeps build artefacts out of `src/`,
matches the MCP `delphi_build` tool's expected log location, and is git-ignorable in one rule.

**Separate console from file verbosity.** Console stays quiet (errors only) so the
`delphi_build` MCP tool captures minimal output — this keeps the AI agent's context
window lean. The log file always gets `verbosity=normal` so you have the full picture
when something goes wrong (use `windows_exec` to read the log if needed).

**Platform is a first-class parameter.** Cross-compilation between Win32/Win64 is common
enough that hard-coding it causes surprises. Default to Win64 for new projects.

**`SHOWWARNINGS` should surface hints too.** When debugging, `/v:m` (minimal) shows
warnings. For deeper investigation bump to `/v:n` (normal) or `/v:d` (detailed).

**Validate rsvars.** The `if errorlevel 1` check after `rsvars.bat` gives an immediate
useful error instead of a cascade of missing-tool failures.

**Custom config.** For projects with conditional library sets (e.g. NI6 hardware libs,
mock/stub variants), add a `Custom` config in the `.dproj` with its own `DCC_Define`
entries. The build script passes it straight through — no code change needed.

---

## MSBuild Verbosity Reference

| Flag | Level | Shows |
|------|-------|-------|
| `/v:q` | Quiet | Nothing (errors only via `/clp`) |
| `/v:m` | Minimal | Errors + warnings |
| `/v:n` | Normal | + build steps |
| `/v:d` | Detailed | + all task outputs |
| `/v:diag` | Diagnostic | Everything (very large log) |

---

## Common Pitfalls

- **Stale DCUs with `/t:Build`** — incremental build sees no timestamp change (common
  with WSL edits on Windows files) and silently skips recompilation. Use `/t:Rebuild`
  to be certain, or `touch` the modified `.pas` files from Windows.
- **Wrong RTL version** — `rsvars.bat` sets `$(BDS)` and library paths; wrong version
  silently links against the wrong RTL units.
- **Log file locked** — if a previous build is still running, MSBuild can't write the
  log and may fail silently. Check for stale `msbuild.exe` processes.
