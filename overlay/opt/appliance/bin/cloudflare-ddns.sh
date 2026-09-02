#!/usr/bin/env bash
set -euo pipefail
. /persist/config.env
. /persist/secrets.env

api=https://api.cloudflare.com/client/v4
auth=(-H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json")
get() { curl -fsS --retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 10 --max-time 30 "$@"; }

public_ip=""
for i in $(seq 1 10); do
  public_ip="$(get https://api4.ipify.org 2>/dev/null || true)"
  [[ "$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
  sleep 3
done
[[ "$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "cloudflare-ddns: Could not determine public IP (network offline or DNS delay). Will retry on next timer." >&2; exit 0; }

zone_id=""
suffix="$WEBDAV_DOMAIN"
while [[ -n "$suffix" ]]; do
  z="$(get "${auth[@]}" "$api/zones?name=${suffix}&status=active&per_page=1")"
  zone_id="$(jq -r '.result[0].id // empty' <<<"$z")"
  [[ -n "$zone_id" ]] && break
  [[ "$suffix" == *.* ]] || break
  suffix="${suffix#*.}"
done
[[ -n "$zone_id" ]] || { echo "Cloudflare zone not found" >&2; exit 1; }

records="$(get "${auth[@]}" "$api/zones/$zone_id/dns_records?type=A&name=$WEBDAV_DOMAIN&per_page=100")"
id="$(jq -r '.result[0].id // empty' <<<"$records")"
old="$(jq -r '.result[0].content // empty' <<<"$records")"
[[ "$old" == "$public_ip" && -n "$id" ]] && exit 0

payload="$(jq -cn --arg type A --arg name "$WEBDAV_DOMAIN" --arg content "$public_ip" '{type:$type,name:$name,content:$content,ttl:300,proxied:false}')"
if [[ -n "$id" ]]; then
  get -X PUT "${auth[@]}" "$api/zones/$zone_id/dns_records/$id" --data "$payload" >/dev/null
else
  get -X POST "${auth[@]}" "$api/zones/$zone_id/dns_records" --data "$payload" >/dev/null
fi
