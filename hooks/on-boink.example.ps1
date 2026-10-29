# Example BOINK hook (PowerShell). Runs on every BOINK event with
# $env:BOINK_SEQ, $env:BOINK_TS, $env:BOINK_MONITORS available.
#
# This is where you inject the BOINK prompt into YOUR harness — a watched file,
# a pipe, or the harness's own notification channel.
Write-Output ("BOINK {0} (monitors={1})" -f $env:BOINK_SEQ, $env:BOINK_MONITORS)
