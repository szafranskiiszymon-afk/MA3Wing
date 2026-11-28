# MA3 Wing - most: strona WWW (iPad) -> OSC -> grandMA3 onPC
# Uruchamiaj przez "Uruchom MA3 Wing.bat". Zamkniecie okna = koniec.

# ===== USTAWIENIA =====
$HttpPorts    = @(8080, 8090, 8888, 9080, 18080)   # porty strony dla iPada - wybierany pierwszy wolny
$ConsoleIP    = '127.0.0.1'   # gdzie dziala onPC (ten sam laptop = 127.0.0.1)
$OscPort      = 8000          # port OSC ustawiony w onPC (Receive)
$Prefix       = 'gma3'        # prefix ustawiony w onPC
$ShortcutsOn  = $true         # czy w onPC sa wlaczone skroty klawiszowe (ShCuts / F10). Jesli tak, skrypt
                              # na czas wpisywania je wylacza (F10) i potem wlacza z powrotem.
$FeedbackPorts = @(9000, 9100, 19000)   # porty feedbacku z onPC (Send) - pierwszy wolny; @() = wylacz
# ======================
# Plik MA3Wing-ustawienia.txt obok skryptu nadpisuje powyzsze (np. praca z konsola grandMA3):
#   KONSOLA=192.168.1.10     (IP konsoli; 127.0.0.1 = onPC na tym laptopie)
#   PORT_OSC=8000
#   PREFIX=gma3
$SettingsFile = Join-Path $PSScriptRoot 'MA3Wing-ustawienia.txt'
if (-not (Test-Path $SettingsFile)) {
    @('# MA3 Wing - ustawienia',
      '# KONSOLA: 127.0.0.1 = grandMA3 onPC na tym laptopie; dla konsoli wpisz jej adres IP, np. 192.168.1.10',
      'KONSOLA=127.0.0.1',
      'PORT_OSC=8000',
      'PREFIX=gma3') | Set-Content -Path $SettingsFile -Encoding ASCII
}
foreach ($l in (Get-Content $SettingsFile)) {
    if ($l -match '^\s*KONSOLA\s*=\s*(\S+)') { $ConsoleIP = $Matches[1] }
    elseif ($l -match '^\s*PORT_OSC\s*=\s*(\d+)') { $OscPort = [int]$Matches[1] }
    elseif ($l -match '^\s*PREFIX\s*=\s*(\S*)') { $Prefix = $Matches[1] }
}
$IsConsole = ($ConsoleIP -ne '127.0.0.1' -and $ConsoleIP -ne 'localhost')
$CacheFile = Join-Path $PSScriptRoot 'MA3Wing-show.txt'   # ostatnie dane show (nazwy, pule, layouty) - dla konsoli / bez wtyczki

$ErrorActionPreference = 'Stop'

# --- uprawnienia administratora (potrzebne dla strony w sieci i zapory) ---
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`""
    exit
}
$Host.UI.RawUI.WindowTitle = 'MA3 Wing - most OSC'
try { Start-Transcript -Path (Join-Path $PSScriptRoot 'MA3Wing-log.txt') -Force | Out-Null } catch {}
$IndexPath = Join-Path $PSScriptRoot 'index.html'
if (-not (Test-Path $IndexPath)) { Write-Host "Brak pliku index.html obok skryptu." -ForegroundColor Red; return }

# --- OSC: kodowanie / dekodowanie ---
function Write-OscString([System.IO.MemoryStream]$ms, [string]$s) {
    $b = [Text.Encoding]::UTF8.GetBytes($s)
    $ms.Write($b, 0, $b.Length)
    $pad = 4 - ($b.Length % 4)                 # zawsze co najmniej jeden bajt 0
    $ms.Write((New-Object byte[] $pad), 0, $pad)
}
function New-OscMessage([string]$addr, [string]$type, [string]$val) {
    $ms = New-Object System.IO.MemoryStream
    Write-OscString $ms $addr
    Write-OscString $ms (',' + $type)
    switch ($type) {
        'i' { $b = [BitConverter]::GetBytes([int32][math]::Round([double]$val)); [Array]::Reverse($b); $ms.Write($b, 0, 4) }
        'f' { $b = [BitConverter]::GetBytes([single][double]$val); [Array]::Reverse($b); $ms.Write($b, 0, 4) }
        's' { Write-OscString $ms $val }
    }
    return ,$ms.ToArray()
}
function Read-Osc([byte[]]$d) {
    $i = [Array]::IndexOf($d, [byte]0)
    if ($i -lt 1) { return $null }
    $addr = [Text.Encoding]::UTF8.GetString($d, 0, $i)
    $p = ($i + 4) -band -4
    $val = ''
    if ($p -lt $d.Length -and $d[$p] -eq 44) {
        $j = [Array]::IndexOf($d, [byte]0, $p)
        if ($j -gt $p) {
            $tags = [Text.Encoding]::ASCII.GetString($d, $p + 1, $j - $p - 1)
            $p = ($j + 4) -band -4
            if ($tags.Length -gt 0) {
                switch ([string]$tags[0]) {
                    'i' { if ($p + 4 -le $d.Length) { [byte[]]$b = $d[$p..($p + 3)]; [Array]::Reverse($b); $val = [string][BitConverter]::ToInt32($b, 0) } }
                    'f' { if ($p + 4 -le $d.Length) { [byte[]]$b = $d[$p..($p + 3)]; [Array]::Reverse($b); $val = [BitConverter]::ToSingle($b, 0).ToString([Globalization.CultureInfo]::InvariantCulture) } }
                    's' { $k = [Array]::IndexOf($d, [byte]0, $p); if ($k -ge $p) { $val = [Text.Encoding]::UTF8.GetString($d, $p, $k - $p) } }
                    'T' { $val = '1' }
                    'F' { $val = '0' }
                }
            }
        }
    }
    return ,@($addr, $val)
}

# --- gniazda ---
$udp = New-Object System.Net.Sockets.UdpClient
$udpIn = $null
$FeedbackPort = 0
# onPC sam zajmuje port linii Send (0.0.0.0:port). Bindujemy sie konkretnie na 127.0.0.1:port -
# Windows przekazuje wtedy pakiety wyslane na 127.0.0.1 do bardziej konkretnego gniazda (naszego).
function New-FeedbackSocket([int]$port, [Net.IPAddress]$ip = [Net.IPAddress]::Loopback) {
    $s = New-Object System.Net.Sockets.UdpClient
    try {
        $s.ExclusiveAddressUse = $false
        $s.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $s.Client.Bind((New-Object Net.IPEndPoint($ip, $port)))
        return $s
    } catch { try { $s.Close() } catch {}; throw }
}
$udpIns = New-Object System.Collections.ArrayList
foreach ($fp in $FeedbackPorts) {
    try { $udpIn = New-FeedbackSocket $fp; $FeedbackPort = $fp; [void]$udpIns.Add([pscustomobject]@{ Sock = $udpIn; Task = $null; Ip = '127.0.0.1' }); break }
    catch { Write-Host "Port feedbacku $fp niedostepny ($($_.Exception.InnerException.Message)), probuje nastepny..." -ForegroundColor DarkGray }
}
$listener = $null
$HttpPort = 0
foreach ($p in $HttpPorts) {
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://+:$p/")
    try { $l.Start(); $listener = $l; $HttpPort = $p; break }
    catch { Write-Host "Port $p zajety przez inny program, probuje nastepny..." -ForegroundColor DarkGray; try { $l.Close() } catch {} }
}
if (-not $listener) { Write-Host "Wszystkie porty ($($HttpPorts -join ', ')) sa zajete. Wpisz inny port w MA3Wing.ps1." -ForegroundColor Red; return }

# --- zapora: pozwol iPadowi wejsc na port strony ---
try {
    Get-NetFirewallRule -DisplayName 'MA3 Wing' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName 'MA3 Wing' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $HttpPort -Profile Any | Out-Null
} catch { Write-Host "Nie udalo sie ustawic zapory: $_" -ForegroundColor Yellow }

# --- diagnostyka: kto nasluchuje na porcie OSC onPC ---
function Show-PortOwner([string]$proto, [int]$port) {
    $eps = if ($proto -eq 'UDP') { @(Get-NetUDPEndpoint -LocalPort $port -ErrorAction SilentlyContinue) }
           else { @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) }
    foreach ($e in $eps) {
        $pn = '?'; try { $pn = (Get-Process -Id $e.OwningProcess -ErrorAction Stop).ProcessName } catch {}
        Write-Host ("  [diag] {0} {1}: adres {2}, program '{3}'" -f $proto, $port, $e.LocalAddress, $pn) -ForegroundColor DarkGray
    }
    return ,$eps
}
Write-Host ''
$oscEps = Show-PortOwner 'UDP' $OscPort
if ($oscEps.Count -eq 0) {
    Write-Host "  UWAGA: nic nie nasluchuje na UDP $OscPort." -ForegroundColor Yellow
    Write-Host "  onPC nie odbiera OSC na tym porcie: sprawdz w onPC Menu > In & Out > OSC:" -ForegroundColor Yellow
    Write-Host "  'Enable Input' wlaczone, linia z Port $OscPort i Receive = Yes." -ForegroundColor Yellow
} else {
    $specific = @($oscEps | Where-Object { $_.LocalAddress -notin @('0.0.0.0', '::', '127.0.0.1', '::1') } | Select-Object -First 1)
    if ($specific.Count -gt 0 -and $ConsoleIP -eq '127.0.0.1') {
        $ConsoleIP = $specific[0].LocalAddress
        Write-Host "  onPC nasluchuje tylko na $ConsoleIP - wysylam OSC na ten adres." -ForegroundColor DarkGray
    }
}
$gmaIds = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like '*gma3*' -or $_.ProcessName -like 'app_*' } | Select-Object -ExpandProperty Id)
if ($gmaIds.Count -eq 0) {
    Write-Host "  [diag] Nie widze procesu onPC (app_gma3) - czy onPC jest uruchomiony?" -ForegroundColor Yellow
} else {
    $u = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $gmaIds -contains $_.OwningProcess } | Sort-Object LocalPort)
    $list = ($u | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)" }) -join ', '
    Write-Host "  [diag] onPC nasluchuje na UDP: $list" -ForegroundColor Cyan
}
[void](Show-PortOwner 'UDP' 9000)
[void](Show-PortOwner 'TCP' 8080)

if ($FeedbackPort -gt 0) {
    $lan = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Select-Object -ExpandProperty IPAddress)
    foreach ($ip in $lan) {
        try { $sx = New-FeedbackSocket $FeedbackPort ([Net.IPAddress]::Parse($ip)); [void]$udpIns.Add([pscustomobject]@{ Sock = $sx; Task = $null; Ip = $ip }) }
        catch { Write-Host "  [diag] nie moge sluchac feedbacku na ${ip}:$FeedbackPort" -ForegroundColor DarkGray }
    }
    Write-Host ("  [diag] feedback slucham na: " + (($udpIns | ForEach-Object { "$($_.Ip):$FeedbackPort" }) -join ', ')) -ForegroundColor Cyan
}

# --- komunikat startowy ---
$ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
         Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
         Select-Object -ExpandProperty IPAddress)
Write-Host ''
Write-Host '  MA3 Wing dziala.' -ForegroundColor Green
Write-Host '  Na iPadzie (ta sama siec Wi-Fi) otworz w Safari:' -ForegroundColor White
foreach ($ip in $ips) { Write-Host "     http://${ip}:$HttpPort" -ForegroundColor Cyan }
Write-Host "  OSC -> ${ConsoleIP}:$OscPort  prefix '/$Prefix'" -ForegroundColor DarkGray
if ($IsConsole) {
    Write-Host "  TRYB KONSOLI: grandMA3 pod $ConsoleIP" -ForegroundColor Yellow
    Write-Host "  W konsoli (Menu - In & Out - OSC): linia z adresem tego laptopa, port $($FeedbackPorts[0]), Send=Yes, Receive=Yes, Receive Command=Yes, prefix '$Prefix'" -ForegroundColor Yellow
}
if ($udpIn) { Write-Host "  Feedback z onPC: ustaw w onPC linie OSC z Send na porcie $FeedbackPort (IP 127.0.0.1)" -ForegroundColor DarkGray }
else { Write-Host "  Feedback wylaczony (porty zajete)." -ForegroundColor Yellow }
Write-Host '  Ponizej widac kazda wiadomosc. Aby zakonczyc, zamknij to okno.' -ForegroundColor DarkGray
Write-Host ''

$clients = New-Object System.Collections.ArrayList
$cancel = [Threading.CancellationToken]::None
$lastFaderLog = [DateTime]::MinValue
$lastFbLog = @{}
$fbCache = [ordered]@{}   # ostatnie pozycje faderow z MA, dla nowo podlaczonych iPadow
$cacheDirty = $false; $lastCacheSave = [DateTime]::Now
if (Test-Path $CacheFile) {
    try {
        foreach ($l in [IO.File]::ReadAllLines($CacheFile)) { $i = $l.IndexOf('='); if ($i -gt 0) { $fbCache[$l.Substring(0, $i)] = $l.Substring($i + 1) } }
        Write-Host "  wczytano zapamietane dane show ($($fbCache.Count) pozycji) - layouty, pule, nazwy" -ForegroundColor DarkGray
    } catch {}
}
# --- obrazki gobo: indeks plikow z instalacji / biblioteki MA (budowany przy pierwszym zapytaniu) ---
$goboIndex = $null
function Find-GoboImage([string]$name) {
    if ($null -eq $script:goboIndex) {
        $script:goboIndex = @{}
        $roots = @("$env:ProgramData\MALightingTechnology", "$env:LOCALAPPDATA\MALightingTechnology",
                   "$env:APPDATA\MALightingTechnology", "$env:USERPROFILE\MALightingTechnology",
                   "${env:ProgramFiles}\MALightingTechnology") | Where-Object { $_ -and (Test-Path $_) }
        foreach ($r in $roots) {
            Get-ChildItem -Path $r -Recurse -File -Include *.png, *.jpg, *.jpeg, *.svg -ErrorAction SilentlyContinue |
                ForEach-Object { $k = $_.Name.ToLowerInvariant(); if (-not $script:goboIndex.ContainsKey($k)) { $script:goboIndex[$k] = $_.FullName } }
        }
        Write-Host "  obrazki gobo: znaleziono $($script:goboIndex.Count) plikow w: $($roots -join ', ')" -ForegroundColor DarkGray
    }
    return $script:goboIndex[$name]
}
function Save-Cache {
    if (-not $script:cacheDirty) { return }
    if (([DateTime]::Now - $script:lastCacheSave).TotalSeconds -lt 10) { return }
    $script:cacheDirty = $false; $script:lastCacheSave = [DateTime]::Now
    try {
        $sb = New-Object System.Text.StringBuilder
        foreach ($k in $script:fbCache.Keys) { if ($k -notmatch '^/Page') { [void]$sb.Append($k).Append('=').Append($script:fbCache[$k]).Append("`r`n") } }
        [IO.File]::WriteAllText($script:CacheFile, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
    } catch {}
}
# dane z wtyczki przez siec (konsola): OSC /ma3wing ,s "KLUCZ=WARTOSC%0AKLUCZ=WARTOSC..." (%xx = znaki specjalne)
function Read-NetState([string]$payload) {
    if (-not $script:netSeen) { $script:netSeen = $true; Write-Host "<- wtyczka MA3Wing przez siec (SendOSC) dziala" -ForegroundColor Green }
    $batch = New-Object System.Text.StringBuilder; $n = 0
    foreach ($l in ([Uri]::UnescapeDataString($payload) -split "`n")) {
        $i = $l.IndexOf('='); if ($i -le 0) { continue }
        $k = $l.Substring(0, $i); $v = $l.Substring($i + 1)
        if ($k -eq 'HELLO') { continue }
        if ($script:fbCache[$k] -ne $v) {
            $script:fbCache[$k] = $v; $n++
            if ($batch.Length) { [void]$batch.Append("`n") }
            [void]$batch.Append(("fb`t{0}`t{1}" -f $k, $v))
        }
    }
    if ($batch.Length) { Send-ToClients $batch.ToString(); $script:cacheDirty = $true }
}
$StateFile = Join-Path $env:TEMP 'MA3Wing-faders.txt'
$CmdLineFile = Join-Path $env:TEMP 'MA3Wing-cmdline.txt'
$EscFile = Join-Path $env:TEMP 'MA3Wing-esc.txt'   # linia komend z iPada, czyta ja wtyczka
try { [IO.File]::WriteAllText($CmdLineFile, '', (New-Object Text.UTF8Encoding $false)) } catch {}   # zapisuje go wtyczka MA3Wing.lua w onPC
$stateStamp = [DateTime]::MinValue
$stateSeen = $false
$lastStateLog = [DateTime]::MinValue
function Read-StateFile {
    if (-not [IO.File]::Exists($script:StateFile)) { return }
    $t = [IO.File]::GetLastWriteTimeUtc($script:StateFile)
    if ($t -eq $script:stateStamp) { return }
    try { $lines = [IO.File]::ReadAllLines($script:StateFile) } catch { return }
    if ($lines.Count -eq 0 -or $lines[-1] -ne 'END') { return }   # plik w trakcie zapisu - sprobuj za chwile
    $script:stateStamp = $t
    if (-not $script:stateSeen) { $script:stateSeen = $true; Write-Host "<- wtyczka MA3Wing w onPC dziala (plik $($script:StateFile))" -ForegroundColor Green }
    $n = 0
    $batch = New-Object System.Text.StringBuilder
    foreach ($l in $lines) {
        $kv = $l.Split('=')
        if ($kv.Count -ne 2) { continue }
        if ($script:fbCache[$kv[0]] -ne $kv[1]) {
            $script:fbCache[$kv[0]] = $kv[1]
            if ($batch.Length) { [void]$batch.Append("`n") }
            [void]$batch.Append(("fb`t{0}`t{1}" -f $kv[0], $kv[1]))
            $n++
        }
    }
    if ($batch.Length) { Send-ToClients $batch.ToString(); $script:cacheDirty = $true }
    $now = [DateTime]::Now
    if ($n -gt 0 -and ($now - $script:lastStateLog).TotalMilliseconds -gt 1000) {
        $script:lastStateLog = $now
        Write-Host "<- MA: zmiana $n pozycji (np. $($lines[0]))" -ForegroundColor DarkCyan
    }
}

function Send-Client($c, [string]$text) {
    if ($c.Dead) { return }
    if ($c.SendTask -and -not $c.SendTask.IsCompleted) {
        try { if (-not $c.SendTask.Wait(300)) { $c.Dead = $true; return } } catch { $c.Dead = $true; return }
    }
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        $c.SendTask = $c.Ws.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, $cancel)
    } catch { $c.Dead = $true }
}
function Send-ToClients([string]$text) {
    foreach ($c in @($clients)) { Send-Client $c $text }
}

# --- klawiatura: wpisywanie w linie komend onPC (jak klawisze konsoli) ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic
$script:maPid = 0
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class MA3WingKB {
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
}
"@
function Focus-MA {
    $p = $null
    if ($script:maPid) { $p = Get-Process -Id $script:maPid -ErrorAction SilentlyContinue }
    if (-not $p -or $p.MainWindowHandle -eq 0) {
        $p = Get-Process -ErrorAction SilentlyContinue | Where-Object { ($_.ProcessName -like '*gma3*') -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    }
    if (-not $p) { Write-Host "Nie widze okna onPC" -ForegroundColor Yellow; return $false }
    $script:maPid = $p.Id
    if ([MA3WingKB]::IsIconic($p.MainWindowHandle)) {
        # onPC zminimalizowany (np. otwarty wizualizer) - nie wyciagamy go na wierzch, iPad wysle cala komende przez OSC
        Write-Host "onPC zminimalizowany - klawisze pomijam, komenda pojdzie przez OSC" -ForegroundColor DarkGray
        return $false
    }
    try { [Microsoft.VisualBasic.Interaction]::AppActivate($p.Id) } catch {}
    Start-Sleep -Milliseconds 30
    return $true
}
# przytrzymanie prawdziwego klawisza MA przez jego skrot (Store = S, Update = U)
function Send-MAHold([string]$dir, [string]$letter) {
    if (-not $ShortcutsOn) {
        if ($dir -eq 'd') { $w = @{ 'S' = 'Store'; 'U' = 'Update' }[$letter]; if ($w) { Send-MAKeys 't' ($w + ' ') } }
        return
    }
    if ($dir -eq 'd' -and -not (Focus-MA)) { Send-KeysResult 'skipped'; return }
    if ($dir -eq 'd') { Send-KeysResult 'ok' }
    $vk = [byte][char]$letter.ToUpper()
    if ($dir -eq 'd') { [MA3WingKB]::keybd_event($vk, 0, 0, [UIntPtr]::Zero); Write-Host "-> klawisz MA: $letter (wcisniety)" }
    else { [MA3WingKB]::keybd_event($vk, 0, 2, [UIntPtr]::Zero); Write-Host "-> klawisz MA: $letter (puszczony)" }
}
$script:curClient = $null
function Send-KeysResult([string]$r) { if ($script:curClient) { Send-Client $script:curClient ("fb`tKEYS`t" + $r) } }
function Send-MAKeys([string]$mode, [string]$text) {
    if ($mode -eq 't') {
        # tekst: znaki specjalne SendKeys trzeba ujac w nawiasy klamrowe
        $sb = New-Object System.Text.StringBuilder
        foreach ($ch in $text.ToCharArray()) {
            if ('+^%~(){}[]'.IndexOf($ch) -ge 0) { [void]$sb.Append('{').Append($ch).Append('}') } else { [void]$sb.Append($ch) }
        }
        $keys = $sb.ToString()
    } else { $keys = $text }
    try {
        if (-not (Focus-MA)) { Send-KeysResult 'skipped'; return }
        if ($ShortcutsOn) { $keys = '{F10}' + $keys + '{F10}' }
        [System.Windows.Forms.SendKeys]::SendWait($keys)
        Write-Host ("-> klawiatura onPC: {0}" -f $text)
        Send-KeysResult 'ok'
    } catch { Write-Host "Blad wpisywania do onPC: $($_.Exception.Message)" -ForegroundColor Red }
}

function Invoke-Line([string]$line) {
    $parts = $line -split "`t", 3
    if ($parts.Count -lt 3) { return }
    if ($parts[0] -eq '!keys') { Send-MAKeys $parts[1] $parts[2]; return }
    if ($parts[0] -eq '!hold') { Send-MAHold $parts[1] $parts[2]; return }
    if ($parts[0] -eq '!esc') {          # klawisz Esc z iPada -> wtyczka naciska Esc w MA (zamyka okna)
        try { [IO.File]::WriteAllText($script:EscFile, $parts[2], (New-Object Text.UTF8Encoding $false)) } catch {}
        return
    }
    if ($parts[0] -eq '!cmdline') {      # linia komend z iPada -> plik dla wtyczki (pokazuje ja w linii komend onPC)
        try { [IO.File]::WriteAllText($script:CmdLineFile, $parts[2], (New-Object Text.UTF8Encoding $false)) } catch {}
        return
    }
    $addr = $parts[0]
    if ($Prefix) { $addr = '/' + $Prefix + $addr }
    try {
        $msg = New-OscMessage $addr $parts[1] $parts[2]
        [void]$udp.Send($msg, $msg.Length, $ConsoleIP, $OscPort)
    } catch { Write-Host "Blad wysylania OSC: $_" -ForegroundColor Red; return }
    $now = [DateTime]::Now
    if ($addr -like '*Fader*') {
        if (($now - $script:lastFaderLog).TotalMilliseconds -lt 250) { return }
        $script:lastFaderLog = $now
    }
    Write-Host ("-> {0} {1}" -f $addr, $parts[2])
}

$ctxTask = $listener.GetContextAsync()
foreach ($u in $udpIns) { $u.Task = $u.Sock.ReceiveAsync() }

try {
    while ($true) {
        Read-StateFile
        Save-Cache
        foreach ($c in @($clients)) {
            if ($c.Dead) {
                try { $c.Ws.Abort() } catch {}
                $clients.Remove($c)
                Write-Host "Rozlaczono (nie nadazal): $($c.Who)" -ForegroundColor DarkYellow
            }
        }
        $tasks = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task]'
        $tasks.Add($ctxTask)
        foreach ($u in $udpIns) { $tasks.Add($u.Task) }
        foreach ($c in $clients) { $tasks.Add($c.Task) }
        $offset = 1 + $udpIns.Count

        $idx = [System.Threading.Tasks.Task]::WaitAny($tasks.ToArray(), 100)
        if ($idx -lt 0) { continue }

        if ($idx -eq 0) {
            # --- nowe polaczenie HTTP / WebSocket ---
            try {
                $ctx = $ctxTask.Result
                if ($ctx.Request.IsWebSocketRequest) {
                    $wsc = $ctx.AcceptWebSocketAsync([NullString]::Value).GetAwaiter().GetResult()
                    $buf = New-Object byte[] 16384
                    $seg = [ArraySegment[byte]]::new($buf)
                    $c = [pscustomobject]@{ Ws = $wsc.WebSocket; Buf = $buf; Seg = $seg; Text = ''; Who = $ctx.Request.RemoteEndPoint.Address.ToString(); Task = $null; SendTask = $null; Dead = $false }
                    $c.Task = $c.Ws.ReceiveAsync($seg, $cancel)
                    [void]$clients.Add($c)
                    Write-Host "Polaczono: $($c.Who)" -ForegroundColor Green
                    if ($fbCache.Count -gt 0) {
                        $all = (@($fbCache.Keys) | ForEach-Object { "fb`t{0}`t{1}" -f $_, $fbCache[$_] }) -join "`n"
                        Send-Client $c $all
                    }
                    if ($fbCache.Count -gt 0) { Write-Host "  wyslano iPadowi $($fbCache.Count) pozycji z MA" -ForegroundColor DarkGray }
                } else {
                    $res = $ctx.Response
                    $path = $ctx.Request.Url.AbsolutePath
                    if ($path -eq '/' -or $path -eq '/index.html') {
                        $bytes = [IO.File]::ReadAllBytes($IndexPath)
                        $res.ContentType = 'text/html; charset=utf-8'
                        $res.Headers.Add('Cache-Control', 'no-store')
                    } elseif ($path.StartsWith('/gobo/')) {
                        # obrazek gobo z biblioteki MA na tym laptopie (nazwa pliku ze slotu kola)
                        $name = [Uri]::UnescapeDataString($path.Substring(6)).ToLowerInvariant()
                        $file = Find-GoboImage $name
                        if ($file) {
                            $bytes = [IO.File]::ReadAllBytes($file)
                            $res.ContentType = $(if ($file -match '\.jpe?g$') { 'image/jpeg' } elseif ($file -match '\.svg$') { 'image/svg+xml' } else { 'image/png' })
                            $res.Headers.Add('Cache-Control', 'max-age=86400')
                            $res.Headers.Add('Access-Control-Allow-Origin', '*')
                        } else {
                            $res.StatusCode = 404
                            $bytes = [Text.Encoding]::UTF8.GetBytes('404')
                        }
                    } else {
                        $res.StatusCode = 404
                        $bytes = [Text.Encoding]::UTF8.GetBytes('404')
                    }
                    $res.ContentLength64 = $bytes.Length
                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                    $res.Close()
                }
            } catch { Write-Host "Blad polaczenia: $($_.Exception.Message)" -ForegroundColor Yellow }
            $ctxTask = $listener.GetContextAsync()
        }
        elseif ($idx -lt $offset) {
            # --- feedback z onPC ---
            $u = $udpIns[$idx - 1]
            try {
                $r = $u.Task.Result
                $m = Read-Osc $r.Buffer
                if ($m) {
                    $a = $m[0]; $v = $m[1]
                    $local = $a
                    if ($Prefix -and $local.StartsWith('/' + $Prefix + '/')) { $local = $local.Substring($Prefix.Length + 1) }
                    if ($local -eq '/ma3wing') { Read-NetState $v; $u.Task = $u.Sock.ReceiveAsync(); continue }
                    if ($local -match '^/Page\d+/Fader\d+$') { $fbCache[$local] = $v }
                    if ($local -match '^/Page\d+/Fader\d+$') { Send-ToClients ("fb`t{0}`t{1}" -f $local, $v) }
                    $now = [DateTime]::Now
                    if (($local -notmatch '^/\d+\.') -and (-not $lastFbLog.ContainsKey($a) -or ($now - $lastFbLog[$a]).TotalMilliseconds -gt 1000)) {
                        $lastFbLog[$a] = $now
                        Write-Host ("<- {0} {1}" -f $a, $v) -ForegroundColor DarkCyan
                    }
                }
            } catch {}
            $u.Task = $u.Sock.ReceiveAsync()
        }
        else {
            # --- wiadomosc z iPada ---
            $c = $clients[$idx - $offset]
            $remove = $false
            try {
                $r = $c.Task.Result
                if ($r.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                    $remove = $true
                } else {
                    $c.Text += [Text.Encoding]::UTF8.GetString($c.Buf, 0, $r.Count)
                    if ($r.EndOfMessage) { $t = $c.Text; $c.Text = ''; $script:curClient = $c; Invoke-Line $t; $script:curClient = $null }
                    $c.Task = $c.Ws.ReceiveAsync($c.Seg, $cancel)
                }
            } catch { $remove = $true }
            if ($remove) {
                try { $c.Ws.CloseOutputAsync([Net.WebSockets.WebSocketCloseStatus]::NormalClosure, '', $cancel).Wait(500) | Out-Null } catch {}
                $clients.Remove($c)
                Write-Host "Rozlaczono: $($c.Who)" -ForegroundColor DarkYellow
            }
        }
    }
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
    $listener.Stop()
    $udp.Close()
    foreach ($u in $udpIns) { try { $u.Sock.Close() } catch {} }
}
