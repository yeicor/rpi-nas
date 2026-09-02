#!/usr/bin/env bash
set -euo pipefail

. /persist/config.env
user="${ADMIN_USERNAME:-admin}"
root=/run/webdav-data/webdav
cert=/persist/acme/$WEBDAV_DOMAIN
run=/run/lighttpd
conf=$run/lighttpd.conf

install -d -m 0755 -o www-data -g www-data "$run"

# Ensure document root directory exists and is accessible by www-data
if ! mkdir -p "$root" 2>/dev/null; then
  echo "lighttpd: $root not available (data drive disconnected). Falling back to /var/www/html..."
  root=/var/www/html
  mkdir -p "$root"
fi
chown -R "$user:www-data" "$root" 2>/dev/null || true
chmod -R 0775 "$root" 2>/dev/null || true
chmod 0775 "/run/webdav-data" 2>/dev/null || true

# Ensure htpasswd exists
mkdir -p /persist/auth
if [[ ! -s /persist/auth/htpasswd ]]; then
  touch /persist/auth/htpasswd
  chmod 0600 /persist/auth/htpasswd
  chown www-data:www-data /persist/auth/htpasswd
fi

# If Let's Encrypt certificate is not yet generated, create temporary self-signed cert
ssl_cert="$cert/fullchain.pem"
ssl_key="$cert/key.pem"
if [[ ! -s "$ssl_cert" || ! -s "$ssl_key" ]]; then
  echo "lighttpd: ACME certs not ready yet, generating temporary self-signed TLS cert..."
  ssl_cert="$run/selfsigned.pem"
  ssl_key="$run/selfsigned.key"
  if [[ ! -s "$ssl_cert" ]]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$ssl_key" -out "$ssl_cert" \
      -subj "/CN=$WEBDAV_DOMAIN" >/dev/null 2>&1 || true
    chown www-data:www-data "$ssl_cert" "$ssl_key" 2>/dev/null || true
    chmod 0600 "$ssl_cert" "$ssl_key" 2>/dev/null || true
  fi
fi

cat > "$conf" <<EOF2
server.document-root = "$root"
server.upload-dirs = ( "/tmp" )
server.bind = "0.0.0.0"
server.port = 8080
server.pid-file = "$run/lighttpd.pid"
server.username = "www-data"
server.groupname = "www-data"
server.modules = (
  "mod_access",
  "mod_auth",
  "mod_authn_file",
  "mod_webdav",
  "mod_openssl",
  "mod_dirlisting"
)

dir-listing.activate = "enable"
dir-listing.hide-dotfiles = "enable"

webdav.activate = "enable"
webdav.is-readonly = "disable"
webdav.sqlite-db-name = "$run/webdav.db"

auth.backend = "htpasswd"
auth.backend.htpasswd.userfile = "/persist/auth/htpasswd"
auth.require = (
  "/" => (
    "method" => "basic",
    "realm" => "WebDAV",
    "require" => "valid-user"
  )
)

\$SERVER["socket"] == "0.0.0.0:8443" {
  ssl.engine = "enable"
  ssl.pemfile = "$ssl_cert"
  ssl.privkey = "$ssl_key"
  ssl.minimum-version = "TLSv1.2"
}
EOF2

exec /usr/sbin/lighttpd -D -f "$conf"
