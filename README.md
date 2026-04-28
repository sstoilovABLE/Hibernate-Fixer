# HibernateFix

A PowerShell script that diagnoses why Windows failed to hibernate, applies targeted fixes, and automatically re-attempts hibernation.


## The Problem

Windows hibernate fails intermittently on many laptops, particularly those with:

- **Fast Startup** enabled (conflicts with the hibernate kernel state mechanism)
- **Microsoft Teams** running (holds an active audio session via `msedgewebview2.exe`)
- **Windows Update** running in the background (`MoUsoCoreWorker.exe` holds a SYSTEM power request)
- **HP Print Scan Doctor** installed (registers a scheduled wake timer)

When hibernate fails, Windows turns the screen off for a few seconds, then returns to the lock screen with no explanation. Running this script immediately after a failed hibernate attempt identifies and clears the active blockers, then re-attempts hibernation automatically.

The underlying blockers are common across Windows 10/11 laptops from any manufacturer, but this script was developed and tested specifically on an ASUS PC running Windows 11, with root-cause analysis performed via `powercfg /sleepstudy`.
> Developed with AI assistance (Perplexity / Claude Sonnet).

## What It Does

The script performs 6 steps in sequence, displays colour-coded status messages in the console, and writes a full log to the same folder as the script.

| Step | Check | Action Taken |
|------|-------|-------------|
| 1 | **Fast Startup** (`HiberbootEnabled`) | Disables it permanently if enabled |
| 2 | **Active power requests** (`powercfg -requests`) | Logs all blockers by type (DISPLAY, SYSTEM, etc.) |
| 3 | **Edge WebView2 audio session** (`msedgewebview2.exe`) | Terminates all instances; warns if Teams is still open |
| 4 | **Windows Update Orchestrator** (`MoUsoCoreWorker` / `UsoSvc`) | Stops the service temporarily; **restarts it after** the attempt |
| 5 | **HP Print Scan Doctor wake timer** (scheduled task) | Disables the task temporarily; **re-enables it after** a successful resume |
| 6 | **Hibernate file integrity** (`hiberfil.sys`) | Enables hibernate if missing; sets type to `full` |

After completing all steps, the script waits 5 seconds, performs a final power request check, then issues `shutdown /h`.

If hibernate **succeeds**, the script resumes execution on wake, restarts any stopped services, re-enables any disabled tasks, and logs the result.

If hibernate **still fails**, the script reports which blockers remain active and provides next-step guidance.


## Requirements

- Windows 10 or Windows 11
- PowerShell 5.1 or later (included with Windows) - tested up to PowerShell 7.6.1
- Administrator privileges (the script self-elevates via UAC)


## Usage

First, download the `HibernateFix.ps1` file directly from this repository.

### Run directly (recommended)

Right-click `HibernateFix.ps1` → **Run with PowerShell**. The UAC prompt will appear; accept it. The script handles the rest.

> If Windows blocks the script with an execution policy error, run this once in an elevated PowerShell terminal:
> ```powershell
> Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
> ```

### Run from an elevated terminal

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\HibernateFix.ps1"
```
Replace `powershell` with `pwsh` to use PowerShell 7 if you have it installed


## Making It Double-Clickable

There are three options depending on your preference.

### Option 1 — `.bat` wrapper (simplest, no tools required)

Create a `HibernateFix.bat` file in the **same folder** as the script, containing:

```bat
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0HibernateFix.ps1"
```

Double-clicking the `.bat` file launches the script. Both files must remain in the same folder.

### Option 2 — Desktop shortcut (no extra files)

1. Right-click `HibernateFix.ps1` → **Create shortcut**
2. Right-click the shortcut → **Properties**
3. Set the **Target** field to:
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\full\path\to\HibernateFix.ps1"
   ```
4. Optionally set **Run** to *Minimised* if you don't want to see the Terminal window when running the script.

The `.ps1` file must stay in the same location. The shortcut can be placed or pinned anywhere.

### Option 3 — Compile to `.exe` with PS2EXE (standalone, no `.ps1` required)

[PS2EXE](https://github.com/MScholtes/PS2EXE) wraps the script into a self-contained executable with a UAC manifest embedded.

```powershell
# Install once
Install-Module ps2exe -Scope CurrentUser

# Compile
Invoke-PS2EXE .\HibernateFix.ps1 .\HibernateFix.exe -requireAdmin -noConsole:$false
```

The resulting `HibernateFix.exe` is fully standalone and double-clickable. The original `.ps1` is no longer needed.


## Configuration

Two variables at the top of the script can be adjusted to your preference:

```powershell
$CountdownSecs = 5   # Seconds to wait after fixes before hibernating
$ResumeMarker  = 30  # Elapsed-time threshold (seconds) used to detect a successful hibernate
```

The log directory defaults to the same folder as the script (`$PSScriptRoot`). To change it, update this line:

```powershell
$LogDir = $PSScriptRoot
```


## Log Output

A log file named `hibernate-fix_YYYY-MM-DD.log` is written to the same folder as the script. Each run appends to the day's log file. Example output:

```
================================================================
  HIBERNATE FIX SCRIPT
  Tuesday, 28 April 2026  --  19:57:41
  Log: C:\Users\<user>\Desktop\hibernate-fix_2026-04-28.log
================================================================

[2026-04-28 19:57:41] [INFO   ]  Running as: <username> on <computer name>
--- STEP 1 / 6 -- Fast Startup ---
[2026-04-28 19:57:41] [WARN   ]  Fast Startup is ENABLED (HiberbootEnabled=1).
[2026-04-28 19:57:41] [ACTION ]  Disabling Fast Startup...
[2026-04-28 19:57:41] [SUCCESS]  Fast Startup disabled.
--- STEP 3 / 6 -- Edge WebView2 / Teams Audio Blocker ---
[2026-04-28 19:57:42] [WARN   ]  4 msedgewebview2 process(es) found -- known audio session blocker.
[2026-04-28 19:57:42] [ACTION ]  Terminating msedgewebview2 processes...
[2026-04-28 19:57:43] [SUCCESS]  All msedgewebview2 processes terminated.
...
[2026-04-28 19:57:48] [SUCCESS]  --- MARKER: written before hibernate. If present after resume = SUCCESS ---
--- POST-HIBERNATE (2451.3 s elapsed) ---
[2026-04-28 21:38:39] [SUCCESS]  RESULT: SUCCESS -- system hibernated and resumed. Elapsed: 2451.3s
```


## Troubleshooting

**Hibernate still fails after running the script**

Run this in an elevated terminal immediately after the failure, while the blocking process is still running:

```powershell
powercfg -requests
```

Any non-`[NONE]` entry under `SYSTEM` or `DISPLAY` is the active blocker. Then check **Event Viewer → Windows Logs → System**, filtering by source `Kernel-Power`, for further detail.

**Teams keeps re-spawning `msedgewebview2` instantly**

The script cannot prevent Teams from respawning its WebView2 worker faster than the hibernate transition begins. Right-click the Teams tray icon → **Quit** before running the script for a reliable fix.

**Script exits immediately after UAC prompt**

This can happen if the script is run from a network or OneDrive-synced path. Copy the `.ps1` to a local folder (e.g., the Desktop) and run it from there.


## Contributing

Feel free to fork this repository and improve on the script further!


## License

MIT License — see [LICENSE](LICENSE) for full text.

Copyright (c) 2026 Stoil M. Stoilov
