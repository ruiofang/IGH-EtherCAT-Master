#!/bin/sh

# Resolve the current Linux interface name from a persistent Ethernet MAC address.
set -eu

usage() {
    echo "Usage: $0 <mac-address> <ethercat-config> [--apply]" >&2
    exit 2
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage

expected_mac=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
config_file=$2
apply=false
[ "${3:-}" = "--apply" ] && apply=true
[ -z "${3:-}" ] || [ "$apply" = true ] || usage

interface=""
for net_path in /sys/class/net/*; do
    [ -r "$net_path/address" ] || continue
    case "$(basename "$net_path")" in
        ecdbgm*) continue ;;
    esac
    current_mac=$(tr '[:upper:]' '[:lower:]' < "$net_path/address")
    if [ "$current_mac" = "$expected_mac" ]; then
        interface=$(basename "$net_path")
        break
    fi
done

[ -n "$interface" ] || exit 1

if [ "$apply" = true ]; then
    tmp_file="${config_file}.tmp.$$"
    trap 'rm -f "$tmp_file"' EXIT HUP INT TERM
    awk -v interface="$interface" '
        /^MASTER0_DEVICE=/ { print "MASTER0_DEVICE=\"" interface "\""; next }
        { print }
    ' "$config_file" > "$tmp_file"
    mv "$tmp_file" "$config_file"
    trap - EXIT HUP INT TERM
    ip link set dev "$interface" up
fi

printf '%s\n' "$interface"
