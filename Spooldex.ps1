<#
.SYNOPSIS
    Spooldex - keeps a local filament inventory up to date from Bambu Cloud print history.

.DESCRIPTION
    (no switches)  Start the local web page on http://localhost:8765 and open it in your browser.
                   The page syncs new prints from Bambu Cloud every time it opens.
    -SyncOnly      Pull new prints from Bambu Cloud into the inventory and exit (used at Windows logon).
    -Login         Sign in to Bambu Cloud and store the access token, encrypted to your Windows account.
    -TasksFile     Sync from a saved my/tasks JSON response instead of the cloud (testing).
#>
[CmdletBinding()]
param(
    [switch]$Login,
    [switch]$SyncOnly,
    [string]$TasksFile,
    [int]$Port = 8765,
    [int]$IdleMinutes = 15,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root      = $PSScriptRoot
# Personal data (inventory, Bambu token, logs) lives outside the program folder so it never ends up in git.
# Not under AppData: packaged (MSIX) apps get AppData writes silently redirected to a private copy, so
# launching from such an app and from a desktop shortcut would see different data.
$DataDir   = Join-Path $env:USERPROFILE 'Spooldex'
$DbPath    = Join-Path $DataDir 'tracker.json'
$TokenPath = Join-Path $DataDir 'token.xml'
$AuthPath  = Join-Path $DataDir 'auth.json'
$LogPath   = Join-Path $DataDir 'sync.log'
$BackupDir = Join-Path $DataDir 'backups'
$IndexPath = Join-Path $Root 'web\index.html'
$ApiBase   = 'https://api.bambulab.com'
$Utf8      = New-Object System.Text.UTF8Encoding $false

# Older versions kept data in .\data next to the script; copy it over once (the old folder stays as a backup).
$LegacyDir = Join-Path $Root 'data'
if ((Test-Path (Join-Path $LegacyDir 'tracker.json')) -and -not (Test-Path $DataDir)) { Copy-Item -Recurse $LegacyDir $DataDir }

New-Item -ItemType Directory -Force -Path $DataDir, $BackupDir | Out-Null

# ---------------------------------------------------------------- helpers

function Write-Log([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    [IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, $Utf8)
    Write-Verbose $line
}

function Get-Prop($Object, [string]$Name) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }
    return $null
}

function Set-Prop($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Read-Db {
    if (-not (Test-Path $DbPath)) {
        return [pscustomobject]@{
            version        = 0
            spools         = @()
            prints         = @()
            settings       = [pscustomobject]@{ lowGrams = 150 }
            lastSync       = $null
            lastSyncResult = $null
        }
    }
    return [IO.File]::ReadAllText($DbPath, $Utf8) | ConvertFrom-Json
}

function Write-Db($Db) {
    # One backup per day, taken before the first write of the day.
    $stamp = Join-Path $BackupDir ('tracker-{0:yyyy-MM-dd}.json' -f (Get-Date))
    if ((Test-Path $DbPath) -and -not (Test-Path $stamp)) { Copy-Item $DbPath $stamp }

    $tmp = "$DbPath.tmp"
    [IO.File]::WriteAllText($tmp, ($Db | ConvertTo-Json -Depth 30 -Compress), $Utf8)
    if (Test-Path $DbPath) { [IO.File]::Replace($tmp, $DbPath, [NullString]::Value) } else { Move-Item $tmp $DbPath }
}

function ConvertFrom-SecureToPlain([Security.SecureString]$Secure) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-Token {
    if (-not (Test-Path $TokenPath)) { return $null }
    return ConvertFrom-SecureToPlain (Import-Clixml $TokenPath)
}

function Get-AuthInfo {
    $info = [ordered]@{ loggedIn = (Test-Path $TokenPath); expiresAt = $null; invalid = $false }
    if (Test-Path $AuthPath) {
        $a = [IO.File]::ReadAllText($AuthPath, $Utf8) | ConvertFrom-Json
        $info.expiresAt = Get-Prop $a 'expiresAt'
        $info.invalid   = [bool](Get-Prop $a 'invalid')
    }
    return [pscustomobject]$info
}

function Set-AuthInfo([string]$ExpiresAt, [bool]$Invalid) {
    $json = [pscustomobject]@{ expiresAt = $ExpiresAt; invalid = $Invalid } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($AuthPath, $json, $Utf8)
}

function Get-HttpStatus($ErrorRecord) {
    $resp = $ErrorRecord.Exception.Response
    if ($resp) { return [int]$resp.StatusCode }
    return 0
}

# ---------------------------------------------------------------- Bambu Cloud

function Invoke-Bambu([string]$Method, [string]$Path, $Body, [string]$Token) {
    $params = @{
        Method          = $Method
        Uri             = "$ApiBase$Path"
        ContentType     = 'application/json'
        UseBasicParsing = $true
        Headers         = @{}
    }
    if ($Token) { $params.Headers['Authorization'] = "Bearer $Token" }
    if ($null -ne $Body) { $params.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Compress)) }
    return Invoke-RestMethod @params
}

function Get-AllTasks([string]$Token) {
    # my/tasks pages with limit/offset; stop when a page adds nothing new so an ignored offset can't loop.
    $seen  = @{}
    $tasks = New-Object System.Collections.ArrayList
    $limit = 100
    $offset = 0
    for ($page = 0; $page -lt 100; $page++) {
        $r = Invoke-Bambu GET "/v1/user-service/my/tasks?limit=$limit&offset=$offset" $null $Token
        $hits = @(Get-Prop $r 'hits') | Where-Object { $_ }
        $added = 0
        foreach ($h in $hits) {
            $id = [string](Get-Prop $h 'id')
            if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; [void]$tasks.Add($h); $added++ }
        }
        $total = Get-Prop $r 'total'
        if ($added -eq 0 -or @($hits).Count -lt $limit) { break }
        if ($total -and $tasks.Count -ge [int]$total) { break }
        $offset += @($hits).Count
    }
    return ,$tasks
}

function Convert-Task($Task) {
    $statusRaw = Get-Prop $Task 'status'
    $status = switch ([int]$statusRaw) {
        2       { 'finished' }
        3       { 'failed' }      # failed or cancelled
        1       { 'printing' }
        4       { 'printing' }
        default { 'unknown' }
    }

    $usages = @()
    foreach ($m in @(Get-Prop $Task 'amsDetailMapping')) {
        if ($null -eq $m) { continue }
        # 'ams' is the global tray index (0-3 = AMS lite slots 1-4; negative/254/255 = external spool).
        # amsId/slotId on these entries are unreliable (usually 0/0).
        $tray = Get-Prop $m 'ams'
        $slot = $null
        if ($null -ne $tray -and [int]$tray -ge 0 -and [int]$tray -lt 16) { $slot = [int]$tray + 1 }
        $type  = Get-Prop $m 'targetFilamentType'; if (-not $type)  { $type  = Get-Prop $m 'filamentType' }
        $color = Get-Prop $m 'targetColor';        if (-not $color) { $color = Get-Prop $m 'sourceColor' }
        $usages += [pscustomobject]@{
            slot        = $slot
            tray        = $tray
            type        = $type
            color       = $color
            sourceColor = Get-Prop $m 'sourceColor'
            filamentId  = Get-Prop $m 'filamentId'
            grams       = [math]::Round([double](Get-Prop $m 'weight'), 2)
        }
    }

    $weight = [math]::Round([double](Get-Prop $Task 'weight'), 2)
    if ($usages.Count -eq 0 -and $weight -gt 0) {
        $usages += [pscustomobject]@{ slot = $null; type = $null; color = $null; filamentId = $null; grams = $weight }
    }

    $title = Get-Prop $Task 'title'
    if (-not $title) { $title = Get-Prop $Task 'designTitle' }

    return [pscustomobject]@{
        id           = [string](Get-Prop $Task 'id')
        title        = $title
        device       = Get-Prop $Task 'deviceName'
        start        = Get-Prop $Task 'startTime'
        end          = Get-Prop $Task 'endTime'
        status       = $status
        statusRaw    = $statusRaw
        plannedGrams = $weight
        estSeconds   = Get-Prop $Task 'costTime'   # slicer's estimated print time
        usages       = $usages
        reviewed     = $false
    }
}

function Invoke-Sync {
    $db = Read-Db
    $result = [ordered]@{ at = (Get-Date).ToString('o'); ok = $false; fetched = 0; added = 0; message = '' }
    try {
        if ($TasksFile) {
            $raw   = [IO.File]::ReadAllText((Resolve-Path $TasksFile), $Utf8) | ConvertFrom-Json
            $tasks = @(Get-Prop $raw 'hits')
        } else {
            $token = Get-Token
            if (-not $token) { throw 'Not signed in to Bambu Cloud yet. Run Login.cmd.' }
            try { $tasks = Get-AllTasks $token }
            catch {
                $code = Get-HttpStatus $_
                if ($code -eq 401 -or $code -eq 403) {
                    $auth = Get-AuthInfo
                    Set-AuthInfo $auth.expiresAt $true
                    throw 'Bambu login has expired. Run Login.cmd to sign in again.'
                }
                throw
            }
        }

        $known = @{}
        foreach ($p in @($db.prints)) { if ($p) { $known[[string]$p.id] = $p } }
        $new = @()
        foreach ($t in $tasks) {
            if (-not $t) { continue }
            $p = Convert-Task $t
            if ($p.id -and $known.ContainsKey($p.id)) {
                # Fill in fields added after a print was first imported.
                $old = $known[$p.id]
                if ($null -eq (Get-Prop $old 'estSeconds')) { Set-Prop $old 'estSeconds' $p.estSeconds }
                continue
            }
            if ($p.status -eq 'printing' -or -not $p.id) { continue }
            $known[$p.id] = $p
            $new += $p
        }

        $db.prints = @($new) + @(@($db.prints) | Where-Object { $_ })
        Set-Prop $db 'lastSync' $result.at
        $result.ok = $true
        $result.fetched = @($tasks).Count
        $result.added = $new.Count
        $result.message = "Checked $($result.fetched) cloud prints, added $($result.added) new."
    } catch {
        $result.message = $_.Exception.Message
    }

    Set-Prop $db 'lastSyncResult' ([pscustomobject]$result)
    $db.version = [int]$db.version + 1
    Write-Db $db
    Write-Log ("sync {0}: {1}" -f ($(if ($result.ok) { 'ok' } else { 'FAILED' }), $result.message))
    return [pscustomobject]$result
}

function Get-ErrorCode($ErrorRecord) {
    # Bambu returns {"code":N,"error":"..."} bodies on 400s.
    try { return Get-Prop ($ErrorRecord.ErrorDetails.Message | ConvertFrom-Json) 'code' } catch { return $null }
}

function Invoke-EmailCodeLogin([string]$Email) {
    Invoke-Bambu POST '/v1/user-service/user/sendemail/code' @{ email = $Email; type = 'codeLogin' } | Out-Null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $code = (Read-Host "Bambu emailed a code to $Email. Enter it").Trim()
        try { return Invoke-Bambu POST '/v1/user-service/user/login' @{ account = $Email; code = $code } }
        catch {
            if ((Get-HttpStatus $_) -ne 400) { throw }
            if ((Get-ErrorCode $_) -eq 1) {
                Write-Host 'That code expired. Sending a fresh one.' -ForegroundColor Yellow
                Invoke-Bambu POST '/v1/user-service/user/sendemail/code' @{ email = $Email; type = 'codeLogin' } | Out-Null
            } else {
                Write-Host 'That code was not accepted. Try again.' -ForegroundColor Yellow
            }
        }
    }
    throw 'Login failed after 3 codes.'
}

function Invoke-Login {
    Write-Host ''
    Write-Host 'Sign in to Bambu Cloud.' -ForegroundColor Cyan
    Write-Host 'If you sign in to Bambu with Google or Apple, leave the password blank and Bambu will'
    Write-Host 'email you a one-time code instead. A password, if you use one, goes only to Bambu and'
    Write-Host 'is not saved. The access token Bambu returns is stored in %USERPROFILE%\Spooldex, encrypted so'
    Write-Host 'only your Windows account can read it.'
    Write-Host ''
    $email = (Read-Host 'Bambu account email').Trim()
    $pw = ConvertFrom-SecureToPlain (Read-Host 'Password (blank for Google/Apple sign-in)' -AsSecureString)

    if ($pw) {
        $r = Invoke-Bambu POST '/v1/user-service/user/login' @{ account = $email; password = $pw; apiError = '' }
        $pw = $null
        $loginType = Get-Prop $r 'loginType'
        if (-not (Get-Prop $r 'accessToken')) {
            # verifyCode, or authenticator 2FA - both can be satisfied with an emailed code.
            if ($loginType -eq 'tfa') { Write-Host 'Your account uses authenticator 2FA; using an emailed code instead.' }
            $r = Invoke-EmailCodeLogin $email
        }
    } else {
        $r = Invoke-EmailCodeLogin $email
    }

    $token = Get-Prop $r 'accessToken'
    if (-not $token) { throw 'Login failed: Bambu did not return an access token.' }

    ConvertTo-SecureString $token -AsPlainText -Force | Export-Clixml $TokenPath
    $expiresIn = Get-Prop $r 'expiresIn'
    if (-not $expiresIn) { $expiresIn = 7776000 }
    Set-AuthInfo ((Get-Date).AddSeconds([int]$expiresIn).ToString('o')) $false

    $tasks = Get-AllTasks $token
    Write-Host ''
    Write-Host "Signed in. Bambu Cloud has $($tasks.Count) prints in your history." -ForegroundColor Green
    Write-Host 'Open Spooldex from the desktop shortcut to import them.'
}

# ---------------------------------------------------------------- local web server

function Send-Bytes($Ctx, [int]$Code, [string]$ContentType, [byte[]]$Bytes) {
    $res = $Ctx.Response
    $res.StatusCode = $Code
    $res.ContentType = $ContentType
    $res.Headers['Cache-Control'] = 'no-store'
    $res.ContentLength64 = $Bytes.Length
    $res.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $res.OutputStream.Close()
}

function Send-Json($Ctx, [int]$Code, [string]$Json) {
    Send-Bytes $Ctx $Code 'application/json; charset=utf-8' $Utf8.GetBytes($Json)
}

function Get-StateJson {
    $db = Read-Db
    Set-Prop $db 'auth' (Get-AuthInfo)
    return $db | ConvertTo-Json -Depth 30 -Compress
}

function Invoke-Request($Ctx) {
    $req = $Ctx.Request
    # Only answer pages served from this server: blocks DNS rebinding and cross-site POSTs.
    if ($req.Headers['Host'] -notmatch "^(localhost|127\.0\.0\.1):$Port$") { Send-Json $Ctx 403 '{"error":"forbidden"}'; return }
    if ($req.HttpMethod -eq 'POST' -and $req.Headers['X-Spooldex'] -ne '1') { Send-Json $Ctx 403 '{"error":"forbidden"}'; return }

    switch ("$($req.HttpMethod) $($req.Url.AbsolutePath)") {
        'GET /'           { Send-Bytes $Ctx 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($IndexPath)) }
        'GET /favicon.ico' { Send-Bytes $Ctx 200 'image/x-icon' ([IO.File]::ReadAllBytes((Join-Path $Root 'assets\icon.ico'))) }
        'GET /api/state'  { Send-Json $Ctx 200 (Get-StateJson) }
        'GET /api/ping'   { Send-Json $Ctx 200 '{"ok":true}' }
        'POST /api/sync'  { Invoke-Sync | Out-Null; Send-Json $Ctx 200 (Get-StateJson) }
        'POST /api/save'  {
            $body = (New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd()
            $incoming = $body | ConvertFrom-Json
            $current = Read-Db
            if ([int](Get-Prop $incoming 'version') -ne [int]$current.version) { Send-Json $Ctx 409 '{"error":"The data changed since the page loaded."}'; return }
            $incoming.PSObject.Properties.Remove('auth')
            $incoming.version = [int]$current.version + 1
            Write-Db $incoming
            Send-Json $Ctx 200 (Get-StateJson)
        }
        default { Send-Json $Ctx 404 '{"error":"not found"}' }
    }
}

function Start-Server {
    $url = "http://localhost:$Port/"
    $listener = New-Object Net.HttpListener
    $listener.Prefixes.Add($url)
    try { $listener.Start() }
    catch {
        # Already running from an earlier launch - just show it.
        if (-not $NoBrowser) { Start-Process $url }
        return
    }
    Write-Log "server started on $url"
    if (-not $NoBrowser) { Start-Process $url }

    # Exit once the page has been closed for a while (it pings every minute while open).
    $lastSeen = Get-Date
    try {
        while ($listener.IsListening) {
            $pending = $listener.BeginGetContext($null, $null)
            while (-not $pending.AsyncWaitHandle.WaitOne(1000)) {
                if (((Get-Date) - $lastSeen).TotalMinutes -ge $IdleMinutes) { return }
            }
            $ctx = $listener.EndGetContext($pending)
            $lastSeen = Get-Date
            try { Invoke-Request $ctx }
            catch {
                Write-Log "request error: $($_.Exception.Message)"
                try { Send-Json $ctx 500 (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) } catch { }
            }
        }
    } finally {
        $listener.Close()
        Write-Log 'server stopped'
    }
}

# ---------------------------------------------------------------- main

if ($Login) {
    Invoke-Login
} elseif ($SyncOnly) {
    # At logon the network may not be up yet; retry a few times unless it's a login problem.
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $r = Invoke-Sync
        if ($r.ok -or $r.message -match 'Login|signed in') { break }
        Start-Sleep -Seconds 30
    }
} else {
    Start-Server
}
