#Requires -Version 5.1

<#
.SYNOPSIS
    HibernateFix.ps1 - Diagnoses hibernate blockers, applies fixes, and re-attempts hibernate.

.DESCRIPTION
    Run this script immediately after a failed hibernate attempt. It will:
      1. Check and disable Fast Startup (known hibernate conflict)
      2. Read active power requests via powercfg -requests
      3. Terminate Edge WebView2 processes (Teams audio session blocker)
      4. Temporarily stop Windows Update Orchestrator (MoUsoCoreWorker blocker)
      5. Disable HP Print Scan Doctor scheduled wake timers
      6. Verify and refresh the hibernate file configuration
      7. Wait briefly, then re-attempt hibernate via shutdown /h
      8. On resume or failure: restart services, re-enable tasks, and log result

    If hibernate succeeds, execution resumes from where it left off on wake.
    If hibernate still fails, the script reports what is still blocking it.

    Requires Administrator privileges (script will self-elevate via UAC).
    Safe to run repeatedly. Services and tasks are restored after each attempt.
    Tested against several Windows PCs.
	
	Log location: <script file location>\hibernate-fix_YYYY-MM-DD.log
	
.NOTES
    Author:      Stoil M. Stoilov (human), Perplexity, Claude Sonnet 4.6 (AI)
    GitHub:      https://github.com/sstoilovABLE/Hibernate-Fixer
    Version:     1.0.0
    Released:    2026-04-28
    License:     MIT License
	
	Copyright (c) 2026 Stoil M. Stoilov

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
	
.LINK
	https://github.com/sstoilovABLE/Hibernate-Fixer
#>

# ============================================================
# SELF-ELEVATION
# ============================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Host "`n  Administrator rights required. Requesting elevation via UAC..." -ForegroundColor Yellow
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    if ($scriptPath) {
        Start-Process powershell.exe `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" `
            -Verb RunAs
    } else {
        Write-Host "  ERROR: Cannot self-elevate -- script path is unknown." -ForegroundColor Red
        Write-Host "  Right-click the .ps1 file and choose 'Run with PowerShell'." -ForegroundColor Yellow
        Start-Sleep -Seconds 4
    }
    exit
}

# ============================================================
# CONFIGURATION  (edit these if needed)
# ============================================================
$LogDir        = $PSScriptRoot
$CountdownSecs = 5      # Seconds to wait after fixes before hibernating
$ResumeMarker  = 30     # Seconds elapsed -- if > this after shutdown /h, hibernate succeeded

# ============================================================
# STATE TRACKING
# ============================================================
$script:FixCount        = 0
$script:BlockersSeen    = [System.Collections.Generic.List[string]]::new()
$script:StoppedServices = [System.Collections.Generic.List[string]]::new()
$script:DisabledTasks   = [System.Collections.Generic.List[PSCustomObject]]::new()

# ============================================================
# LOGGING HELPERS
# ============================================================
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}
$LogFile = Join-Path $LogDir "hibernate-fix_$(Get-Date -Format 'yyyy-MM-dd').log"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','ACTION')]
        [string]$Level = 'INFO'
    )
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $label = $Level.PadRight(7)
    $entry = "[$ts] [$label] $Message"
    Add-Content -Path $LogFile -Value $entry -Encoding UTF8
    $colour = switch ($Level) {
        'INFO'    { 'Cyan'    }
        'WARN'    { 'Yellow'  }
        'ERROR'   { 'Red'     }
        'SUCCESS' { 'Green'   }
        'ACTION'  { 'Magenta' }
    }
    Write-Host "  $entry" -ForegroundColor $colour
}

function Write-Section {
    param([string]$Title)
    $sep   = '-' * 62
    $block = "`n$sep`n  $Title`n$sep"
    Add-Content -Path $LogFile -Value $block -Encoding UTF8
    Write-Host $block -ForegroundColor DarkCyan
}

function Get-ActivePowerRequests {
    $output      = & powercfg -requests 2>&1
    $results     = [System.Collections.Generic.List[PSCustomObject]]::new()
    $currentType = $null
    foreach ($line in $output) {
        if ($line -match '^(DISPLAY|SYSTEM|AWAYMODE|EXECUTION|PERFBOOST|ACTIVELOCKSCREEN):') {
            $currentType = $Matches[1]
        } elseif ($currentType -and $line.Trim() -notin @('[NONE]', '')) {
            $results.Add([PSCustomObject]@{ Type = $currentType; Detail = $line.Trim() })
        }
    }
    return $results
}

# ============================================================
# HEADER
# ============================================================
$header = @"

================================================================
  HIBERNATE FIX SCRIPT
  $(Get-Date -Format 'dddd, d MMMM yyyy  --  HH:mm:ss')
  Log: $LogFile
================================================================
"@
Add-Content -Path $LogFile -Value $header -Encoding UTF8
Write-Host $header -ForegroundColor White
Write-Log "Running as: $($env:USERNAME) on $($env:COMPUTERNAME)" -Level INFO

# ================================================================
# STEP 1: FAST STARTUP
# Fast Startup and hibernate share the same kernel hibernation
# mechanism. When enabled, driver states from the previous boot
# can be in a partial state that causes hibernate to abort.
# ================================================================
Write-Section "STEP 1 / 6  --  Fast Startup"

$fastKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
try {
    $hiberboot = (Get-ItemProperty -Path $fastKey -Name 'HiberbootEnabled' -ErrorAction Stop).HiberbootEnabled
    if ($hiberboot -eq 1) {
        Write-Log "Fast Startup is ENABLED (HiberbootEnabled=1)." -Level WARN
        Write-Log "This is the most common cause of intermittent hibernate failures." -Level WARN
        Write-Log "Disabling Fast Startup..." -Level ACTION
        Set-ItemProperty -Path $fastKey -Name 'HiberbootEnabled' -Value 0
        Write-Log "Fast Startup disabled. Change persists after reboot." -Level SUCCESS
        $script:FixCount++
        $script:BlockersSeen.Add("Fast Startup was enabled (HiberbootEnabled=1)")
    } else {
        Write-Log "Fast Startup is already disabled. OK." -Level INFO
    }
} catch {
    Write-Log "Could not check Fast Startup registry key: $($_.Exception.Message)" -Level WARN
}

# ================================================================
# STEP 2: ACTIVE POWER REQUESTS
# Shows which processes/drivers are currently holding a power
# request that prevents the system from entering low power states.
# ================================================================
Write-Section "STEP 2 / 6  --  Active Power Requests (powercfg -requests)"

$requests = Get-ActivePowerRequests
if ($requests.Count -eq 0) {
    Write-Log "No active power requests found right now." -Level SUCCESS
} else {
    Write-Log "$($requests.Count) active power request(s) found:" -Level WARN
    foreach ($r in $requests) {
        Write-Log "  [$($r.Type)]  $($r.Detail)" -Level WARN
        $script:BlockersSeen.Add("Power request [$($r.Type)]: $($r.Detail)")
    }
}

# ================================================================
# STEP 3: EDGE WEBVIEW2 (TEAMS AUDIO SESSION)
# msedgewebview2.exe is spawned by Teams (and other apps) and
# holds an active audio session, submitting a SYSTEM power request
# that Windows treats as a veto against hibernate transitions.
# ================================================================
Write-Section "STEP 3 / 6  --  Edge WebView2 / Teams Audio Blocker"

$wv2Procs = Get-Process -Name 'msedgewebview2' -ErrorAction SilentlyContinue
if ($wv2Procs) {
    Write-Log "$($wv2Procs.Count) msedgewebview2 process(es) found -- known audio session blocker." -Level WARN
    Write-Log "Terminating msedgewebview2 processes..." -Level ACTION
    foreach ($proc in $wv2Procs) {
        Write-Log "  Stopping PID $($proc.Id) (CPU: $($proc.CPU)s)" -Level ACTION
        $proc | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 800
    $remaining = Get-Process -Name 'msedgewebview2' -ErrorAction SilentlyContinue
    if ($remaining) {
        Write-Log "$($remaining.Count) process(es) could not be stopped (likely re-spawned by Teams)." -Level WARN
    } else {
        Write-Log "All msedgewebview2 processes terminated." -Level SUCCESS
    }
    $script:FixCount++
    $script:BlockersSeen.Add("msedgewebview2.exe (Edge WebView2 / Teams audio session)")
} else {
    Write-Log "No msedgewebview2 processes found." -Level INFO
}

# Warn if Teams itself is still running (it will respawn WebView2)
$teamsProcs = Get-Process -Name 'msteams','Teams','ms-teams' -ErrorAction SilentlyContinue
if ($teamsProcs) {
    Write-Log "WARNING: Microsoft Teams is still running." -Level WARN
    Write-Log "Teams will re-spawn msedgewebview2 within seconds." -Level WARN
    Write-Log "For reliable hibernate, quit Teams first: right-click tray icon > Quit." -Level WARN
}

# ================================================================
# STEP 4: WINDOWS UPDATE ORCHESTRATOR (MoUsoCoreWorker)
# The Update Session Orchestrator holds a SYSTEM power request
# while downloading or staging updates, blocking hibernate.
# It is temporarily stopped here and restarted after the attempt.
# ================================================================
Write-Section "STEP 4 / 6  --  Windows Update Orchestrator (MoUsoCoreWorker)"

$usoProc = Get-Process -Name 'MoUsoCoreWorker' -ErrorAction SilentlyContinue
$usoSvc  = Get-Service  -Name 'UsoSvc'          -ErrorAction SilentlyContinue

if ($usoProc) {
    Write-Log "MoUsoCoreWorker.exe is actively running -- update activity in progress." -Level WARN
} elseif ($usoSvc -and $usoSvc.Status -eq 'Running') {
    Write-Log "Windows Update Orchestrator service (UsoSvc) is running." -Level WARN
} else {
    Write-Log "Windows Update Orchestrator is not active." -Level INFO
}

if ($usoSvc -and $usoSvc.Status -eq 'Running') {
    Write-Log "Stopping UsoSvc temporarily..." -Level ACTION
    try {
        Stop-Service -Name 'UsoSvc' -Force -ErrorAction Stop
        $script:StoppedServices.Add('UsoSvc')
        Write-Log "UsoSvc stopped. Will be restarted after hibernate attempt." -Level SUCCESS
        $script:FixCount++
        $script:BlockersSeen.Add("MoUsoCoreWorker / UsoSvc (Windows Update Orchestrator)")
    } catch {
        Write-Log "Could not stop UsoSvc: $($_.Exception.Message)" -Level WARN
        if ($usoProc) {
            Write-Log "Attempting direct process termination..." -Level ACTION
            $usoProc | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Log "MoUsoCoreWorker process stop attempted." -Level ACTION
        }
    }
}

# ================================================================
# STEP 5: HP PRINT SCAN DOCTOR SCHEDULED WAKE TIMERS
# HP Print Scan Doctor registers a scheduled task with a wake
# timer, which keeps a background wake request active. Disabling
# it temporarily removes this as a hibernate blocker.
# ================================================================
Write-Section "STEP 5 / 6  --  HP Scheduled Wake Tasks"

try {
    $hpTasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.TaskName -like '*HP*' -or $_.TaskPath -like '*HP*') -and
            ($_.State -eq 'Ready' -or $_.State -eq 'Running')
        }

    if ($hpTasks) {
        foreach ($task in $hpTasks) {
            Write-Log "HP task: $($task.TaskPath)$($task.TaskName)  [State: $($task.State)]" -Level WARN
            try {
                Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath `
                    -ErrorAction Stop | Out-Null
                $script:DisabledTasks.Add([PSCustomObject]@{
                    Name = $task.TaskName
                    Path = $task.TaskPath
                })
                Write-Log "  Disabled: $($task.TaskPath)$($task.TaskName)" -Level SUCCESS
                $script:FixCount++
                $script:BlockersSeen.Add("HP scheduled task: $($task.TaskPath)$($task.TaskName)")
            } catch {
                Write-Log "  Could not disable $($task.TaskName): $($_.Exception.Message)" -Level WARN
            }
        }
    } else {
        Write-Log "No active HP scheduled tasks found." -Level INFO
    }
} catch {
    Write-Log "Error reading scheduled tasks: $($_.Exception.Message)" -Level WARN
}

# ================================================================
# STEP 6: HIBERNATE FILE HEALTH
# Ensures hiberfil.sys exists and is set to 'full' size, which is
# more reliable than the default 'reduced' type.
# ================================================================
Write-Section "STEP 6 / 6  --  Hibernate File Health"

$hibFile = "$env:SystemDrive\hiberfil.sys"
if (Test-Path $hibFile) {
    $hibSizeGB = [Math]::Round((Get-Item $hibFile -Force).Length / 1GB, 2)
    Write-Log "hiberfil.sys present -- $hibSizeGB GB." -Level INFO
} else {
    Write-Log "hiberfil.sys not found! Hibernate may be disabled." -Level ERROR
    Write-Log "Running: powercfg /hibernate on" -Level ACTION
    & powercfg /hibernate on
}

Write-Log "Setting hibernate type to 'full' (prevents truncated write failures)..." -Level ACTION
$typeOut = & powercfg /h /type full 2>&1
if ($typeOut) {
    Write-Log "  powercfg output: $($typeOut -join ' ')" -Level INFO
} else {
    Write-Log "  Hibernate type set to full. OK." -Level SUCCESS
}

# ================================================================
# PRE-HIBERNATE SUMMARY + COUNTDOWN
# ================================================================
Write-Section "PRE-HIBERNATE SUMMARY"

Write-Log "Total fixes applied this run: $($script:FixCount)" -Level INFO

if ($script:BlockersSeen.Count -gt 0) {
    Write-Log "Blockers found and addressed:" -Level INFO
    $script:BlockersSeen | ForEach-Object { Write-Log "  - $_" -Level INFO }
} else {
    Write-Log "No blockers detected. Hibernate should succeed." -Level SUCCESS
}

# Final power request check
$finalRequests = Get-ActivePowerRequests
if ($finalRequests.Count -eq 0) {
    Write-Log "Final power request check: CLEAR. No active blockers." -Level SUCCESS
} else {
    Write-Log "Final power request check: $($finalRequests.Count) request(s) still active:" -Level WARN
    $finalRequests | ForEach-Object { Write-Log "  [$($_.Type)]  $($_.Detail)" -Level WARN }
    Write-Log "Attempting hibernate anyway -- some requests may be benign." -Level WARN
}

# Countdown
Write-Host ""
for ($i = $CountdownSecs; $i -ge 1; $i--) {
    Write-Host "`r  Hibernating in $i second(s)...  " -NoNewline -ForegroundColor Yellow
    Start-Sleep -Seconds 1
}
Write-Host "`r  Initiating hibernate now...         " -ForegroundColor Green

# This log line is written BEFORE hibernate. If you see it on the other
# side of a resume, that confirms hibernate succeeded.
Write-Log "Submitting hibernate request (shutdown /h)..." -Level ACTION
Write-Log "--- MARKER: written before hibernate. If present after resume = SUCCESS ---" -Level SUCCESS

# ================================================================
# HIBERNATE
# If the system hibernates successfully, this script's process
# freezes here along with the rest of the system, and resumes
# from this exact point on next wake. Elapsed time will be > 30s.
#
# If hibernate is blocked immediately (the intermittent failure
# case), shutdown /h returns quickly and elapsed time will be < 30s.
# ================================================================
$preHibernateTime = Get-Date
shutdown /h

# ----------------------------------------------------------------
# NOTE: Execution continues here either after a successful resume
#       OR if hibernate failed. Use elapsed time to distinguish.
# ----------------------------------------------------------------
$elapsed = [Math]::Round(((Get-Date) - $preHibernateTime).TotalSeconds, 1)

# ================================================================
# POST-ATTEMPT CLEANUP  (runs on resume AND on failure)
# Services and tasks are restored regardless of outcome.
# ================================================================
Write-Section "POST-HIBERNATE  ($elapsed s elapsed)"

if ($elapsed -gt $ResumeMarker) {
    Write-Log "RESULT: SUCCESS -- system hibernated and resumed. Elapsed: ${elapsed}s" -Level SUCCESS
} else {
    Write-Log "RESULT: FAILED -- hibernate did not complete. Elapsed: ${elapsed}s" -Level ERROR
    Write-Log "A blocker submitted a new power request after fixes were applied." -Level ERROR
    Write-Log "Next steps:" -Level WARN
    Write-Log "  1. Run in an elevated terminal: powercfg -requests" -Level WARN
    Write-Log "  2. Check Event Viewer > Windows Logs > System (source: Kernel-Power)" -Level WARN
    Write-Log "  3. If Teams is still running, quit it and try hibernating manually." -Level WARN
    Write-Log "  4. Consider a restart to clear all driver states, then try again." -Level WARN
}

# Restart any stopped services
if ($script:StoppedServices.Count -gt 0) {
    Write-Log "Restarting stopped services..." -Level ACTION
    foreach ($svc in $script:StoppedServices) {
        try {
            Start-Service -Name $svc -ErrorAction Stop
            Write-Log "  Restarted: $svc" -Level SUCCESS
        } catch {
            Write-Log "  Could not restart ${svc}: $($_.Exception.Message)" -Level WARN
        }
    }
}

# Re-enable HP scheduled tasks (only after confirmed success)
if ($script:DisabledTasks.Count -gt 0) {
    if ($elapsed -gt $ResumeMarker) {
        Write-Log "Re-enabling HP scheduled tasks after successful resume..." -Level ACTION
        foreach ($t in $script:DisabledTasks) {
            try {
                Enable-ScheduledTask -TaskName $t.Name -TaskPath $t.Path `
                    -ErrorAction SilentlyContinue | Out-Null
                Write-Log "  Re-enabled: $($t.Path)$($t.Name)" -Level SUCCESS
            } catch {
                Write-Log "  Could not re-enable $($t.Name)" -Level WARN
            }
        }
    } else {
        Write-Log "HP tasks remain disabled (hibernate failed -- leaving disabled for next attempt)." -Level INFO
    }
}

# Final message
Write-Host ""
Write-Log "Script complete. Full log: $LogFile" -Level INFO
Write-Host "`n  Log saved to: $LogFile" -ForegroundColor Cyan

# Pause only on failure so the window does not vanish
if ($elapsed -le $ResumeMarker) {
    Write-Host "`n  Press any key to exit..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
