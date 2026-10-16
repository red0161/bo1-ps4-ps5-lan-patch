<#
BO1 Cross-Version LAN Patch (PowerShell, no Python needed)

Makes a jailbroken PS4's running BO1 (CUSA57547, app 01.08) use the 1.09 network
protocol (2121 / 0x849) over ps4debug (TCP 744), so a 1.09 console can join its LAN match.

Usage:
  Patch-BO1.ps1                         interactive menu
  Patch-BO1.ps1 <ps4_ip> status
  Patch-BO1.ps1 <ps4_ip> apply [0x849]
  Patch-BO1.ps1 <ps4_ip> restore

Every site is checked against the original 01.08 bytes before writing and read back
afterwards. Nothing is written if anything doesn't match. Restarting BO1 undoes it.
#>
param([string]$Ip, [string]$Action, [string]$Value = "0x849")

$ErrorActionPreference = "Stop"

$ORIGINAL = 0x848
# Description, instruction address, opcode bytes before the 32-bit protocol value
$SITES = @(
    @("host advertises protocol in lobby info", 0x54FB5D, [byte[]](0xBE)),
    @("host connect check (SV_DirectConnect)",  0x5572F7, [byte[]](0xB8)),
    @("host joinParty argument check",          0x585F2D, [byte[]](0x3D)),
    @("lobby message protocol written by host", 0x8F3F40, [byte[]](0xBE)),
    @("lobby message protocol check on read",   0x8F4174, [byte[]](0x81, 0x3B)),
    @("protocol getter function",               0x64A510, [byte[]](0xB8)),
    @("local client connect userinfo protocol", 0x7274B4, [byte[]](0xBE)),
    @("local client connect string protocol",   0x7228E5, [byte[]](0x41, 0xB9)),
    @("local client joinParty protocol",        0x56E3C6, [byte[]](0xBA)),
    @("server browser protocol filter",         0x71FDB8, [byte[]](0x3D))
)
$DVAR_HINT = 0x2BE3000          # usual spot of the "protocol" dvar; it moves between launches
$DVAR_NAME_STRING = 0xB5A1FD    # address of the "protocol" string its name pointer must hold
$DVAR_FIELDS = @(0x28, 0x38, 0x48)  # current, latched, reset
$BSS_START = 0x1000000
$BSS_END = 0x3C9C000

# ---------------- ps4debug client ----------------
# Parsed from strings: Windows PowerShell 5.1 reads hex literals above 0x7FFFFFFF as negative Int32.
$MAGIC = [Convert]::ToUInt32("FFAABBCC", 16)
$CMD_PROC_LIST = [Convert]::ToUInt32("BDAA0001", 16)
$CMD_PROC_READ = [Convert]::ToUInt32("BDAA0002", 16)
$CMD_PROC_WRITE = [Convert]::ToUInt32("BDAA0003", 16)
$STATUS_SUCCESS = [Convert]::ToUInt32("80000000", 16)

function U32([uint32]$v) { [BitConverter]::GetBytes($v) }

function Connect-PS4([string]$ip) {
    $client = New-Object System.Net.Sockets.TcpClient
    $connected = $false
    try { $connected = $client.ConnectAsync($ip, 744).Wait(10000) -and $client.Connected } catch { }
    if (-not $connected) {
        throw "Can't reach ps4debug on ${ip}:744. Check the PS4 is on, the IP is right, and the ps4debug payload is loaded."
    }
    $client.ReceiveTimeout = 30000
    $client.SendTimeout = 30000
    return $client
}

function Receive-Exact($stream, [int]$n) {
    $buf = New-Object byte[] $n
    $got = 0
    while ($got -lt $n) {
        $r = $stream.Read($buf, $got, $n - $got)
        if ($r -le 0) { throw "Connection closed by the console." }
        $got += $r
    }
    return ,$buf
}

function Assert-Status($stream, [string]$what) {
    $s = [BitConverter]::ToUInt32((Receive-Exact $stream 4), 0)
    if ($s -ne $STATUS_SUCCESS) { throw ("{0} failed: status 0x{1:X8}" -f $what, $s) }
}

function Send-Command($stream, [uint32]$cmd, [byte[]]$data) {
    $len = 0
    if ($data) { $len = $data.Length }
    $hdr = (U32 $MAGIC) + (U32 $cmd) + (U32 $len)
    $stream.Write([byte[]]$hdr, 0, 12)
    if ($len -gt 0) { $stream.Write($data, 0, $len) }
    Assert-Status $stream ("command 0x{0:X8}" -f $cmd)
}

function Get-GamePid($stream) {
    Send-Command $stream $CMD_PROC_LIST $null
    $count = [BitConverter]::ToUInt32((Receive-Exact $stream 4), 0)
    $found = $null
    for ($i = 0; $i -lt $count; $i++) {
        $raw = Receive-Exact $stream 36
        $name = [Text.Encoding]::ASCII.GetString($raw, 0, 32).Split([char]0)[0]
        if ($name -eq "codmp.elf") { $found = [BitConverter]::ToInt32($raw, 32) }
    }
    if ($null -eq $found) { throw "codmp.elf is not running on the console. Start BO1 first." }
    return $found
}

function Read-Mem($stream, [int]$procId, [uint64]$addr, [int]$len) {
    $out = New-Object byte[] $len
    $done = 0
    while ($done -lt $len) {
        $n = [Math]::Min(0x10000, $len - $done)
        $req = [BitConverter]::GetBytes([int32]$procId) + [BitConverter]::GetBytes([uint64]($addr + $done)) + (U32 $n)
        Send-Command $stream $CMD_PROC_READ ([byte[]]$req)
        $chunk = Receive-Exact $stream $n
        [Array]::Copy($chunk, 0, $out, $done, $n)
        $done += $n
    }
    return ,$out
}

function Write-Mem($stream, [int]$procId, [uint64]$addr, [byte[]]$data) {
    $req = [BitConverter]::GetBytes([int32]$procId) + [BitConverter]::GetBytes($addr) + (U32 $data.Length)
    Send-Command $stream $CMD_PROC_WRITE ([byte[]]$req)
    $stream.Write($data, 0, $data.Length)
    Assert-Status $stream "write data"
}

# ---------------- patch logic ----------------
function Read-Sites($stream, [int]$procId) {
    foreach ($s in $SITES) {
        $op = $s[2]
        $raw = Read-Mem $stream $procId $s[1] ($op.Length + 4)
        $okOp = $true
        for ($i = 0; $i -lt $op.Length; $i++) { if ($raw[$i] -ne $op[$i]) { $okOp = $false } }
        [pscustomobject]@{
            Desc = $s[0]; Addr = $s[1]; ImmAddr = $s[1] + $op.Length
            OkOpcode = $okOp; Value = [BitConverter]::ToUInt32($raw, $op.Length)
        }
    }
}

function Find-ProtocolDvar($stream, [int]$procId) {
    $hint = Read-Mem $stream $procId $DVAR_HINT 8
    if ([BitConverter]::ToUInt64($hint, 0) -eq $DVAR_NAME_STRING) { return $DVAR_HINT }
    Write-Host "  Searching for the 'protocol' setting (takes a few seconds)..."
    $needle0 = [byte]($DVAR_NAME_STRING -band 0xFF)
    for ($base = $BSS_START; $base -lt $BSS_END; $base += 0x100000) {
        $blob = Read-Mem $stream $procId $base ([Math]::Min(0x100000, $BSS_END - $base))
        $pos = [Array]::IndexOf($blob, $needle0, 0)
        while ($pos -ge 0 -and $pos -le $blob.Length - 0x20) {
            if (($pos % 8) -eq 0 -and [BitConverter]::ToUInt64($blob, $pos) -eq $DVAR_NAME_STRING -and
                [BitConverter]::ToUInt32($blob, $pos + 0x1C) -eq 5) {
                return [uint64]($base + $pos)
            }
            $pos = [Array]::IndexOf($blob, $needle0, $pos + 1)
        }
    }
    throw "Could not find the 'protocol' setting. Is BO1 fully loaded?"
}

function Show-Status($stream, [int]$procId) {
    foreach ($r in (Read-Sites $stream $procId)) {
        $state = "UNEXPECTED BYTES"
        if ($r.OkOpcode) { $state = "0x{0:X}" -f $r.Value }
        Write-Host ("  0x{0:X6}  {1,16}  {2}" -f $r.Addr, $state, $r.Desc)
    }
    $dv = Find-ProtocolDvar $stream $procId
    $raw = Read-Mem $stream $procId $dv 0x50
    $vals = ($DVAR_FIELDS | ForEach-Object { "0x{0:X}" -f [BitConverter]::ToUInt32($raw, $_) }) -join ", "
    Write-Host ("  dvar 'protocol' at 0x{0:X}: {1}" -f $dv, $vals)
}

function Set-Protocol($stream, [int]$procId, [uint32]$new) {
    $rows = @(Read-Sites $stream $procId)
    $old = $rows[0].Value
    $bad = @($rows | Where-Object { -not $_.OkOpcode -or ($_.Value -ne $old -and $_.Value -ne $new) })
    if ($bad.Count -gt 0) {
        foreach ($b in $bad) { Write-Host ("  refusing: 0x{0:X6} ({1}) holds 0x{2:X}" -f $b.Addr, $b.Desc, $b.Value) }
        throw "Nothing written: this is not the expected 01.08 build/state."
    }
    $dv = Find-ProtocolDvar $stream $procId
    $draw = Read-Mem $stream $procId $dv 0x50
    $bytes = [byte[]](U32 $new)
    foreach ($r in $rows) {
        Write-Mem $stream $procId $r.ImmAddr $bytes
        $got = [BitConverter]::ToUInt32((Read-Mem $stream $procId $r.ImmAddr 4), 0)
        $ok = "READBACK MISMATCH"
        if ($got -eq $new) { $ok = "ok" }
        Write-Host ("  0x{0:X6} -> 0x{1:X}  {2}  {3}" -f $r.Addr, $got, $ok, $r.Desc)
    }
    foreach ($off in $DVAR_FIELDS) {
        if ([BitConverter]::ToUInt32($draw, $off) -eq $old) { Write-Mem $stream $procId ($dv + $off) $bytes }
    }
    Write-Host ("  dvar 'protocol' -> 0x{0:X}" -f $new)
}

function Invoke-Action([string]$ip, [string]$action, [string]$value) {
    $client = $null
    try {
        $client = Connect-PS4 $ip
        $stream = $client.GetStream()
        $procId = Get-GamePid $stream
        switch ($action) {
            "status"  { Show-Status $stream $procId }
            "apply"   { Set-Protocol $stream $procId ([Convert]::ToUInt32($value.Replace("0x", ""), 16)) }
            "restore" { Set-Protocol $stream $procId $ORIGINAL }
            default   { throw "Unknown action '$action'. Use status, apply or restore." }
        }
        return $true
    } catch {
        Write-Host ("Error: " + $_.Exception.Message) -ForegroundColor Red
        if ($_.Exception.Message -like "Can't reach*") {
            Write-Host "Port 744 is ps4debug itself. Send the ps4debug payload first (loader port 9090), then try again." -ForegroundColor Yellow
        }
        return $false
    } finally {
        if ($client) { $client.Close() }
    }
}

# ---------------- entry point ----------------
if ($Ip -and $Action) {
    Invoke-Action $Ip $Action $Value | Out-Null
    return
}

if (-not $Ip) { $Ip = (Read-Host "Enter your jailbroken PS4's IP address").Trim() }
while ($true) {
    Write-Host ""
    Write-Host "BO1 Cross-Version LAN Patch (PS4 01.08 host -> 1.09 guest)"
    Write-Host "  1. Apply patch (use the 1.09 protocol)"
    Write-Host "  2. Check status"
    Write-Host "  3. Restore original"
    Write-Host "  4. Quit"
    $choice = (Read-Host "Choose 1-4").Trim()
    switch ($choice) {
        "1" {
            if (Invoke-Action $Ip "apply" "0x849") {
                Write-Host ""
                Write-Host "If every line shows 0x849: PS4 -> LAN -> Create Game -> START THE MATCH, then join from the other console."
                Write-Host "Re-apply after restarting BO1."
            }
        }
        "2" { Invoke-Action $Ip "status" "" | Out-Null }
        "3" { Invoke-Action $Ip "restore" "" | Out-Null }
        "4" { return }
    }
    Read-Host "Press Enter to continue" | Out-Null
}
