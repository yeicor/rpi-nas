#!/usr/bin/env bash
set -euo pipefail
. /persist/config.env
. /persist/secrets.env

state=/persist/acme
mkdir -p "$state/lego" "$state/$WEBDAV_DOMAIN"
chmod 0700 "$state" "$state/lego" "$state/$WEBDAV_DOMAIN"

# lego Cloudflare provider requires CLOUDFLARE_DNS_API_TOKEN and CLOUDFLARE_ZONE_API_TOKEN.
# secrets.env exposes the token as CLOUDFLARE_API_TOKEN, so map it here.
export CLOUDFLARE_DNS_API_TOKEN="${CLOUDFLARE_DNS_API_TOKEN:-${CLOUDFLARE_API_TOKEN}}"
export CLOUDFLARE_ZONE_API_TOKEN="${CLOUDFLARE_ZONE_API_TOKEN:-${CLOUDFLARE_API_TOKEN}}"

cert="$state/lego/certificates/${WEBDAV_DOMAIN}.crt"
key="$state/lego/certificates/${WEBDAV_DOMAIN}.key"

# lego will be installed to /usr/local/bin by build.sh
if [[ ! -s "$cert" || ! -s "$key" ]]; then
  lego \
    --path "$state/lego" \
    --email "$ACME_EMAIL" \
    --accept-tos \
    --dns cloudflare \
    --domains "$WEBDAV_DOMAIN" run
else
  lego \
    --path "$state/lego" \
    --email "$ACME_EMAIL" \
    --accept-tos \
    --dns cloudflare \
    --domains "$WEBDAV_DOMAIN" renew --days 30
fi

src="$state/lego/certificates"
out="$state/$WEBDAV_DOMAIN"
tmp="$out/.publish"
mkdir -p "$tmp"

if [[ -s "$src/${WEBDAV_DOMAIN}.issuer.crt" ]]; then
  cat "$src/${WEBDAV_DOMAIN}.crt" "$src/${WEBDAV_DOMAIN}.issuer.crt" > "$tmp/fullchain.pem"
else
  cp "$src/${WEBDAV_DOMAIN}.crt" "$tmp/fullchain.pem"
fi
cp "$src/${WEBDAV_DOMAIN}.key" "$tmp/key.pem"
chmod 0644 "$tmp/fullchain.pem"
chmod 0600 "$tmp/key.pem"
mv -f "$tmp/fullchain.pem" "$out/fullchain.pem"
mv -f "$tmp/key.pem" "$out/key.pem"

systemctl try-restart lighttpd.service || true
