# MA3 Wing - most: strona WWW (iPad) -> OSC -> grandMA3 onPC
# Uruchamiaj przez "Uruchom MA3 Wing.bat". Zamkniecie okna = koniec.

# ===== USTAWIENIA =====
$HttpPorts    = @(8080, 8090, 8888, 9080, 18080)   # porty strony dla iPada - wybierany pierwszy wolny
$ConsoleIP    = '127.0.0.1'   # gdzie dziala onPC (ten sam laptop = 127.0.0.1)
$OscPort      = 8000          # port OSC ustawiony w onPC (Receive)
$Prefix       = 'gma3'        # prefix ustawiony w onPC
$FeedbackPort = 9000          # port, na ktory onPC wysyla feedback (Send); 0 = wylacz
# ======================

$ErrorActionPreference = 'Stop'

# --- uprawnienia administratora (potrzebne dla strony w sieci i zapory) ---
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`""
    exit
}
$Host.UI.RawUI.WindowTitle = 'MA3 Wing - most OSC'
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
if ($FeedbackPort -gt 0) {
    try { $udpIn = New-Object System.Net.Sockets.UdpClient($FeedbackPort) }
    catch { Write-Host "Port feedbacku $FeedbackPort zajety - feedback wylaczony." -ForegroundColor Yellow }
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

# --- komunikat startowy ---
$ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
         Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
         Select-Object -ExpandProperty IPAddress)
Write-Host ''
Write-Host '  MA3 Wing dziala.' -ForegroundColor Green
Write-Host '  Na iPadzie (ta sama siec Wi-Fi) otworz w Safari:' -ForegroundColor White
foreach ($ip in $ips) { Write-Host "     http://${ip}:$HttpPort" -ForegroundColor Cyan }
Write-Host "  OSC -> ${ConsoleIP}:$OscPort  prefix '/$Prefix'   feedback <- port $FeedbackPort" -ForegroundColor DarkGray
Write-Host '  Ponizej widac kazda wiadomosc. Aby zakonczyc, zamknij to okno.' -ForegroundColor DarkGray
Write-Host ''

$clients = New-Object System.Collections.ArrayList
$cancel = [Threading.CancellationToken]::None
$lastFaderLog = [DateTime]::MinValue
$lastFbLog = @{}

function Send-ToClients([string]$text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    foreach ($c in @($clients)) {
        try { $c.Ws.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, $cancel).Wait(500) | Out-Null } catch {}
    }
}

function Invoke-Line([string]$line) {
    $parts = $line -split "`t", 3
    if ($parts.Count -lt 3) { return }
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
$udpTask = $null
if ($udpIn) { $udpTask = $udpIn.ReceiveAsync() }

try {
    while ($true) {
        $tasks = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task]'
        $tasks.Add($ctxTask)
        if ($udpTask) { $tasks.Add($udpTask) }
        foreach ($c in $clients) { $tasks.Add($c.Task) }
        $offset = 1; if ($udpTask) { $offset = 2 }

        $idx = [System.Threading.Tasks.Task]::WaitAny($tasks.ToArray(), 500)
        if ($idx -lt 0) { continue }

        if ($idx -eq 0) {
            # --- nowe polaczenie HTTP / WebSocket ---
            try {
                $ctx = $ctxTask.Result
                if ($ctx.Request.IsWebSocketRequest) {
                    $wsc = $ctx.AcceptWebSocketAsync($null).GetAwaiter().GetResult()
                    $buf = New-Object byte[] 16384
                    $seg = [ArraySegment[byte]]::new($buf)
                    $c = [pscustomobject]@{ Ws = $wsc.WebSocket; Buf = $buf; Seg = $seg; Text = ''; Who = $ctx.Request.RemoteEndPoint.Address.ToString(); Task = $null }
                    $c.Task = $c.Ws.ReceiveAsync($seg, $cancel)
                    [void]$clients.Add($c)
                    Write-Host "Polaczono: $($c.Who)" -ForegroundColor Green
                } else {
                    $res = $ctx.Response
                    $path = $ctx.Request.Url.AbsolutePath
                    if ($path -eq '/' -or $path -eq '/index.html') {
                        $bytes = [IO.File]::ReadAllBytes($IndexPath)
                        $res.ContentType = 'text/html; charset=utf-8'
                        $res.Headers.Add('Cache-Control', 'no-store')
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
        elseif ($udpTask -and $idx -eq 1) {
            # --- feedback z onPC ---
            try {
                $r = $udpTask.Result
                $m = Read-Osc $r.Buffer
                if ($m) {
                    $a = $m[0]; $v = $m[1]
                    $local = $a
                    if ($Prefix -and $local.StartsWith('/' + $Prefix + '/')) { $local = $local.Substring($Prefix.Length + 1) }
                    Send-ToClients ("fb`t{0}`t{1}" -f $local, $v)
                    $now = [DateTime]::Now
                    if (-not $lastFbLog.ContainsKey($a) -or ($now - $lastFbLog[$a]).TotalMilliseconds -gt 1000) {
                        $lastFbLog[$a] = $now
                        Write-Host ("<- {0} {1}" -f $a, $v) -ForegroundColor DarkCyan
                    }
                }
            } catch {}
            $udpTask = $udpIn.ReceiveAsync()
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
                    if ($r.EndOfMessage) { $t = $c.Text; $c.Text = ''; Invoke-Line $t }
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
    $listener.Stop()
    $udp.Close()
    if ($udpIn) { $udpIn.Close() }
}
