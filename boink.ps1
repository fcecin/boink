# boink.ps1 — Windows-native BOINK watchdog scheduler (PowerShell 5.1+).
#
# Harness-agnostic replacement for Claude Code's CronCreate("BOINK") pattern on
# Windows. Registers a Task Scheduler job that fires `boink.ps1 tick` on
# wall-clock time; each tick appends a BOINK event to the log and runs any hooks
# you install, so a broken monitor can't starve you of silence.
#
# License: Unlicense (public domain). See UNLICENSE.
$ErrorActionPreference = 'Stop'
$BOINK_VERSION = '0.1.0'

$script:Self = $PSCommandPath

$script:StateDir = if ($env:BOINK_DIR) { $env:BOINK_DIR } else { Join-Path $env:USERPROFILE '.boink' }
$script:DefaultInterval = if ($env:BOINK_INTERVAL) { [int]$env:BOINK_INTERVAL } else { 300 }
$script:IsWin = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT

# ---- parse args: pull --dir / --dir= out of the whole list -------------------
$rest = New-Object System.Collections.Generic.List[string]
$i = 0
while ($i -lt $args.Count) {
  $a = [string]$args[$i]
  if ($a -eq '--dir') {
    $i++
    if ($i -ge $args.Count) { throw '--dir needs a path' }
    $script:StateDir = [string]$args[$i]
  }
  elseif ($a -like '--dir=*') {
    $script:StateDir = $a.Substring(6)
  }
  else {
    $rest.Add($a)
  }
  $i++
}
$Command = if ($rest.Count -gt 0) { $rest[0] } else { 'help' }
$CommandArgs = if ($rest.Count -gt 1) { $rest.GetRange(1, $rest.Count - 1) } else { @() }

# ---- state init --------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
$monFile  = Join-Path $script:StateDir 'monitors'
$logFile  = Join-Path $script:StateDir 'boink.log'
$seqFile  = Join-Path $script:StateDir 'seq'
$lastFile = Join-Path $script:StateDir 'last'
foreach ($f in @($monFile, $logFile)) {
  if (-not (Test-Path -LiteralPath $f)) { New-Item -ItemType File -Force -Path $f | Out-Null }
}
if (-not (Test-Path -LiteralPath $seqFile)) { '0' | Set-Content -LiteralPath $seqFile }

function Now-Iso { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Get-MonitorCount {
  $c = Get-Content -LiteralPath $monFile -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' }
  return @($c).Count
}
function Set-Monitors([string[]]$items) {
  [System.IO.File]::WriteAllLines($monFile, $items)
}
function Get-Interval {
  if (Test-Path -LiteralPath (Join-Path $script:StateDir 'interval')) {
    $v = (Get-Content -LiteralPath (Join-Path $script:StateDir 'interval') -Raw).Trim()
    $n = 0
    if ([int]::TryParse($v, [ref]$n) -and $n -ge 1) { return $n }
  }
  return $script:DefaultInterval
}
function Get-Backend {
  if ($env:BOINK_BACKEND) { return $env:BOINK_BACKEND }
  if ($script:IsWin) { return 'schtasks' }
  return 'daemon'
}

# ---- commands ----------------------------------------------------------------
function Invoke-Arm {
  $tag = $null; $interval = $null
  $i = 0
  while ($i -lt $CommandArgs.Count) {
    $a = [string]$CommandArgs[$i]
    if ($a -eq '--tag') { $i++; $tag = [string]$CommandArgs[$i] }
    elseif ($a -like '--tag=*') { $tag = $a.Substring(6) }
    elseif ($a -eq '--interval') { $i++; $interval = [string]$CommandArgs[$i] }
    elseif ($a -like '--interval=*') { $interval = $a.Substring(11) }
    else { $tag = $a }
    $i++
  }
  if (-not $tag) { $tag = 'session-' + (Now-Iso) }
  $existing = @(Get-Content -LiteralPath $monFile -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' })
  if ($existing -contains $tag) {
    'armed    {0} (already live)' -f $tag
  }
  else {
    Add-Content -LiteralPath $monFile -Value $tag
    'armed    {0}' -f $tag
  }
  if ($interval) { $interval | Set-Content -LiteralPath (Join-Path $script:StateDir 'interval') }
  Install-Scheduler
}

function Invoke-Disarm {
  if ($CommandArgs.Count -gt 0 -and $CommandArgs[0] -eq '--all') {
    Set-Monitors @()
    'disarmed all'
    return
  }
  if ($CommandArgs.Count -eq 0) { throw 'disarm needs a tag or --all' }
  foreach ($t in $CommandArgs) {
    $lines = @(Get-Content -LiteralPath $monFile -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' })
    if ($lines -contains $t) {
      Set-Monitors ([string[]]@($lines | Where-Object { $_ -ne $t }))
      'disarmed {0}' -f $t
    }
    else {
      'not-live {0}' -f $t
    }
  }
}

function Invoke-Sweep {
  'live monitors: {0}' -f (Get-MonitorCount)
  Get-Content -LiteralPath $monFile -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' } | ForEach-Object { '  - ' + $_ }
  'reap a finished monitor: boink disarm <tag>   (or boink disarm --all)'
}

function Invoke-Off {
  Set-Monitors @()
  Remove-Scheduler
  'off      no live monitors; scheduler removed'
}

function Invoke-Hooks([int]$seq, [string]$ts, [int]$count) {
  $dir = Join-Path $script:StateDir 'hooks'
  if (-not (Test-Path -LiteralPath $dir)) { return }
  $env:BOINK_SEQ = "$seq"; $env:BOINK_TS = $ts; $env:BOINK_MONITORS = "$count"
  Get-ChildItem -LiteralPath $dir -File | Sort-Object Name | ForEach-Object {
    $hfile = $_
    try {
      switch ($hfile.Extension.ToLower()) {
        '.ps1' { & $hfile.FullName }
        '.cmd' { & cmd.exe /c ('"{0}"' -f $hfile.FullName) }
        '.bat' { & cmd.exe /c ('"{0}"' -f $hfile.FullName) }
        '.sh'  { if (Get-Command sh -ErrorAction SilentlyContinue) { & sh $hfile.FullName } }
        default { & $hfile.FullName }
      }
    }
    catch { }
  }
}

function Invoke-Tick {
  $count = Get-MonitorCount
  if ($count -eq 0) {
    Write-Error 'tick: no live monitors' -ErrorAction Continue
    return
  }
  $seq = [int]((Get-Content -LiteralPath $seqFile -Raw).Trim()) + 1
  "$seq" | Set-Content -LiteralPath $seqFile
  $ts = Now-Iso
  'BOINK seq={0} ts={1} monitors={2}' -f $seq, $ts, $count | Add-Content -LiteralPath $logFile
  'seq={0} ts={1} monitors={2}' -f $seq, $ts, $count | Set-Content -LiteralPath $lastFile
  Invoke-Hooks $seq $ts $count
}

function Show-Status {
  'boink {0}' -f $BOINK_VERSION
  '  dir:        {0}' -f $script:StateDir
  '  interval:   {0}s' -f (Get-Interval)
  '  monitors:   {0}' -f (Get-MonitorCount)
  Get-Content -LiteralPath $monFile -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' } | ForEach-Object { '    - ' + $_ }
  if (Test-Path -LiteralPath $lastFile) {
    '  last:       {0}' -f (Get-Content -LiteralPath $lastFile -Raw).Trim()
  }
  else { '  last:       never' }
  '  scheduler:  {0}' -f (Get-SchedulerStatus)
  if (Test-Path -LiteralPath $logFile) {
    '  log tail:'
    Get-Content -LiteralPath $logFile -Tail 5 | ForEach-Object { '    ' + $_ }
  }
}

function Start-Daemon {
  $interval = Get-Interval
  'boink daemon: ticking every {0}s (ctrl-c to stop)' -f $interval
  while ($true) {
    Invoke-Tick *> $null
    Start-Sleep -Seconds $interval
  }
}

# ---- scheduler ---------------------------------------------------------------
function Install-Scheduler {
  if ($env:BOINK_SCHEDULER -eq 'none') {
    'scheduler skipped (BOINK_SCHEDULER=none)'
    return
  }
  switch (Get-Backend) {
    'schtasks' { Install-Schtasks }
    'daemon'   { 'daemon   no persistent scheduler here; run: boink daemon' }
    default    { throw ('unknown backend: ' + (Get-Backend)) }
  }
}

function Remove-Scheduler {
  if ($env:BOINK_SCHEDULER -eq 'none') {
    'scheduler skipped (BOINK_SCHEDULER=none)'
    return
  }
  switch (Get-Backend) {
    'schtasks' {
      Stop-ScheduledTask -TaskName 'Boink' -ErrorAction SilentlyContinue
      Unregister-ScheduledTask -TaskName 'Boink' -Confirm:$false -ErrorAction SilentlyContinue
      'schtasks removed'
    }
    'daemon' { 'daemon   stop the background boink daemon process' }
  }
}

function Get-SchedulerStatus {
  switch (Get-Backend) {
    'schtasks' {
      $t = Get-ScheduledTask -TaskName 'Boink' -ErrorAction SilentlyContinue
      if ($t) { 'schtasks (registered)' } else { 'schtasks (not registered)' }
    }
    'daemon' { 'daemon (manual)' }
  }
}

function Install-Schtasks {
  $interval = Get-Interval
  $taskName = 'Boink'
  # Task Scheduler rejects repetition intervals below one minute (PT1M); clamp.
  $repSeconds = [Math]::Max($interval, 60)
  $arg = '-NoProfile -ExecutionPolicy Bypass -File "{0}" --dir "{1}" tick' -f $script:Self, $script:StateDir
  $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5) -RepetitionInterval (New-TimeSpan -Seconds $repSeconds) -RepetitionDuration (New-TimeSpan -Days 3650)
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
  # S4U runs for the current user without a password and without needing an
  # interactive logon session — the common case on headless CI runners.
  $principal = New-ScheduledTaskPrincipal -UserId ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME) -LogonType S4U -RunLevel Limited
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
  Start-ScheduledTask -TaskName $taskName | Out-Null
  'schtasks installed ''{0}'' (every {1}s)' -f $taskName, $repSeconds
}

# ---- dispatch ----------------------------------------------------------------
switch ($Command) {
  'arm'        { Invoke-Arm }
  'disarm'     { Invoke-Disarm }
  'rm'         { Invoke-Disarm }
  'sweep'      { Invoke-Sweep }
  'status'     { Show-Status }
  'tick'       { Invoke-Tick }
  'off'        { Invoke-Off }
  'stop'       { Invoke-Off }
  'daemon'     { Start-Daemon }
  'watch'      { Get-Content -LiteralPath $logFile -Tail 0 -Wait }
  'log'        { Get-Content -LiteralPath $logFile -Tail 50 }
  'version'    { 'boink {0}' -f $BOINK_VERSION }
  '--version'  { 'boink {0}' -f $BOINK_VERSION }
  'scheduler'  {
    $a = if ($CommandArgs.Count -gt 0) { $CommandArgs[0] } else { 'status' }
    switch ($a) {
      'install'  { Install-Scheduler }
      'remove'   { Remove-Scheduler }
      'uninstall'{ Remove-Scheduler }
      'status'   { Get-SchedulerStatus }
      'backend'  { Get-Backend }
      default    { throw ('scheduler: unknown action ' + $a) }
    }
  }
  default {
@'
boink — a wall-clock watchdog that keeps your monitors honest, outside Claude.

usage: boink <command> [options]

commands:
  arm [--tag NAME] [--interval SECS]   register a live monitor, arm the scheduler
  disarm TAG... | --all                reap finished monitors
  sweep                                list live monitors (never auto-reaps)
  status                               show state + scheduler + log tail
  tick                                 emit a BOINK event if monitors are live
  off                                  disarm all + remove the scheduler
  daemon                               foreground self-loop scheduler (fallback)
  watch                                tail the BOINK event log
  log                                  show the BOINK event log
  scheduler install|remove|status|backend
  version                              print version

env:
  BOINK_DIR        state dir (default ~/.boink)
  BOINK_INTERVAL   default interval seconds (default 300)
  BOINK_SCHEDULER  'none' disables scheduler management (tests)
  BOINK_BACKEND    force schtasks|daemon
'@
  }
}
