#!/usr/bin/env bash
# Put the Splendor game server, its download page and the Android app on the
# VPS that also runs Veynoria. Splendor has its own containers, network,
# database volume, port (127.0.0.1:7450) and nginx site (splendor.mspink.ir),
# so Veynoria (veinora.mspink.ir, 127.0.0.1:7350) is never touched.
#
#   ./deploy/deploy.sh                 # server + page + apk
#   ./deploy/deploy.sh apk             # only the page and the apk
#
# Needs: the client key of the server (see C:\projects\my-servers\...).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${SPLENDOR_SSH_KEY:-C:/projects/my-servers/personal-89.44.240.29/personal-client.pem}"
HOST="${SPLENDOR_HOST:-client@89.44.240.29}"
DOMAIN="splendor.mspink.ir"
SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes "$HOST")
APK="$ROOT/client-godot/build/android/splendor.apk"

publish_web() {
  echo "== download page and apk"
  "${SSH[@]}" "sudo mkdir -p /var/www/splendor/download && sudo chown -R \$USER /var/www/splendor"
  tar -C "$ROOT/deploy/web" -cf - . | "${SSH[@]}" "tar -C /var/www/splendor -xf -"
  if [ -f "$APK" ]; then
    scp -i "$KEY" -o IdentitiesOnly=yes "$APK" "$HOST:/var/www/splendor/download/splendor.apk.new"
    "${SSH[@]}" "mv /var/www/splendor/download/splendor.apk.new /var/www/splendor/download/splendor.apk"
  fi
}

if [ "${1:-}" = "apk" ]; then publish_web; exit 0; fi

echo "== copying the server to /opt/splendor"
"${SSH[@]}" "sudo mkdir -p /opt/splendor && sudo chown \$USER /opt/splendor"
tar -C "$ROOT" -czf - runtime Dockerfile docker-compose.yml deploy/env.template deploy/nginx \
  | "${SSH[@]}" "tar -C /opt/splendor -xzf -"

echo "== building and starting the server"
"${SSH[@]}" bash -s <<'REMOTE'
set -euo pipefail
cd /opt/splendor
if [ ! -f .env ]; then
  rnd() { head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32; }
  sed -e "s/@POSTGRES@/$(rnd)/" -e "s/@SESSION@/$(rnd)/" -e "s/@REFRESH@/$(rnd)/" \
      -e "s/@CONSOLE@/$(rnd)/" deploy/env.template > .env
  chmod 600 .env
  echo "created .env"
fi
docker compose build -q
docker compose up -d
for i in $(seq 1 45); do
  if curl -fsS http://127.0.0.1:7450/healthcheck >/dev/null 2>&1; then echo "server is up"; exit 0; fi
  sleep 2
done
echo "server did not answer"; docker logs --tail 60 splendor-nakama; exit 1
REMOTE

echo "== nginx site"
"${SSH[@]}" bash -s <<REMOTE
set -euo pipefail
sudo cp /opt/splendor/deploy/nginx/splendor.conf /etc/nginx/sites-available/splendor
if [ ! -e /etc/letsencrypt/live/$DOMAIN ]; then
  sudo ln -sf /etc/nginx/sites-available/splendor /etc/nginx/sites-enabled/splendor
  sudo nginx -t && sudo systemctl reload nginx
  sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email --redirect
else
  echo "certificate exists; the site file certbot edited is kept"
fi
sudo nginx -t && sudo systemctl reload nginx
REMOTE

publish_web
echo "== check"
curl -fsS "https://$DOMAIN/healthcheck" && echo " <- https://$DOMAIN/healthcheck"
