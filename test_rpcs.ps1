# Quick smoke-test for bootstrap_profile and get_active_game RPCs.
# Run AFTER `docker compose up` and Nakama is ready at localhost:7350.
# Usage: .\test_rpcs.ps1

$base = "http://localhost:7350"
$serverKey = "defaultkey"   # Nakama default server key

# 1. Authenticate as a device (creates account if new)
$authBody = '{"id":"test-device-001","create":true,"username":"testplayer1"}'
$authB64   = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${serverKey}:"))
$authResp  = Invoke-RestMethod -Method Post `
    -Uri "$base/v2/account/authenticate/device?create=true&username=testplayer1" `
    -Headers @{ Authorization = "Basic $authB64"; "Content-Type" = "application/json" } `
    -Body $authBody

$token = $authResp.token
Write-Host "`n[1] Auth token: $($token.Substring(0,40))..."

# 2. Call bootstrap_profile
$bpBody = '{"displayName":"TestPlayer","generation":"merfolk","avatarId":"preset_07"}'
$bpResp  = Invoke-RestMethod -Method Post `
    -Uri "$base/v2/rpc/bootstrap_profile" `
    -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
    -Body $bpBody

Write-Host "`n[2] bootstrap_profile response:"
$bpResp | ConvertTo-Json

# 3. Call get_active_game
$agResp = Invoke-RestMethod -Method Post `
    -Uri "$base/v2/rpc/get_active_game" `
    -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
    -Body '{}'

Write-Host "`n[3] get_active_game response:"
$agResp | ConvertTo-Json
