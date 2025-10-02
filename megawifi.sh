#!/usr/bin/env bash
# megawifi.sh
# Usage:
#   sudo ./hotspot-mitm.sh SSID PASSWORD
#   sudo ./hotspot-mitm.sh --clear
#
# настраивайте и используйте аккуратно. Только для легального тестирования.

set -euo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

STATE_DIR="/var/run/myhotspot"
mkdir -p "$STATE_DIR"
HOSTAPD_CONF="$STATE_DIR/hostapd.conf"
DNSMASQ_CONF="$STATE_DIR/dnsmasq.conf"
PIDS_FILE="$STATE_DIR/pids"
OUT_IF_FILE="$STATE_DIR/out_if"
SAVED_AUTOCONN="$STATE_DIR/autoconnect_before.txt"
MITM_TOKEN_FILE="$STATE_DIR/mitm_token"

die(){ echo "ERROR: $*"; exit 1; }
info(){ echo "==> $*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Need root: re-running with sudo..."
  exec sudo bash "$0" "$@"
fi

if [ $# -eq 0 ]; then
  cat <<EOF
Usage:
  $0 SSID PASSWORD      # стартовать hotspot + mitm
  $0 --clear            # остановить и откатить изменения
EOF
  exit 1
fi

if [ "$1" = "--clear" ]; then
  action="clear"
else
  action="start"
  SSID="$1"
  PASSWORD="${2:-}"
  if [ -z "$PASSWORD" ]; then die "Нужны SSID и PASSWORD"; fi
fi

find_wlan() {
  local w
  w=$(iw dev | awk '/Interface/ {print $2; exit}' || true)
  if [ -z "$w" ]; then
    die "Не найден Wi-Fi интерфейс (iw dev не показал Interface)."
  fi
  echo "$w"
}

find_out_if() {
  local dev
  dev=$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}' || true)
  echo "${dev:-}"
}

install_if_missing() {
  local pkgs=("$@")
  local to_install=()
  for p in "${pkgs[@]}"; do
    if ! pacman -Qi "$p" &>/dev/null; then
      to_install+=("$p")
    fi
  done
  if [ "${#to_install[@]}" -gt 0 ]; then
    info "Устанавливаю пакеты: ${to_install[*]} (pacman)."
    pacman -Syu --noconfirm "${to_install[@]}"
  fi
}

start_hotspot() {
  local wlan
  wlan=$(find_wlan)
  info "Использую Wi-Fi интерфейс: $wlan"

  info "Сохраняю autoconnect состояний (wifi-профилей) в $SAVED_AUTOCONN"
  nmcli -t -f UUID,TYPE connection show | awk -F: '$2=="802-11-wireless"{print $1}' | while read -r uuid; do
    nmcli -g 802-11-wireless.ssid connection show "$uuid" >/dev/null 2>&1 || true
    autocon=$(nmcli -g connection.autoconnect connection show "$uuid" 2>/dev/null || echo "no")
    echo "$uuid:$autocon" >> "$SAVED_AUTOCONN"
    nmcli connection modify "$uuid" connection.autoconnect no >/dev/null 2>&1 || true
  done || true

  info "Отключаю $wlan от NetworkManager, чтобы освободить управление"
  nmcli device disconnect "$wlan" >/dev/null 2>&1 || true

  install_if_missing hostapd dnsmasq mitmproxy

  info "Настраиваю IP на $wlan: 10.0.0.1/24"
  ip link set "$wlan" down || true
  ip addr flush dev "$wlan" || true
  ip addr add 10.0.0.1/24 dev "$wlan"
  ip link set "$wlan" up

  cat > "$HOSTAPD_CONF" <<EOF
interface=$wlan
driver=nl80211
ssid=$SSID
hw_mode=g
channel=6
wpa=2
wpa_passphrase=$PASSWORD
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
  info "Создал hostapd конфиг: $HOSTAPD_CONF"

  cat > "$DNSMASQ_CONF" <<EOF
interface=$wlan
bind-interfaces
listen-address=10.0.0.1
no-resolv
server=8.8.8.8
dhcp-range=10.0.0.10,10.0.0.200,12h
log-facility=$STATE_DIR/dnsmasq.log
EOF
  info "Создал dnsmasq конфиг: $DNSMASQ_CONF"

  
  info "Запускаю hostapd..."
  hostapd "$HOSTAPD_CONF" >"$STATE_DIR/hostapd.log" 2>&1 &
  local hostapd_pid=$!
  sleep 0.5
  
  if ! kill -0 "$hostapd_pid" 2>/dev/null; then
    echo "hostapd не запустился — посмотрим лог:"
    tail -n 100 "$STATE_DIR/hostapd.log" || true
    die "hostapd failed"
  fi
  echo "hostapd PID $hostapd_pid" >> "$PIDS_FILE"
  info "hostapd запущен (PID $hostapd_pid)."

  
  info "Запускаю dnsmasq..."
  dnsmasq --conf-file="$DNSMASQ_CONF" --no-daemon >"$STATE_DIR/dnsmasq.log" 2>&1 &
  local dns_pid=$!
  sleep 0.5
  if ! kill -0 "$dns_pid" 2>/dev/null; then
    echo "dnsmasq не запустился — лог:"
    tail -n 200 "$STATE_DIR/dnsmasq.log" || true
    die "dnsmasq failed"
  fi
  echo "dnsmasq PID $dns_pid" >> "$PIDS_FILE"
  info "dnsmasq запущен (PID $dns_pid)."

  
  local out_if
  out_if=$(find_out_if)
  if [ -n "$out_if" ]; then
    info "Найден внешний интерфейс для NAT: $out_if. Включаю форвард и маскарадинг."
    echo "$out_if" > "$OUT_IF_FILE"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    iptables -t nat -A POSTROUTING -o "$out_if" -j MASQUERADE
    iptables -A FORWARD -i "$out_if" -o "$wlan" -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i "$wlan" -o "$out_if" -j ACCEPT
  else
    info "Внешний интерфейс для NAT не найден — клиенты не получат доступ в интернет."
    : > "$OUT_IF_FILE"
  fi

  
  info "Запускаю mitmweb в transparent режиме (порт 8080), web GUI на 8081..."
  mitmweb --mode transparent --listen-port 8080 --web-host 0.0.0.0 --web-port 8081 >"$STATE_DIR/mitmweb.log" 2>&1 &
  local mitm_pid=$!
  sleep 1
  if ! kill -0 "$mitm_pid" 2>/dev/null; then
    echo "mitmweb не запустился — лог:"
    tail -n 200 "$STATE_DIR/mitmweb.log" || true
    die "mitmweb failed"
  fi
  echo "mitmweb PID $mitm_pid" >> "$PIDS_FILE"
  info "mitmweb запущен (PID $mitm_pid)."

  info "Добавляю iptables правила перенаправления 80/443 -> 8080"
  iptables -t nat -A PREROUTING -i "$wlan" -p tcp --dport 80  -m comment --comment "myhotspot" -j REDIRECT --to-port 8080
  iptables -t nat -A PREROUTING -i "$wlan" -p tcp --dport 443 -m comment --comment "myhotspot" -j REDIRECT --to-port 8080

  grep -oE 'http://[^ ]+:[0-9]+/\\?token=[0-9a-f]+' "$STATE_DIR/mitmweb.log" 2>/dev/null | head -n1 > "$MITM_TOKEN_FILE" || true

  info "Hotspot '$SSID' поднят. DHCP: 10.0.0.10-10.0.0.200. IP точки: 10.0.0.1"
  info "Mitmweb GUI: http://<this-host-ip>:8081 (см. $STATE_DIR/mitmweb.log для токена)"
  info "CA: ~/.mitmproxy/mitmproxy-ca-cert.pem — раздайте клиентам, например: cd ~/.mitmproxy && python3 -m http.server 8000"
  info "Сохранённое состояние в $STATE_DIR. Для остановки: $0 --clear"
}

clear_all() {
  info "Отключаю и удаляю все сервисы и правила, созданные скриптом..."

  
  if [ -f "$PIDS_FILE" ]; then
    while read -r line; do
      pid=$(echo "$line" | awk '{print $NF}')
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        info "Killing PID $pid"
        kill "$pid" || true
      fi
    done < "$PIDS_FILE" || true
    rm -f "$PIDS_FILE"
  fi

  info "Удаляю REDIRECT правила (comment 'myhotspot') из nat PREROUTING..."
  while iptables -t nat -S PREROUTING | grep -q -- "-m comment --comment \"myhotspot\""; do
    rule=$(iptables -t nat -S PREROUTING | grep -- "-m comment --comment \"myhotspot\"" | head -n1)
    del_rule="${rule/-A/-D}"
    eval "iptables -t nat ${del_rule#-D }" || break
  done || true

  if [ -f "$OUT_IF_FILE" ]; then
    out_if=$(cat "$OUT_IF_FILE")
    if [ -n "$out_if" ]; then
      info "Удаляю MASQUERADE и FORWARD для $out_if"
      iptables -t nat -D POSTROUTING -o "$out_if" -j MASQUERADE 2>/dev/null || true
      iptables -D FORWARD -i "$out_if" -o "$(find_wlan)" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
      iptables -D FORWARD -i "$(find_wlan)" -o "$out_if" -j ACCEPT 2>/dev/null || true
    fi
    rm -f "$OUT_IF_FILE"
  fi

  sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true

  pkill hostapd || true
  pkill dnsmasq || true
  pkill mitmweb || true
  pkill mitmproxy || true

  rm -f "$HOSTAPD_CONF" "$DNSMASQ_CONF" "$STATE_DIR/hostapd.log" "$STATE_DIR/dnsmasq.log" "$STATE_DIR/mitmweb.log" "$MITM_TOKEN_FILE" || true

  if [ -f "$SAVED_AUTOCONN" ]; then
    info "Восстанавливаю autoconnect для сохранённых профилей..."
    while IFS=: read -r uuid autocon; do
      if [ "$autocon" = "yes" ]; then
        nmcli connection modify "$uuid" connection.autoconnect yes || true
      fi
    done < "$SAVED_AUTOCONN" || true
    rm -f "$SAVED_AUTOCONN"
  fi

  local wlan
  wlan=$(find_wlan)
  ip addr flush dev "$wlan" || true
  info "Попытка вернуть $wlan под управление NetworkManager..."
  nmcli device connect "$wlan" >/dev/null 2>&1 || true

  rmdir "$STATE_DIR" 2>/dev/null || true

  info "Очистка завершена."
}

if [ "$action" = "start" ]; then
  start_hotspot
else
  clear_all
fi

exit 0

