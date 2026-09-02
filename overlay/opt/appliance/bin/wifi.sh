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

# Set regulatory country domain and unblock RFKILL
if command -v raspi-config >/dev/null 2>&1 && [[ -n "$country" ]]; then
  raspi-config nonint do_wifi_country "$country" 2>/dev/null || true
fi

if command -v rfkill >/dev/null 2>&1; then
  rfkill unblock wifi 2>/dev/null || true
  rfkill unblock all 2>/dev/null || true
fi

if command -v iw >/dev/null 2>&1 && [[ -n "$country" ]]; then
  iw reg set "$country" 2>/dev/null || true
fi

# Configure NetworkManager profiles in /run/NetworkManager/system-connections/
if command -v nmcli >/dev/null 2>&1; then
  echo "appliance-wifi: Configuring NetworkManager profiles for ${#networks[@]} Wi-Fi network(s)..."
  mkdir -p /run/NetworkManager/system-connections
  chmod 0700 /run/NetworkManager/system-connections

  for net in "${networks[@]}"; do
    IFS=':' read -r idx ssid psk <<< "$net"
    priority=$(( 50 - idx * 10 ))
    nm_file="/run/NetworkManager/system-connections/wifi-${idx}.nmconnection"
    
    cat > "$nm_file" <<EOF
[connection]
id=${ssid}
uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "12345678-1234-1234-1234-12345678901${idx}")
type=wifi
autoconnect=true
autoconnect-priority=${priority}

[wifi]
mode=infrastructure
ssid=${ssid}

EOF
    if [[ -n "$psk" && "$psk" != "REPLACE_ME" ]]; then
      cat >> "$nm_file" <<EOF
[wifi-security]
key-mgmt=wpa-psk
psk=${psk}

EOF
    fi
    cat >> "$nm_file" <<EOF
[ipv4]
method=auto

[ipv6]
method=auto
EOF
    chmod 0600 "$nm_file"
  done

  nmcli radio wifi on 2>/dev/null || true
  nmcli connection reload 2>/dev/null || true
  nmcli device wifi rescan 2>/dev/null || true
  exit 0
fi

# Fallback: direct wpa_supplicant if NetworkManager is absent
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
  echo "appliance-wifi: No wireless interface found. Exiting cleanly."
  exit 0
fi

ip link set "$wlan_if" up 2>/dev/null || true
mkdir -p /run/wpa_supplicant
chmod 0700 /run/wpa_supplicant
conf="/run/wpa_supplicant/wpa_supplicant-${wlan_if}.conf"

(
  umask 077
  cat > "$conf" <<EOF
ctrl_interface=/run/wpa_supplicant
ctrl_interface_group=netdev
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

exec wpa_supplicant -i "$wlan_if" -c "$conf" -D nl80211,wext
