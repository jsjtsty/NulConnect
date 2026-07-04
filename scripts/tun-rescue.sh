#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_LABEL="com.nulstudio.NulConnect.helper"
SOCKET_PATH="/var/run/nulconnect-helper.sock"
HELPER_BIN="/Library/PrivilegedHelperTools/NulConnect/nulconnect-helper"
PLIST_PATH="/Library/LaunchDaemons/com.nulstudio.NulConnect.helper.plist"

usage() {
  cat <<'EOF'
Usage:
  scripts/tun-rescue.sh [--status] [--deep] [--all-utun]

Options:
  --status   Print network/helper status only, do not change anything.
  --deep     Also bring down the current default utun interface if the route
             still points at utun after cleanup.
  --all-utun Bring down every active utun interface after cleanup. This will
             almost certainly disconnect the current tunnel.

Examples:
  bash scripts/tun-rescue.sh
  bash scripts/tun-rescue.sh --deep
  bash scripts/tun-rescue.sh --status
EOF
}

log() {
  printf '[NulConnect][Rescue] %s\n' "$*"
}

status_mode=0
deep_mode=0
all_utun_mode=0

for arg in "$@"; do
  case "$arg" in
    --status)
      status_mode=1
      ;;
    --deep)
      deep_mode=1
      ;;
    --all-utun)
      all_utun_mode=1
      deep_mode=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  exec sudo "$SCRIPT_DIR/$(basename "$0")" "$@"
fi

print_global_dns_state() {
  log "global DNS dynamic store:"
  scutil 2>/dev/null <<'EOF' | sed -n '1,24p' || true
show State:/Network/Global/DNS
quit
EOF
}

remove_global_dns_state() {
  log "removing State:/Network/Global/DNS"
  scutil >/dev/null 2>&1 <<'EOF' || true
remove State:/Network/Global/DNS
quit
EOF
}

print_status() {
  log "default route:"
  route -n get default 2>/dev/null | sed -n '1,8p' || true

  print_global_dns_state

  log "active utun interfaces:"
  ifconfig 2>/dev/null | awk '
    /^utun[0-9]+:/ { iface=$1; gsub(":", "", iface); print iface; next }
    iface != "" && ($1 == "inet" || $1 == "inet6" || $1 == "mtu" || $1 == "status:") {
      print "  " $0
    }
    iface != "" && $1 == "nd6" {
      print "  " $0
      iface=""
    }
  ' || true

  log "launchd helper:"
  launchctl print "system/${APP_LABEL}" 2>/dev/null | sed -n '1,24p' || true

  log "socket:"
  if [[ -S "$SOCKET_PATH" ]]; then
    ls -l "$SOCKET_PATH" || true
  else
    log "socket not present"
  fi

  log "system proxy:"
  networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | while IFS= read -r service; do
    [[ -z "$service" ]] && continue
    service="${service#\* }"
    web="$(networksetup -getwebproxy "$service" 2>/dev/null | awk -F': ' '/Enabled/ {print $2}' || true)"
    socks="$(networksetup -getsocksfirewallproxy "$service" 2>/dev/null | awk -F': ' '/Enabled/ {print $2}' || true)"
    secure="$(networksetup -getsecurewebproxy "$service" 2>/dev/null | awk -F': ' '/Enabled/ {print $2}' || true)"
    if [[ "$web" == "Yes" || "$socks" == "Yes" || "$secure" == "Yes" ]]; then
      log "  $service: web=$web secure=$secure socks=$socks"
    fi
  done
}

send_helper_cleanup() {
  if [[ ! -S "$SOCKET_PATH" ]]; then
    return
  fi

  if command -v nc >/dev/null 2>&1; then
    log "requesting helper cleanup via UNIX socket"
    local response
    response="$(
      printf '{"id":"rescue-1","command":"cleanup"}\n' | nc -w 3 -U "$SOCKET_PATH" 2>/dev/null || true
    )"
    if [[ -n "$response" ]]; then
      log "helper response: ${response//$'\n'/ }"
    fi
    return
  fi

  log "nc not found; skipping direct helper cleanup request"
}

disable_system_proxies() {
  log "disabling system proxies on all network services"
  networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | while IFS= read -r service; do
    [[ -z "$service" ]] && continue
    service="${service#\* }"
    log "  $service"
    networksetup -setwebproxystate "$service" off >/dev/null 2>&1 || true
    networksetup -setsecurewebproxystate "$service" off >/dev/null 2>&1 || true
    networksetup -setsocksfirewallproxystate "$service" off >/dev/null 2>&1 || true
    networksetup -setproxyautodiscovery "$service" off >/dev/null 2>&1 || true
    networksetup -setautoproxystate "$service" off >/dev/null 2>&1 || true
  done
}

stop_helper_processes() {
  log "booting out helper launchd service"
  launchctl bootout "system/${APP_LABEL}" >/dev/null 2>&1 || true

  log "killing stale helper/tun2proxy processes"
  pkill -f "$HELPER_BIN serve" >/dev/null 2>&1 || true
  pkill -f 'nulconnect-helper serve' >/dev/null 2>&1 || true
  pkill -f 'tun2proxy' >/dev/null 2>&1 || true
}

flush_dns() {
  log "flushing DNS caches"
  dscacheutil -flushcache >/dev/null 2>&1 || true
  killall -HUP mDNSResponder >/dev/null 2>&1 || true
}

deep_disconnect_default_utun() {
  local iface=""
  iface="$(route -n get default 2>/dev/null | awk -F': ' '/interface: / {print $2; exit}')"
  if [[ -z "$iface" ]]; then
    log "deep mode: no default interface detected"
    return
  fi
  if [[ "$iface" != utun* ]]; then
    log "deep mode: default interface is $iface, not utun; skipping"
    return
  fi

  log "deep mode: default route still points to $iface; bringing interface down"
  ifconfig "$iface" down >/dev/null 2>&1 || true
}

disconnect_all_utun() {
  log "all-utun mode: bringing down every active utun interface"
  ifconfig 2>/dev/null | awk -F: '/^utun[0-9]+:/ {print $1}' | while IFS= read -r iface; do
    [[ -z "$iface" ]] && continue
    log "  down $iface"
    ifconfig "$iface" down >/dev/null 2>&1 || true
  done
}

kill_common_tunnel_apps() {
  log "stopping common tunnel/proxy background processes"
  pkill -f 'Clash' >/dev/null 2>&1 || true
  pkill -f 'clash' >/dev/null 2>&1 || true
  pkill -f 'mihomo' >/dev/null 2>&1 || true
  pkill -f 'sing-box' >/dev/null 2>&1 || true
  pkill -f 'v2ray' >/dev/null 2>&1 || true
  pkill -f 'nekoray' >/dev/null 2>&1 || true
  pkill -f 'NulConnect' >/dev/null 2>&1 || true
}

reset_dns_to_dhcp() {
  log "resetting per-service DNS to DHCP/default"
  networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | while IFS= read -r service; do
    [[ -z "$service" ]] && continue
    service="${service#\* }"
    log "  $service"
    networksetup -setdnsservers "$service" Empty >/dev/null 2>&1 || true
    networksetup -setsearchdomains "$service" Empty >/dev/null 2>&1 || true
  done
}

cleanup_fake_ip_routes() {
  log "removing common fake-ip routes"
  route -n delete -net 198.18.0.0/15 >/dev/null 2>&1 || true
  route -n delete -net 198.18.0.0/16 >/dev/null 2>&1 || true
  route -n delete -host 198.18.0.1 >/dev/null 2>&1 || true
}

if [[ "$status_mode" -eq 1 ]]; then
  print_status
  exit 0
fi

log "starting rescue"
print_status
send_helper_cleanup
stop_helper_processes
kill_common_tunnel_apps
disable_system_proxies
reset_dns_to_dhcp
remove_global_dns_state
cleanup_fake_ip_routes
flush_dns
if [[ "$deep_mode" -eq 1 ]]; then
  deep_disconnect_default_utun
  flush_dns
fi

if [[ "$all_utun_mode" -eq 1 ]]; then
  disconnect_all_utun
  remove_global_dns_state
  flush_dns
  log "restarting configd"
  killall configd >/dev/null 2>&1 || true
fi

rm -f "$SOCKET_PATH" >/dev/null 2>&1 || true

log "rescue complete"
print_status
