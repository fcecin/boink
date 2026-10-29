# install.ps1 — Windows installer for boink.
#   install.ps1 [install|status|uninstall] [-Prefix DIR] [-AddPath]
# Copies boink.cmd + boink.ps1 into a directory on your PATH. Idempotent.
[CmdletBinding()]
param(
  [ValidateSet('install', 'status', 'uninstall')]
  [string]$Command = 'install',
  [string]$Prefix = (Join-Path $env:USERPROFILE '.local\bin'),
  [switch]$AddPath
)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $MyInvocation.MyCommand.Path

function On-Path {
  $p = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $parts = $p -split ';' | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
  $want = $Prefix.TrimEnd('\')
  return [bool]($parts -contains $want)
}

switch ($Command) {
  'install' {
    New-Item -ItemType Directory -Force -Path $Prefix | Out-Null
    Copy-Item -Force (Join-Path $Repo 'boink.cmd') $Prefix
    Copy-Item -Force (Join-Path $Repo 'boink.ps1') $Prefix
    "linked   $Prefix\boink.cmd -> $Repo\boink.ps1"
    $hooks = Join-Path $env:USERPROFILE '.boink\hooks'
    New-Item -ItemType Directory -Force -Path $hooks | Out-Null
    if (Test-Path (Join-Path $Repo 'hooks\on-boink.example.ps1')) {
      Copy-Item -Force (Join-Path $Repo 'hooks\on-boink.example.ps1') $hooks
      "hook     example hook at $hooks\on-boink.example.ps1 (rename to enable)"
    }
    if ($AddPath -and -not (On-Path)) {
      $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
      [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $Prefix), 'User')
      "path     added $Prefix to the user PATH"
    }
    elseif (-not (On-Path)) {
      "path     add $Prefix to your PATH, or re-run with -AddPath"
    }
    else {
      "path     $Prefix is on PATH"
    }
    'done     arm a monitor with: boink arm --tag <name>'
  }
  'status' {
    "repo     $Repo"
    if (Test-Path (Join-Path $Prefix 'boink.cmd')) { "skill    boink installed at $Prefix\boink.cmd" }
    else { 'skill    not installed' }
    if (On-Path) { "path     $Prefix on PATH" } else { "path     $Prefix NOT on PATH" }
  }
  'uninstall' {
    Remove-Item -Force (Join-Path $Prefix 'boink.cmd'), (Join-Path $Prefix 'boink.ps1') -ErrorAction SilentlyContinue
    "removed  $Prefix\boink.cmd"
  }
}
