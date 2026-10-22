#!/usr/bin/env bash
# Put the Splendor game server, its download page, the Android app and the
# Zood Gamers home page on the VPS that also runs Veynoria. Splendor has its
# own containers, network, database volume, port (127.0.0.1:7450) and nginx
# site (splendor.aizood.ir, and splendor.mspink.ir for the apps installed
# before 0.9.3); the home page has its own site (aizood.ir). Veynoria
# (veinora.mspink.ir, 127.0.0.1:7350) and the other sites are never touched.
#
#   ./deploy/deploy.sh                 # server + page + apk + home page
#   ./deploy/deploy.sh apk             # only the page and the apk
#   ./deploy/deploy.sh home            # only the aizood.ir home page
#
# Needs: the client key of the server (see C:\projects\my-servers\...).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${SPLENDOR_SSH_KEY:-C:/projects/my-servers/personal-89.44.240.29/personal-client.pem}"
HOST="${SPLENDOR_HOST:-client@89.44.240.29}"
DOMAIN="splendor.aizood.ir"
OLD_DOMAIN="splendor.mspink.ir"  # still served: older apps connect to it
HOME_DOMAIN="aizood.ir"          # the Zood Gamers home page
SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 "$HOST")
APK="$ROOT/client-godot/build/android/splendor.apk"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The VPS turns away a burst of SSH connections now and then. Every remote
# step here is safe to repeat, so a refused connection (exit 255) is tried
# again after a pause. rsh <stdin file, or -> <remote command...>
rsh() {
  local input="$1"; shift
  local n rc
  for n in 1 2 3 4 5 6; do
    rc=0
    if [ "$input" = "-" ]; then "${SSH[@]}" "$@" </dev/null || rc=$?; else "${SSH[@]}" "$@" <"$input" || rc=$?; fi
    [ "$rc" -ne 255 ] && return "$rc"
    echo "(the server refused the connection; trying again in 20 s)"
    sleep 20
  done
  return 255
}

rscp() {  # rscp <local file> <remote path>
  local n
  for n in 1 2 3 4 5 6; do
    scp -i "$KEY" -o IdentitiesOnly=yes -o ConnectTimeout=20 "$1" "$HOST:$2" && return 0
    echo "(copy failed; trying again in 20 s)"
    sleep 20
  done
  return 1
}

publish_web() {
  echo "== download page and apk"
  rsh - "sudo mkdir -p /var/www/splendor/download && sudo chown -R \$USER /var/www/splendor"
  tar -C "$ROOT/deploy/web" -cf "$TMP/web.tar" .
  rsh "$TMP/web.tar" "tar -C /var/www/splendor -xf -"
  if [ -f "$APK" ]; then
    rscp "$APK" /var/www/splendor/download/splendor.apk.new
    rsh - "mv /var/www/splendor/download/splendor.apk.new /var/www/splendor/download/splendor.apk"
  fi
}

publish_home() {
  echo "== the Zood Gamers home page ($HOME_DOMAIN)"
  rsh - "sudo mkdir -p /var/www/aizood && sudo chown -R \$USER /var/www/aizood"
  tar -C "$ROOT/deploy/home" -cf "$TMP/home.tar" .
  rsh "$TMP/home.tar" "tar -C /var/www/aizood -xf -"
  rscp "$ROOT/deploy/nginx/aizood.conf" /tmp/aizood.conf
  cat > "$TMP/home.sh" <<REMOTE
set -euo pipefail
# a site that certbot already set up for this address is left as it is: a
# fresh copy would be plain http until certbot answers, and the VPS's DNS
# does not always reach Let's Encrypt
if sudo grep -q "managed by Certbot" /etc/nginx/sites-available/aizood 2>/dev/null; then
  echo "$HOME_DOMAIN already has https; its site file is kept"
  exit 0
fi
sudo mv /tmp/aizood.conf /etc/nginx/sites-available/aizood
sudo ln -sf /etc/nginx/sites-available/aizood /etc/nginx/sites-enabled/aizood
sudo nginx -t && sudo systemctl reload nginx
# the copy above is plain http: certbot puts https on it
sudo certbot --nginx --cert-name $HOME_DOMAIN --reinstall -d $HOME_DOMAIN \\
  --non-interactive --agree-tos --register-unsafely-without-email --redirect
sudo nginx -t && sudo systemctl reload nginx
REMOTE
  rsh "$TMP/home.sh" bash -s
  curl -fsS -o /dev/null "https://$HOME_DOMAIN/" && echo " <- https://$HOME_DOMAIN/"
}

if [ "${1:-}" = "apk" ]; then publish_web; exit 0; fi
if [ "${1:-}" = "home" ]; then publish_home; exit 0; fi

echo "== copying the server to /opt/splendor"
rsh - "sudo mkdir -p /opt/splendor && sudo chown \$USER /opt/splendor"
# deploy/mail.env (not in git): the mail account, added to the server's .env once
MAIL_ENV=""; [ -f "$ROOT/deploy/mail.env" ] && MAIL_ENV="deploy/mail.env"
tar -C "$ROOT" -czf "$TMP/server.tgz" runtime Dockerfile docker-compose.yml deploy/env.template deploy/nginx $MAIL_ENV
rsh "$TMP/server.tgz" "tar -C /opt/splendor -xzf -"

echo "== building and starting the server"
cat > "$TMP/server.sh" <<'REMOTE'
set -euo pipefail
cd /opt/splendor
if [ ! -f .env ]; then
  rnd() { head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32; }
  sed -e "s/@POSTGRES@/$(rnd)/" -e "s/@SESSION@/$(rnd)/" -e "s/@REFRESH@/$(rnd)/" \
      -e "s/@CONSOLE@/$(rnd)/" deploy/env.template > .env
  chmod 600 .env
  echo "created .env"
fi
# settings added after the first deploy: append them once
if ! grep -q '^SMTP_HOST=' .env; then
  if [ -f deploy/mail.env ]; then
    cat deploy/mail.env >> .env
    echo "added the mail account to .env"
  else
    sed -n '/^# The mail account/,$p' deploy/env.template >> .env
    echo "added the (empty) mail settings to .env"
  fi
fi
rm -f deploy/mail.env
docker compose build -q
docker compose up -d
for i in $(seq 1 45); do
  if curl -fsS http://127.0.0.1:7450/healthcheck >/dev/null 2>&1; then echo "server is up"; exit 0; fi
  sleep 2
done
echo "server did not answer"; docker logs --tail 60 splendor-nakama; exit 1
REMOTE
rsh "$TMP/server.sh" bash -s

echo "== nginx site"
cat > "$TMP/nginx.sh" <<REMOTE
set -euo pipefail
# kept as it is once certbot set it up for both addresses (see the home page)
if sudo grep -q "managed by Certbot" /etc/nginx/sites-available/splendor    && sudo grep -q "server_name .*$DOMAIN" /etc/nginx/sites-available/splendor; then
  echo "the splendor site already has https for $DOMAIN; its site file is kept"
  exit 0
fi
sudo cp /opt/splendor/deploy/nginx/splendor.conf /etc/nginx/sites-available/splendor
sudo ln -sf /etc/nginx/sites-available/splendor /etc/nginx/sites-enabled/splendor
sudo nginx -t && sudo systemctl reload nginx
# the copy above is plain http: certbot puts https back on it, with one
# certificate for both addresses (issued again only when an address is new)
sudo certbot --nginx --cert-name $OLD_DOMAIN --expand --reinstall -d $OLD_DOMAIN -d $DOMAIN \\
  --non-interactive --agree-tos --register-unsafely-without-email --redirect
sudo nginx -t && sudo systemctl reload nginx
REMOTE
rsh "$TMP/nginx.sh" bash -s

publish_web
publish_home
echo "== check"
curl -fsS "https://$DOMAIN/healthcheck" && echo " <- https://$DOMAIN/healthcheck"
curl -fsS "https://$OLD_DOMAIN/healthcheck" && echo " <- https://$OLD_DOMAIN/healthcheck (older apps)"
