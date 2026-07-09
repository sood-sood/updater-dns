@echo off
setlocal

:: Check for Administrator privileges
fsutil dirty query %systemdrive% >nul
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

set "INSTALL_DIR=C:\ProgramData\XboxDNS"
set "INSTALL_FILE=%INSTALL_DIR%\setup_dns.bat"

:: If running from the install directory, execute the PowerShell payload
if /i "%~dp0"=="%INSTALL_DIR%\" (
    powershell -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -Command "$c=Get-Content -LiteralPath '%~f0' -Raw; Invoke-Expression $c.Substring($c.IndexOf('###'+'PS_START###')+14)"
    exit /b
)

:: Installation Phase
echo Installing Xbox DNS Updater...
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
copy /y "%~f0" "%INSTALL_FILE%" >nul

:: Create Scheduled Task
set "PS_CMD=powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -Command \"$c=Get-Content -LiteralPath '%INSTALL_FILE%' -Raw; Invoke-Expression $c.Substring($c.IndexOf('###'+'PS_START###')+14)\""
schtasks /create /tn "XboxDNS_Updater" /tr "%PS_CMD%" /sc onlogon /rl highest /f >nul
powershell -Command "$t=Get-ScheduledTask -TaskName 'XboxDNS_Updater'; $t.Settings.DisallowStartIfOnBatteries=$false; $t.Settings.StopIfGoingOnBatteries=$false; Set-ScheduledTask -TaskName 'XboxDNS_Updater' -Settings $t.Settings" >nul 2>&1

:: Run immediately in background
start "" powershell -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -Command "$c=Get-Content -LiteralPath '%INSTALL_FILE%' -Raw; Invoke-Expression $c.Substring($c.IndexOf('###'+'PS_START###')+14)"

:: Show Success Notification
powershell -Command "Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show('Success! Xbox DNS Updater installed. It will now run in the background and at every logon.', 'Xbox DNS Updater', 'OK', 'Information')"

exit /b

###PS_START###
$ErrorActionPreference = 'Stop'
$url = 'https://xbox-dns.ru/'

function Get-ActiveInterfaceIndex {
    $routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -ne '0.0.0.0' -and $_.RouteMetric -lt 256 }
    if ($routes) {
        $bestRoute = $routes | Sort-Object RouteMetric | Select-Object -First 1
        return $bestRoute.InterfaceIndex
    }
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false }
    if ($adapters) {
        return $adapters[0].ifIndex
    }
    return $null
}

$interfaceIndex = Get-ActiveInterfaceIndex
if (-not $interfaceIndex) { exit }

function Update-DNS {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $req = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $html = $req.Content
        
        $pattern = '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
        $found = [regex]::Matches($html, $pattern)
        
        $ips = @()
        foreach ($m in $found) {
            $ip = $m.Value
            if ($ip -notmatch '^(127\.|192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)') {
                if ($ips -notcontains $ip) {
                    $ips += $ip
                }
            }
        }
        
        if ($ips.Count -ge 2) {
            Set-DnsClientServerAddress -InterfaceIndex $interfaceIndex -ServerAddresses $ips[0], $ips[1] -ErrorAction Stop
            return $true
        }
        return $false
    } catch {
        return $false
    }
}

if (-not (Update-DNS)) {
    # Failover: reset to DHCP, flush DNS, wait 3 seconds, retry
    Set-DnsClientServerAddress -InterfaceIndex $interfaceIndex -ResetServerAddresses -ErrorAction SilentlyContinue
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    
    if (-not (Update-DNS)) {
        # Still failed
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show('Xbox site is unreachable', 'Xbox DNS Error', 'OK', 'Error')
    }
}
