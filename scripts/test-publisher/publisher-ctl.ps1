# Control script for the long-running test publisher (Windows).
#
#   .\publisher-ctl.ps1 start    # launch detached, runs indefinitely, auto-restarts on crash
#   .\publisher-ctl.ps1 stop     # stop supervisor + publisher
#   .\publisher-ctl.ps1 status   # show PIDs and the last log lines
#   .\publisher-ctl.ps1 log      # tail the log
#
# From WSL:  powershell.exe -ExecutionPolicy Bypass -File "C:\...\publisher-ctl.ps1" start
#
# The MQTT password comes from the git-ignored .env next to the script (MQTT_PASS=...).
# Log: %TEMP%\ruuvi-publisher.log (small: --quiet logs discoveries + 15-min heartbeats).

param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "stop", "status", "log", "run")]
    [string]$Command = "status"
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Publisher = Join-Path $ScriptDir "ruuvi_test_publisher.py"
$LogFile   = Join-Path $env:TEMP "ruuvi-publisher.log"

function Get-SupervisorProc {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like "*publisher-ctl.ps1*run*" -and $_.ProcessId -ne $PID }
}
function Get-PublisherProc {
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
        Where-Object { $_.CommandLine -like "*ruuvi_test_publisher*" }
}

switch ($Command) {

    "run" {
        # PS 5.1 redirects as UTF-16 by default — force UTF-8 so the log is readable
        $PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
        # supervisor loop — restart the publisher if it ever exits
        while ($true) {
            Add-Content $LogFile "supervisor: starting publisher $(Get-Date -Format o)"
            & python $Publisher --quiet `
                --mqtt-host petzval.dy.fi --mqtt-port 8883 --tls `
                --mqtt-user site-test --site test *>> $LogFile
            Add-Content $LogFile "supervisor: publisher exited (code $LASTEXITCODE), restarting in 10s"
            Start-Sleep -Seconds 10
        }
    }

    "start" {
        if (Get-SupervisorProc) {
            Write-Output "already running (supervisor PID $((Get-SupervisorProc).ProcessId))"
            break
        }
        Set-Content $LogFile ""   # fresh log per start
        Start-Process -WindowStyle Hidden powershell -ArgumentList `
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$ScriptDir\publisher-ctl.ps1", 'run'
        Start-Sleep -Seconds 3
        Write-Output "started (supervisor PID $((Get-SupervisorProc).ProcessId)); log: $LogFile"
    }

    "stop" {
        # kill the supervisor FIRST, or it resurrects the publisher
        $sup = Get-SupervisorProc
        if ($sup) { $sup | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }; Write-Output "supervisor stopped" }
        $pub = Get-PublisherProc
        if ($pub) { $pub | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }; Write-Output "publisher stopped" }
        if (-not $sup -and -not $pub) { Write-Output "nothing running" }
    }

    "status" {
        $sup = Get-SupervisorProc; $pub = Get-PublisherProc
        Write-Output ("supervisor: " + $(if ($sup) { "running (PID $($sup.ProcessId))" } else { "not running" }))
        Write-Output ("publisher:  " + $(if ($pub) { "running (PID $($pub.ProcessId))" } else { "not running" }))
        if (Test-Path $LogFile) { Write-Output "--- last log lines ---"; Get-Content $LogFile -Tail 5 }
    }

    "log" {
        Get-Content $LogFile -Tail 30
    }
}
