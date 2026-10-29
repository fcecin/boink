# boink test suite (PowerShell, Windows). Runs the state machine, the hook
# notifier, the daemon fallback, and the REAL Task Scheduler backend to prove a
# BOINK actually fires and is delivered.
#
#   pwsh -NoProfile -ExecutionPolicy Bypass -File tests/run.ps1
$ErrorActionPreference = 'Continue'
$BOINK = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'boink.ps1'
$psExe = (Get-Process -Id $PID).Path
$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ('boink-test-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $TMP | Out-Null

$script:PASS = 0
$script:FAIL = 0
function ok($m)  { $script:PASS++; "ok   $m" }
function bad($m) { $script:FAIL++; "FAIL $m" }

function Run-Boink([string]$dir, [string[]]$rest) {
  $env:BOINK_DIR = $dir
  $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File $BOINK @rest 2>&1
  $env:BOINK_DIR = $null
  return ($out -join "`n")
}

function New-State([string]$name) {
  $d = Join-Path $TMP $name
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  return $d
}

function Install-Hook([string]$dir, [string]$sentinel) {
  $h = Join-Path $dir 'hooks'
  New-Item -ItemType Directory -Force -Path $h | Out-Null
  Set-Content -LiteralPath (Join-Path $h 'on-boink.ps1') -Value "`$env:BOINK_SEQ | Add-Content -LiteralPath '$sentinel'"
}

function Count-Lines([string]$path) {
  if (Test-Path -LiteralPath $path) {
    return @(Get-Content -LiteralPath $path | Where-Object { $_ -ne '' }).Count
  }
  return 0
}
function Count-Boinks([string]$path) {
  if (Test-Path -LiteralPath $path) {
    return @(Select-String -LiteralPath $path -Pattern '^BOINK ').Count
  }
  return 0
}

# ---------------------------------------------------------------------------
# 1. core state machine (no scheduler)
# ---------------------------------------------------------------------------
$env:BOINK_SCHEDULER = 'none'
$s1 = New-State 's1'
Run-Boink $s1 @('arm','--tag','build-1') | Out-Null
if ((Count-Lines (Join-Path $s1 'monitors')) -eq 1) { ok 'arm registers a monitor' } else { bad 'arm registers a monitor' }
Run-Boink $s1 @('arm','--tag','build-1') | Out-Null
if ((Count-Lines (Join-Path $s1 'monitors')) -eq 1) { ok 'arm is idempotent' } else { bad 'arm is idempotent' }

Run-Boink $s1 @('tick') | Out-Null
Run-Boink $s1 @('tick') | Out-Null
$log1 = Get-Content -LiteralPath (Join-Path $s1 'boink.log') -Raw
if ($log1 -match 'BOINK seq=2 ') { ok 'tick appends a BOINK event' } else { bad 'tick appends a BOINK event' }
if ((Get-Content (Join-Path $s1 'seq') -Raw).Trim() -eq '2') { ok 'seq advances' } else { bad 'seq advances' }

Run-Boink $s1 @('disarm','build-1') | Out-Null
if ((Count-Lines (Join-Path $s1 'monitors')) -eq 0) { ok 'disarm removes the monitor' } else { bad 'disarm removes the monitor' }
$seqBefore = (Get-Content (Join-Path $s1 'seq') -Raw).Trim()
Run-Boink $s1 @('tick') | Out-Null
if ((Get-Content (Join-Path $s1 'seq') -Raw).Trim() -eq $seqBefore) { ok 'tick is silent at zero monitors' } else { bad 'tick is silent at zero monitors' }

# ---------------------------------------------------------------------------
# 2. hook notifier (no scheduler)
# ---------------------------------------------------------------------------
$s2 = New-State 's2'; $sent2 = Join-Path $TMP 'sent2'
Install-Hook $s2 $sent2
Run-Boink $s2 @('arm','--tag','hook-test') | Out-Null
Run-Boink $s2 @('tick') | Out-Null
if ((Count-Lines $sent2) -ge 1) { ok 'hook fired on tick' } else { bad 'hook fired on tick (sentinel empty)' }

# ---------------------------------------------------------------------------
# 3. daemon fallback notifier (fast, real loop)
# ---------------------------------------------------------------------------
$s3 = New-State 's3'; $sent3 = Join-Path $TMP 'sent3'
Install-Hook $s3 $sent3
Run-Boink $s3 @('arm','--tag','daemon-test','--interval','1') | Out-Null
$env:BOINK_DIR = $s3; $env:BOINK_SCHEDULER = 'none'
$dp = Start-Process -FilePath $psExe -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`" daemon" -f $BOINK) -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 4
Stop-Process -Id $dp.Id -Force -ErrorAction SilentlyContinue
$dp.WaitForExit()
$env:BOINK_DIR = $null
$n3 = Count-Boinks (Join-Path $s3 'boink.log')
if ($n3 -ge 2) { ok "daemon emitted >=2 BOINKs (got $n3)" } else { bad "daemon emitted >=2 BOINKs (got $n3)" }
if ((Count-Lines $sent3) -ge 1) { ok 'daemon hook fired' } else { bad 'daemon hook fired (sentinel empty)' }

# ---------------------------------------------------------------------------
# 4. REAL Task Scheduler fires a BOINK
# ---------------------------------------------------------------------------
$env:BOINK_SCHEDULER = $null
$s4 = New-State 's4'; $sent4 = Join-Path $TMP 'sent4'
Install-Hook $s4 $sent4
try {
  '--- schtasks arm output ---'
  Run-Boink $s4 @('arm','--tag','schtasks-fire','--interval','10')
  '--- task state after arm ---'
  Get-ScheduledTask -TaskName 'Boink' -ErrorAction SilentlyContinue | Select-Object TaskName,State,LastRunTime,LastTaskResult | Format-List | Out-String | Write-Output
  'ok   waiting 30s for real Task Scheduler to fire...'
  Start-Sleep -Seconds 30
  '--- task state after wait ---'
  Get-ScheduledTask -TaskName 'Boink' -ErrorAction SilentlyContinue | Select-Object TaskName,State,LastRunTime,LastTaskResult | Format-List | Out-String | Write-Output
  '--- boink.log ---'
  if (Test-Path (Join-Path $s4 'boink.log')) { Get-Content -LiteralPath (Join-Path $s4 'boink.log') | ForEach-Object { "  $_" } }
  $n4 = Count-Boinks (Join-Path $s4 'boink.log')
  if ($n4 -ge 1) { ok "real Task Scheduler fired a BOINK (got $n4)" } else { bad "real Task Scheduler fired a BOINK (got $n4)" }
  if ((Count-Lines $sent4) -ge 1) { ok 'real Task Scheduler hook delivered' } else { bad 'real Task Scheduler hook delivered (sentinel empty)' }
}
finally {
  Run-Boink $s4 @('off') | Out-Null
}

''
'{0} passed, {1} failed' -f $script:PASS, $script:FAIL
if ($script:FAIL -ne 0) { exit 1 }
