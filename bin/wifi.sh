#!/usr/bin/env bash
set -euo pipefail

cfg=/persist/config.env
sec=/persist/secrets.env

[[ -s "$cfg" ]] && . "$cfg"
[[ -s "$sec" ]] && . "$sec"

ssid_default="${WIFI_SSID:-}"
psk_default="${WIFI_PASSWORD:-}"
country="${WIFI_COUNTRY:-US}"

networks=()
for idx in 1 2 3 4; do
  ssid_var="WIFI_SSID_${idx}"
  psk_var="WIFI_PASSWORD_${idx}"
  ssid="${!ssid_var:-}"
  psk="${!psk_var:-}"

  alt_ssid_var="WIFI_${idx}_SSID"
  alt_psk_var="WIFI_${idx}_PASSWORD"
  [[ -z "$ssid" ]] && ssid="${!alt_ssid_var:-}"
  [[ -z "$psk" ]] && psk="${!alt_psk_var:-}"

  if [[ "$idx" -eq 1 && -z "$ssid" ]]; then
    ssid="$ssid_default"
    psk="$psk_default"
  fi

  if [[ -n "$ssid" && "$ssid" != "REPLACE_ME" ]]; then
    networks+=("$idx:$ssid:$psk")
  fi
done

if [[ ${#networks[@]} -eq 0 ]]; then
  echo "appliance-wifi: No Wi-Fi SSIDs configured. Skipping Wi-Fi connection."
  exit 0
fi

echo "appliance-wifi: ${#networks[@]} Wi-Fi network(s) configured. Searching for wireless interface..."

wlan_if=""
for i in $(seq 1 15); do
  for p in /sys/class/net/wlan* /sys/class/net/wlp*; do
    if [[ -e "$p" ]]; then
      wlan_if="$(basename "$p")"
      break 2
    fi
  done
  sleep 1
done

if [[ -z "$wlan_if" ]]; then
  echo "appliance-wifi: No wireless interface (wlan*) found after 15s. Exiting cleanly."
  exit 0
fi

echo "appliance-wifi: Found wireless interface '$wlan_if'."

# Unblock wireless radios if rfkill is present
if command -v rfkill >/dev/null 2>&1; then
  rfkill unblock wifi 2>/dev/null || true
  rfkill unblock all 2>/dev/null || true
fi

# Set regulatory domain
if command -v iw >/dev/null 2>&1 && [[ -n "$country" ]]; then
  iw reg set "$country" 2>/dev/null || true
fi

# Bring interface up
ip link set "$wlan_if" up 2>/dev/null || true

# Prepare volatile wpa_supplicant runtime directory
mkdir -p /run/wpa_supplicant
chmod 0700 /run/wpa_supplicant
conf="/run/wpa_supplicant/wpa_supplicant-${wlan_if}.conf"

(
  umask 077
  cat > "$conf" <<EOF
ctrl_interface=/run/wpa_supplicant
ctrl_interface_group=wheel
update_config=0
country=${country}

EOF

  for net in "${networks[@]}"; do
    IFS=':' read -r idx ssid psk <<< "$net"
    priority=$(( 50 - idx * 10 ))
    cat >> "$conf" <<EOF
network={
    ssid="${ssid}"
    scan_ssid=1
    priority=${priority}
EOF
    if [[ -n "$psk" && "$psk" != "REPLACE_ME" ]]; then
      cat >> "$conf" <<EOF
    psk="${psk}"
    key_mgmt=WPA-PSK WPA-PSK-SHA256 SAE
    ieee80211w=1
}

EOF
    else
      cat >> "$conf" <<EOF
    key_mgmt=NONE
}

EOF
    fi
  done
)
chmod 0600 "$conf"

echo "appliance-wifi: Starting wpa_supplicant on '$wlan_if' with ${#networks[@]} network profile(s)..."
exec wpa_supplicant -i "$wlan_if" -c "$conf" -D nl80211,wext
