# smoke_e2e.ps1 -- full happy-path end-to-end smoke test for the Veynoria backend.
#
# Exercises: device auth -> bootstrap_profile -> start_public_search (x2 accounts) ->
# socket matchmaker_add -> match_join -> play a rated match (Player B concedes on
# turn 1, Player A wins) -> verify rating/leaderboard/history updated and
# activeMatchId cleared.
#
# Prerequisites: docker compose up, Nakama at localhost:7350/7349, clean DB
# (otherwise reused device IDs / leaderboard records may skew assertions).
#
# Usage:  pwsh -File .\smoke_e2e.ps1
# Each step prints PASS or FAIL; first FAIL exits non-zero.

$ErrorActionPreference = 'Stop'

# ---------- config ----------
$httpBase  = "http://localhost:7350"
$wsBase    = "ws://localhost:7349"
$serverKey = "defaultkey"
$authB64   = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${serverKey}:"))

# Random device IDs so reruns don't clash with prior state.
$rand = [Guid]::NewGuid().ToString("N").Substring(0,10)
$devA = "smoke-A-$rand"
$devB = "smoke-B-$rand"
$nameA = "SmokeA$rand"
$nameB = "SmokeB$rand"

$stepNum = 0
function Step([string]$desc, [scriptblock]$body) {
    $script:stepNum++
    try {
        & $body
        Write-Host "[$stepNum] PASS  $desc" -ForegroundColor Green
    } catch {
        Write-Host "[$stepNum] FAIL  $desc" -ForegroundColor Red
        Write-Host "       $_" -ForegroundColor Red
        exit 1
    }
}

# ---------- HTTP helpers ----------
function Auth([string]$deviceId, [string]$username) {
    $body = @{ id = $deviceId; username = $username } | ConvertTo-Json -Compress
    $resp = Invoke-RestMethod -Method Post `
        -Uri "$httpBase/v2/account/authenticate/device?create=true&username=$username" `
        -Headers @{ Authorization = "Basic $authB64"; "Content-Type" = "application/json" } `
        -Body $body
    return $resp.token
}

function Rpc([string]$token, [string]$rpc, [string]$payload) {
    # Nakama RPC HTTP body is the raw JSON-as-string (quoted) per /v2/rpc spec.
    $bodyQuoted = ConvertTo-Json -InputObject $payload -Compress
    $resp = Invoke-RestMethod -Method Post `
        -Uri "$httpBase/v2/rpc/$rpc" `
        -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
        -Body $bodyQuoted
    if ($null -ne $resp.payload -and $resp.payload -ne "") {
        return $resp.payload | ConvertFrom-Json
    }
    return $resp
}

function ListLeaderboard([string]$token, [string]$leaderboardId) {
    return Invoke-RestMethod -Method Get `
        -Uri "$httpBase/v2/leaderboard/$leaderboardId" `
        -Headers @{ Authorization = "Bearer $token" }
}

function ReadStorage([string]$token, [string]$userId, [string]$collection, [string]$key) {
    $body = @{ object_ids = @(@{ collection = $collection; key = $key; user_id = $userId }) } |
        ConvertTo-Json -Compress -Depth 6
    return Invoke-RestMethod -Method Post `
        -Uri "$httpBase/v2/storage" `
        -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
        -Body $body
}

# ---------- WebSocket helpers ----------
function NewSocket([string]$token) {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $uri = [Uri]"$wsBase/ws?token=$token&format=json&status=true&lang=en"
    $ws.ConnectAsync($uri, [Threading.CancellationToken]::None).Wait(5000) | Out-Null
    if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        throw "WebSocket failed to open (state=$($ws.State))"
    }
    return $ws
}

function WsSend([System.Net.WebSockets.ClientWebSocket]$ws, [string]$json) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $seg = [System.ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true,
        [Threading.CancellationToken]::None).Wait(5000) | Out-Null
}

# Receive ONE complete text frame (may be reassembled from fragments). Returns $null on timeout.
function WsRecv([System.Net.WebSockets.ClientWebSocket]$ws, [int]$timeoutMs = 8000) {
    $buf = New-Object byte[] 131072
    $sb  = New-Object Text.StringBuilder
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
    while ([DateTime]::UtcNow -lt $deadline -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $seg = [System.ArraySegment[byte]]::new($buf)
        $task = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None)
        $msLeft = [int]([math]::Max(50, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        if (-not $task.Wait($msLeft)) { return $null }
        $result = $task.Result
        if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { return $null }
        $null = $sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $result.Count))
        if ($result.EndOfMessage) { return $sb.ToString() }
    }
    return $null
}

# Wait for an envelope whose top-level key matches $field. Drains intervening events
# and returns the parsed object, or $null on timeout.
function WsWaitFor([System.Net.WebSockets.ClientWebSocket]$ws, [string]$field, [int]$timeoutMs = 10000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $msLeft = [int]([math]::Max(50, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        $msg = WsRecv $ws $msLeft
        if ($null -eq $msg) { continue }
        try { $obj = $msg | ConvertFrom-Json } catch { continue }
        if ($obj.PSObject.Properties.Name -contains $field) { return $obj }
    }
    return $null
}

# Wait for a match_data event with a specific op_code (string per Nakama JSON proto).
function WsWaitMatchData([System.Net.WebSockets.ClientWebSocket]$ws, [string]$wantOpCode, [int]$timeoutMs = 10000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $msLeft = [int]([math]::Max(50, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        $msg = WsRecv $ws $msLeft
        if ($null -eq $msg) { continue }
        try { $obj = $msg | ConvertFrom-Json } catch { continue }
        if ($obj.match_data -and "$($obj.match_data.op_code)" -eq $wantOpCode) { return $obj.match_data }
    }
    return $null
}

Write-Host "`n=== Veynoria backend end-to-end smoke test ===`n" -ForegroundColor Cyan
Write-Host "Device IDs: $devA / $devB`n"

# ---------- 1. Device auth ----------
$tokA = $null; $tokB = $null
Step "Device auth both accounts" {
    $script:tokA = Auth $devA $nameA
    $script:tokB = Auth $devB $nameB
    if (-not $script:tokA -or -not $script:tokB) { throw "missing token" }
}

# Decode user IDs from JWTs (Nakama embeds uid in JWT payload).
function Uid([string]$tok) {
    $payload = $tok.Split('.')[1]
    while ($payload.Length % 4) { $payload += '=' }
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload.Replace('-','+').Replace('_','/')))
    return ($json | ConvertFrom-Json).uid
}
$uidA = Uid $tokA
$uidB = Uid $tokB

# ---------- 2. bootstrap_profile ----------
Step "bootstrap_profile for both accounts" {
    $bp = @{ displayName = $nameA; generation = "merfolk"; avatarId = "preset_07" } | ConvertTo-Json -Compress
    $rA = Rpc $tokA "bootstrap_profile" $bp
    if (-not $rA.ok) { throw "A bootstrap not ok: $($rA | ConvertTo-Json)" }
    $bp = @{ displayName = $nameB; generation = "stoneborn"; avatarId = "preset_02" } | ConvertTo-Json -Compress
    $rB = Rpc $tokB "bootstrap_profile" $bp
    if (-not $rB.ok) { throw "B bootstrap not ok: $($rB | ConvertTo-Json)" }
}

# ---------- 3. start_public_search ----------
$mmA = $null; $mmB = $null
Step "start_public_search returns matchmaker params for both" {
    $req = '{"playerCount":2}'
    $script:mmA = Rpc $tokA "start_public_search" $req
    $script:mmB = Rpc $tokB "start_public_search" $req
    foreach ($r in @($script:mmA, $script:mmB)) {
        if ($r.minCount -ne 2 -or $r.maxCount -ne 2) { throw "bad min/max: $($r | ConvertTo-Json)" }
        if (-not $r.query) { throw "missing query" }
        if ($r.timeoutSeconds -le 0) { throw "missing timeoutSeconds (config externalization)" }
    }
}

# ---------- 4. Open WebSockets ----------
$wsA = $null; $wsB = $null
Step "Open realtime WebSocket for both accounts" {
    $script:wsA = NewSocket $tokA
    $script:wsB = NewSocket $tokB
}

try {
    # ---------- 5. matchmaker_add ----------
    Step "matchmaker_add on both sockets" {
        foreach ($pair in @(@($wsA, $mmA, "a1"), @($wsB, $mmB, "b1"))) {
            $env = @{
                cid = $pair[2]
                matchmaker_add = @{
                    min_count          = $pair[1].minCount
                    max_count          = $pair[1].maxCount
                    query              = $pair[1].query
                    numeric_properties = $pair[1].numericProperties
                    string_properties  = $pair[1].stringProperties
                }
            } | ConvertTo-Json -Compress -Depth 6
            WsSend $pair[0] $env
        }
        # Drain the matchmaker_ticket acks (don't block on them).
        foreach ($ws in @($wsA, $wsB)) {
            $ack = WsWaitFor $ws "matchmaker_ticket" 4000
            if (-not $ack) { throw "no matchmaker_ticket ack" }
        }
    }

    # ---------- 6. Await matchmaker_matched, capture join token ----------
    $matchTokenA = $null; $matchTokenB = $null; $matchId = $null
    Step "Both sockets receive matchmaker_matched" {
        $mA = WsWaitFor $wsA "matchmaker_matched" 15000
        $mB = WsWaitFor $wsB "matchmaker_matched" 15000
        if (-not $mA -or -not $mB) { throw "matchmaker_matched not received" }
        $script:matchTokenA = $mA.matchmaker_matched.token
        $script:matchTokenB = $mB.matchmaker_matched.token
        $script:matchId     = $mA.matchmaker_matched.match_id
        if (-not $script:matchTokenA -or -not $script:matchTokenB) { throw "missing join token" }
    }

    # ---------- 7. match_join + auto-start ----------
    Step "match_join both sockets, observe STATE_FULL and TURN_CHANGE (auto-start)" {
        foreach ($pair in @(@($wsA, $matchTokenA, "a2"), @($wsB, $matchTokenB, "b2"))) {
            $env = @{ cid = $pair[2]; match_join = @{ token = $pair[1] } } | ConvertTo-Json -Compress
            WsSend $pair[0] $env
        }
        # Each socket gets a match-join ack + STATE_FULL (op 100); auto-start fires
        # TURN_CHANGE (op 102) once both players are connected.
        $tcA = WsWaitMatchData $wsA "102" 10000
        $tcB = WsWaitMatchData $wsB "102" 10000
        if (-not $tcA -or -not $tcB) { throw "no TURN_CHANGE received -- match did not auto-start" }
    }

    # ---------- 8. Player B concedes ----------
    Step "Player B sends CONCEDE (op 6)" {
        $env = @{
            cid = "b3"
            match_data_send = @{
                match_id = $matchId
                op_code  = "6"
                data     = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("{}"))
            }
        } | ConvertTo-Json -Compress -Depth 5
        WsSend $wsB $env
    }

    # ---------- 9. GAME_ENDED with A as winner ----------
    Step "Both sockets receive GAME_ENDED (op 106) with A as winner" {
        $geA = WsWaitMatchData $wsA "106" 10000
        $geB = WsWaitMatchData $wsB "106" 10000
        if (-not $geA -or -not $geB) { throw "no GAME_ENDED received" }
        $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($geA.data))
        $ended   = $payload | ConvertFrom-Json
        if ($ended.winnerUserId -ne $uidA) {
            throw "winnerUserId=$($ended.winnerUserId) (want $uidA)"
        }
    }
} finally {
    foreach ($ws in @($wsA, $wsB)) {
        if ($ws -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "bye",
                [Threading.CancellationToken]::None).Wait(2000) | Out-Null } catch {}
        }
    }
}

# Give finalizeMatch (storage writes + rating + activeMatchId clear) a moment.
Start-Sleep -Milliseconds 800

# ---------- 10. activeMatchId cleared for both ----------
Step "get_active_game returns null for both accounts" {
    foreach ($pair in @(@($tokA,"A"), @($tokB,"B"))) {
        $ag = Rpc $pair[0] "get_active_game" "{}"
        if ($null -ne $ag.matchId) { throw "$($pair[1]) still has activeMatchId=$($ag.matchId)" }
    }
}

# ---------- 11. History written for winner with non-zero rating delta ----------
Step "get_match_history for A shows one online win with non-zero ratingDelta" {
    $hist = Rpc $tokA "get_match_history" '{"filter":"online"}'
    if (-not $hist.entries -or $hist.entries.Count -lt 1) { throw "no history entries" }
    $entry = $hist.entries[0]
    if ($entry.result -ne "win")  { throw "result=$($entry.result) (want win)" }
    if ($entry.isAI)              { throw "entry flagged isAI=true (want false)" }
    if ($entry.ratingDelta -eq 0) { throw "ratingDelta=0 -- rating engine did not run" }
}

# ---------- 12. Rating profile reflects the win (leaderboard hidden while provisional) ----------
Step "Rating profile for A shows wins=1, gamesPlayed=1, rating updated" {
    $resp = ReadStorage $tokA $uidA "rating" "profile"
    if (-not $resp.objects -or $resp.objects.Count -lt 1) { throw "no rating record for A" }
    $prof = $resp.objects[0].value | ConvertFrom-Json
    if ($prof.wins -lt 1)         { throw "wins=$($prof.wins) (want >=1)" }
    if ($prof.gamesPlayed -lt 1)  { throw "gamesPlayed=$($prof.gamesPlayed) (want >=1)" }
    if ($prof.rating -le 1000)    { throw "rating=$($prof.rating) (want >1000 after a win)" }
    # Sanity: with PROVISIONAL_GAMES=10 default, first game stays provisional -> no leaderboard write.
    if (-not $prof.provisional) {
        # If provisional flipped off (env override), the leaderboard should now have A.
        $lb = ListLeaderboard $tokA "veynoria_elo"
        if (-not ($lb.records | Where-Object { $_.owner_id -eq $uidA })) {
            throw "non-provisional but A not on leaderboard"
        }
    }
}

Write-Host "`n=== ALL STEPS PASS ===" -ForegroundColor Green
exit 0
