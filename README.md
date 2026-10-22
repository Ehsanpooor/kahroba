# Splendor — the gem merchants

A Splendor-style board game for Android and Windows, made in Godot, with an online
game server. Persian first, English in Settings.

| Folder | What |
|---|---|
| `client-godot/` | The game (Godot 4.7, Compatibility renderer, landscape). |
| `runtime/` | The game server: a Nakama 3.22 Go module (rules, matchmaking, friends' rooms with a code, ratings, history, computer players). |
| `deploy/` | Putting the server, the download page and the APK on the VPS. |
| `Dockerfile`, `docker-compose.yml` | The server stack (Nakama + PostgreSQL). |
| `API_DOC.md`, `BACKEND_DOC.md` | The server's wire contract and design. |

## Play
- Live server and download page: **https://splendor.aizood.ir** (also answers at splendor.mspink.ir, the address of builds before 0.9.3) (APK at `/download/splendor.apk`).
- Against the computer the game runs on the device; online and friends' games run on the server.

## Run the server locally
```bash
docker compose build && docker compose up -d     # http://127.0.0.1:7450/healthcheck
```
Start the game against it with `-- --server=http://127.0.0.1:7450`.

## Build the game
Godot 4.7.2 with export templates. From `client-godot/`:
```bash
godot --headless --path . --export-release "Android" build/android/splendor.apk
godot --headless --path . --export-release "Windows" build/windows/Splendor.exe
```
The release APK is signed with a keystore that is not in this repository; pass it with
`GODOT_ANDROID_KEYSTORE_RELEASE_PATH`, `..._USER` and `..._PASSWORD`.

## Deploy
```bash
./deploy/deploy.sh          # server + download page + APK
./deploy/deploy.sh apk      # only the page and the APK
```
Splendor runs beside another game on the same VPS with its own containers, database,
port (127.0.0.1:7450) and nginx site, so the two never touch.

## Tests
- Server: `cd runtime && go test ./...`
- Game: `godot --headless --path client-godot -- --compilecheck`; online checks with
  `-- --nettest=host|guest|search --autoplay` (see `scripts/dev_net.gd`).
