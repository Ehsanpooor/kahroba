#!/usr/bin/env bash
# Put the Splendor game server, its download page, the Android app and the
# Zood Gamers home page on the VPS that also runs Veynoria. Splendor has its
# own containers, network, database volume, port (127.0.0.1:7450) and nginx
# site (splendor.aizood.ir, and splendor.mspink.ir for the apps installed
# before 0.9.3); the home page has its own site (aizood.ir). Veynoria
# (veinora.mspink.ir, 127.0.0.1:7350) and the other sites are never touched.
#
#   ./deploy/deploy.sh                 # server + page + apk + admin + home page
#   ./deploy/deploy.sh apk             # only the page and the apk
#   ./deploy/deploy.sh admin           # only the admin page's files
#   ./deploy/deploy.sh home            # only the aizood.ir home page
#
# The private admin page (deploy/admin) is served at /admin/ behind a
# password. Its secrets are made on the server at the first deploy and kept in
# /opt/splendor/.env (NAKAMA_HTTP_KEY, ADMIN_PASSWORD); nothing secret is in
# the repo. Read the password with  grep ADMIN_PASSWORD /opt/splendor/.env
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

# install_site <site> <conf file on the server> <certbot arguments...>
#
# certbot manages the live site files (it added their https server blocks),
# so a site file is replaced only when the repo's copy changed since it was
# last installed (its hash is kept beside it). Then: the live file is backed
# up, the new one copied in and certbot asked to put https back on it. If
# certbot (tried 3 times: the VPS's DNS does not always reach Let's Encrypt)
# or nginx -t fails, the backup goes back, nginx is reloaded with it, and the
# deploy stops with an error. nginx is not reloaded before certbot has run,
# so the live site keeps https throughout.
install_site() {
  local site="$1" conf="$2"; shift 2
  {
    printf 'SITE=%q\nCONF=%q\nCERTBOT_ARGS=(' "$site" "$conf"
    printf ' %q' "$@"
    printf ' )\n'
    cat <<'REMOTE'
set -euo pipefail
LIVE=/etc/nginx/sites-available/$SITE
HASH=/etc/nginx/sites-available/.$SITE.conf.sha256
NEW_HASH=$(sha256sum "$CONF" | cut -d' ' -f1)
OLD_HASH=$(sudo cat "$HASH" 2>/dev/null || true)
if sudo test -f "$LIVE" && [ "$OLD_HASH" = "$NEW_HASH" ]; then
  echo "the $SITE site is unchanged; its live file is kept"
  exit 0
fi
BACKUP=""
if sudo test -f "$LIVE"; then
  BACKUP=/etc/nginx/sites-available/.$SITE.backup-$(date +%Y%m%d-%H%M%S)
  sudo cp -p "$LIVE" "$BACKUP"
  echo "backed up the live $SITE site to $BACKUP"
fi
restore() {
  echo "!! $1" >&2
  if [ -n "$BACKUP" ]; then
    sudo cp -p "$BACKUP" "$LIVE"
  else
    sudo rm -f "$LIVE" "/etc/nginx/sites-enabled/$SITE"
  fi
  if sudo nginx -t; then sudo systemctl reload nginx; fi
  echo "!! the previous $SITE site is back in place; the new one was NOT installed" >&2
  exit 1
}
sudo cp "$CONF" "$LIVE"
sudo ln -sf "$LIVE" "/etc/nginx/sites-enabled/$SITE"
sudo nginx -t || restore "nginx -t refused the new $SITE site"
# the copy is plain http: certbot puts https (and the redirect) back on it
done_ok=0
for n in 1 2 3; do
  if sudo certbot --nginx "${CERTBOT_ARGS[@]}" \
       --non-interactive --agree-tos --register-unsafely-without-email --redirect; then
    done_ok=1
    break
  fi
  echo "(certbot failed, attempt $n of 3)"
  if [ "$n" -lt 3 ]; then sleep 30; fi
done
[ "$done_ok" = 1 ] || restore "certbot failed 3 times for the $SITE site"
sudo nginx -t || restore "nginx -t failed after certbot on the $SITE site"
sudo systemctl reload nginx
echo "$NEW_HASH" | sudo tee "$HASH" >/dev/null
# keep the three latest backups
ls -1t /etc/nginx/sites-available/.$SITE.backup-* 2>/dev/null | tail -n +4 | xargs -r sudo rm -f
echo "the $SITE site is updated, with https"
REMOTE
  } > "$TMP/site-$site.sh"
  rsh "$TMP/site-$site.sh" bash -s
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
  install_site aizood /tmp/aizood.conf --cert-name "$HOME_DOMAIN" --reinstall -d "$HOME_DOMAIN"
  curl -fsS -o /dev/null "https://$HOME_DOMAIN/" && echo " <- https://$HOME_DOMAIN/"
}

publish_admin() {
  echo "== the admin page (https://$DOMAIN/admin/)"
  rsh - "sudo mkdir -p /var/www/splendor-admin && sudo chown -R \$USER /var/www/splendor-admin"
  tar -C "$ROOT/deploy/admin" -cf "$TMP/admin.tar" .
  rsh "$TMP/admin.tar" "tar -C /var/www/splendor-admin -xf -"
}

if [ "${1:-}" = "apk" ]; then publish_web; exit 0; fi
if [ "${1:-}" = "admin" ]; then publish_admin; exit 0; fi
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
rnd() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32; }
if [ ! -f .env ]; then
  sed -e "s/@POSTGRES@/$(rnd)/" -e "s/@SESSION@/$(rnd)/" -e "s/@REFRESH@/$(rnd)/" \
      -e "s/@CONSOLE@/$(rnd)/" -e "s/@HTTPKEY@/$(rnd)/" -e "s/@ADMINPW@/$(rnd)/" \
      deploy/env.template > .env
  chmod 600 .env
  echo "created .env"
  echo "the admin page's password is in /opt/splendor/.env (grep ADMIN_PASSWORD /opt/splendor/.env)"
fi
# the runtime http key and the admin page's password (0.9.4): made once
if ! grep -q '^NAKAMA_HTTP_KEY=.' .env; then
  sed -i '/^NAKAMA_HTTP_KEY=/d' .env
  echo "NAKAMA_HTTP_KEY=$(rnd)" >> .env
  echo "added a runtime http key to .env"
fi
if ! grep -q '^ADMIN_PASSWORD=.' .env; then
  sed -i '/^ADMIN_PASSWORD=/d' .env
  echo "ADMIN_PASSWORD=$(rnd)" >> .env
  echo "made the admin page's password: it is in /opt/splendor/.env (grep ADMIN_PASSWORD /opt/splendor/.env)"
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

echo "== the admin page's key and password for nginx"
cat > "$TMP/admin-secrets.sh" <<'REMOTE'
set -euo pipefail
# from the server's .env: the runtime http key goes into an nginx include
# (the site adds it to /admin/api/ calls), the password into an htpasswd file
val() { grep "^$1=" /opt/splendor/.env | tail -n 1 | cut -d= -f2-; }
KEY=$(val NAKAMA_HTTP_KEY)
PW=$(val ADMIN_PASSWORD)
if [ -z "$KEY" ] || [ -z "$PW" ]; then
  echo "NAKAMA_HTTP_KEY or ADMIN_PASSWORD is missing in /opt/splendor/.env" >&2
  exit 1
fi
put() {  # put <file>: stdin into a root:www-data 640 file, replaced in one step
  sudo tee "$1.new" >/dev/null
  sudo chown root:www-data "$1.new"
  sudo chmod 640 "$1.new"
  sudo mv "$1.new" "$1"
}
printf 'set $splendor_admin_key "%s";\n' "$KEY" | put /etc/nginx/splendor-admin-key.conf
printf 'admin:%s\n' "$(printf '%s' "$PW" | openssl passwd -apr1 -stdin)" | put /etc/nginx/splendor-admin.htpasswd
echo "nginx has the admin key and password"
REMOTE
rsh "$TMP/admin-secrets.sh" bash -s

publish_admin

echo "== nginx site"
# one certificate for both addresses (issued again only when an address is new)
install_site splendor /opt/splendor/deploy/nginx/splendor.conf \
  --cert-name "$OLD_DOMAIN" --expand --reinstall -d "$OLD_DOMAIN" -d "$DOMAIN"

publish_web
publish_home
echo "== check"
curl -fsS "https://$DOMAIN/healthcheck" && echo " <- https://$DOMAIN/healthcheck"
curl -fsS "https://$OLD_DOMAIN/healthcheck" && echo " <- https://$OLD_DOMAIN/healthcheck (older apps)"
code=$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/admin/" || true)
echo "admin page: https://$DOMAIN/admin/ (answers $code without the password; 401 is right)"
echo "  user admin; the password is on the server: grep ADMIN_PASSWORD /opt/splendor/.env"
