#!/usr/bin/env bash
set -euo pipefail

. /persist/config.env
user="${ADMIN_USERNAME:-admin}"
root=/run/webdav-data/webdav
cert=/persist/acme/$WEBDAV_DOMAIN
run=/run/lighttpd
conf=$run/lighttpd.conf

[[ -d "$root" ]] || exit 1
[[ -s "$cert/fullchain.pem" && -s "$cert/key.pem" ]] || exit 1
install -d -m 0750 "$run"

cat > "$conf" <<EOF2
server.document-root = "$root"
server.upload-dirs = ( "/tmp" )
server.bind = "127.0.0.1"
server.port = 8080
server.pid-file = "$run/lighttpd.pid"
# WebDAV I/O uses the preconfigured Unix administrator account, so kernel DAC/ACLs
# for that account are the actual filesystem authorization boundary.
server.username = "$user"
server.groupname = "shadow"
server.modules = (
  "mod_access",
  "mod_auth",
  "mod_authn_pam",
  "mod_webdav",
  "mod_openssl"
)

webdav.activate = "enable"
webdav.is-readonly = "disable"
auth.backend = "pam"
auth.backend.pam.opts = ( "service" => "lighttpd" )
auth.require = (
  "/" => (
    "method" => "basic",
    "realm" => "WebDAV",
    "require" => "valid-user"
  )
)

\$SERVER["socket"] == "0.0.0.0:443" {
  ssl.engine = "enable"
  ssl.pemfile = "$cert/fullchain.pem"
  ssl.privkey = "$cert/key.pem"
  ssl.minimum-version = "TLSv1.2"
}
EOF2

exec /run/current-system/sw/bin/lighttpd -D -f "$conf"
