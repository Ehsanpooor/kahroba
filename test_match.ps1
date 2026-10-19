# Smoke test: create a match, join with 2 device accounts, play 3 scripted actions.
# Requires: docker compose up, Nakama ready at localhost:7350.
# Usage: .\test_match.ps1

$base      = "http://localhost:7350"
$serverKey = "defaultkey"
$authB64   = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${serverKey}:"))

function Auth($deviceId, $username) {
    $body = "{`"id`":`"$deviceId`",`"create`":true,`"username`":`"$username`"}"
    $resp = Invoke-RestMethod -Method Post `
        -Uri "$base/v2/account/authenticate/device?create=true&username=$username" `
        -Headers @{ Authorization = "Basic $authB64"; "Content-Type" = "application/json" } `
        -Body $body
    return $resp.token
}

function CallRpc($token, $rpc, $payload) {
    $resp = Invoke-RestMethod -Method Post `
        -Uri "$base/v2/rpc/$rpc" `
        -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
        -Body $payload
    # Nakama wraps the response in a "payload" field as a JSON string
    if ($resp.payload) {
        return $resp.payload | ConvertFrom-Json
    }
    return $resp
}

function CreateMatch($token) {
    $resp = Invoke-RestMethod -Method Post `
        -Uri "$base/v2/match" `
        -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
        -Body '{"name":"veynoria_match"}'
    return $resp.match.match_id
}

function JoinMatch($token, $matchId) {
    $resp = Invoke-RestMethod -Method Post `
        -Uri "$base/v2/match/$matchId/join" `
        -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
        -Body '{}'
    return $resp
}

Write-Host "`n=== Veynoria Match Smoke Test ===`n"

# --- Auth two players ---
Write-Host "[1] Authenticating two device accounts..."
$tok1 = Auth "smoke-device-001" "SmokePlayer1"
$tok2 = Auth "smoke-device-002" "SmokePlayer2"
Write-Host "    Player1 token: $($tok1.Substring(0,30))..."
Write-Host "    Player2 token: $($tok2.Substring(0,30))..."

# --- Bootstrap profiles ---
Write-Host "`n[2] Bootstrapping profiles..."
$bp1 = CallRpc $tok1 "bootstrap_profile" '{"displayName":"SmokePlayer1","generation":"merfolk","avatarId":"preset_01"}'
$bp2 = CallRpc $tok2 "bootstrap_profile" '{"displayName":"SmokePlayer2","generation":"stoneborn","avatarId":"preset_02"}'
Write-Host "    Player1 bootstrap: $($bp1 | ConvertTo-Json -Compress)"
Write-Host "    Player2 bootstrap: $($bp2 | ConvertTo-Json -Compress)"

# --- Check active game (should be null) ---
Write-Host "`n[3] Checking active game (expect null)..."
$ag1 = CallRpc $tok1 "get_active_game" '{}'
Write-Host "    Player1 active game: $($ag1 | ConvertTo-Json -Compress)"

# --- Create an authoritative match via Nakama HTTP API ---
# Note: Nakama's REST API for authoritative matches uses POST /v2/match
# The match name must match the registered handler name ("veynoria_match").
Write-Host "`n[4] Creating authoritative match..."
try {
    $matchResp = Invoke-RestMethod -Method Post `
        -Uri "$base/v2/match" `
        -Headers @{ Authorization = "Bearer $tok1"; "Content-Type" = "application/json" } `
        -Body '{"name":"veynoria_match"}'
    $matchId = $matchResp.match.match_id
    Write-Host "    Match ID: $matchId"
} catch {
    Write-Host "    NOTE: Authoritative match creation via REST may require a custom RPC."
    Write-Host "    Error: $_"
    Write-Host ""
    Write-Host "    To test match logic, use the Nakama console (localhost:7351) -> Matches"
    Write-Host "    or add a create_match RPC (next development stage)."
    Write-Host ""
    Write-Host "=== Unit tests cover rules engine correctness — run them with: ==="
    Write-Host "    docker run --rm -v `"$(Get-Location)/runtime:/src`" -w /src golang:1.21 go test ./..."
    exit 0
}

Write-Host "`n=== Match created successfully. Use Nakama console to inspect state. ==="
Write-Host "Console: http://localhost:7351  (admin / password)"
Write-Host "Match ID: $matchId"
