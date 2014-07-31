#!/usr/bin/env bash
#
# setap.sh: Set up access point
# Copyright (C) 2014, Outernet Inc.
# Some rights reserved.
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
# details.
#
# You should have received a copy of the GNU General Public License along with
# this program.  If not, see <http://www.gnu.org/licenses/>.
#

set -e

NO=1
YES=0
ROOT=0

# Files and locations
NETCFG=/etc/network/interfaces
DHCPCFG=/etc/dhcp/dhcpd.conf
APDFL=/etc/default/hostapd
APCFG=/etc/hostapd/hostapd.conf
AP_UPSTART=/etc/init/hostapd.conf
DNSCFG=/etc/dnsspoof.conf
DHCP_INIT=/etc/init.d/isc-dhcp-server
DHCP_UPSTART=/etc/init/isc-dhcp-server.conf
DSNIFF_UPSTART=/etc/init/dnsspoof.conf
WIFI_UPSTART=/etc/init/wifiback.conf
LOG=setap.log

# Network settings
WLAN=wlan0
MODE=g
CHANNEL=6
SSID=outernet
PSK=outernet
HOSTAPDRV=nl80211
SUBNET=10.0.0
IPADDR=${SUBNET}.1
DNSADDR=$IPADDR  # Pi will be the DNS server as well
NETMASK=255.255.255.0
DHCP_START=10.0.0.2
DHCP_END=10.0.0.254

# Command aliases
WGET="wget"

# warn_and_die(message)
#
# Prints a big fat warning message and exits
#
warn_and_die() {
    echo "FAILED"
    echo "=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*"
    echo "$1"
    echo "=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*"
    exit 1
}

# section(message)
#
# Echo section start message without newline.
#
section() {
    echo -n "${1}... "
}

# fail()
# 
# Echoes "FAIL" and exits
#
fail() {
    echo "FAILED (see '$LOG' for details)"
    exit 1
}

# do_or_fail()
#
# Runs a command and fails if commands returns with a non-0 status
#
do_or_fail() {
    "$@" >> $LOG 2>&1 || fail
}

# do_or_pass()
# 
# Runs a command and ignores non-0 return
#
do_or_pass() {
    "$@" >> $LOG 2>&1 || true
}

# checknet(URL)
# 
# Performs wget dry-run on provided URL to see if it works. Echoes 0 if 
# everything is OK, or non-0 otherwise.
#
checknet() {
    $WGET -q --tries=10 --timeout=20 --spider "$1" > /dev/null || echo 1
    echo $?
}

# checkiw()
# 
# Checks whether wireless interface supports "AP" mode. Returns $NO or $YES.
#
checkiw() {
    iw list | grep -A 8 "Supported interface modes:" | grep "* AP" \
        > /dev/null && echo $YES || echo $NO
}

# checkdriver()
#
# Check if interface uses supported driver. Returns $NO or $YES.
#
checkdriver() {
    lsmod | grep cfg80211 | grep ath > /dev/null && echo $YES || echo $NO
}

# backup()
#
# Back up a file by copying it to a path with '.old' suffix and echo about it
#
backup() {
    if [[ -f "$1" ]] && ! [[ -f "${1}.old" ]]; then
        cp "$1" "${1}.old"
        echo "Backed up '$1' to '${1}.old'"
    fi
}

section "Root permissions"
if [[ $UID != $ROOT ]]; then
    warn_and_die "Please run this script as root."
fi
echo "OK"

section "Internet connection"
if [[ $(checknet) == $NO ]]; then
    warn_and_die "Internet connection is required."
fi
echo "OK"

section "Wi-Fi interface with AP mode support"
if [[ $(checkiw) == $NO ]]; then
    warn_and_die "Wireless interface does not support AP mode"
fi
echo "OK"

section "Driver support... "
if [[ $(checkdriver) == $NO ]]; then
    warn_and_die "Please use a device that works with cfg80211 driver."
fi
echo "OK"

env >> "$LOG"

# Install necessary packages
section "Updating package database"
do_or_fail apt-get update
echo "DONE"

section "Installing packages"
DEBIAN_FRONTEND=noninteractive do_or_pass apt-get -y --force-yes install \
    hostapd isc-dhcp-server dsniff
echo "DONE"

# TODO: First check if network-manager is enabled, and do something else if 
# it's not. Don't just assume it's up and running.

section "Overriding network manager control over wireless"
if ! [[ $(nmcli dev | grep wlan0 | grep unmanaged) ]]; then
    backup "$NETCFG"
    # Disable network-manager control over wlan0
    grep "iface $WLAN" "$NETCFG" || cat >> "$NETCFG" <<EOF
allow-hotplug $WLAN
iface $WLAN inet static
 address $IPADDR
 netmask $NETMASK
EOF
fi
echo "DONE"

section "Restarting network manager"
do_or_pass service network-manager stop >> "$LOG"
do_or_fail service network-manager start >> "$LOG"
sleep 1
echo "DONE"

section "Checking network configuration"
nmcli dev | grep $WLAN | grep unmanaged > /dev/null || \
    warn_and_die "Failed to configure Wi-Fi interface '$WLAN'."
echo "OK"

section "Configuring wireless interface"
# Add Upstart job that overrides custom RaspBMC settings
cat > "$WIFI_UPSTART" <<EOF
description "Wifi reconfiguration"

start on custom-network-done

script
ifdown $WLAN || true
ifup $WLAN
sleep 2
end script

post-start exec initctl emit --no-wait wifi-done
EOF
echo "DONE"

section "Restarting Wi-Fi interface"
service wifiback start >> "$LOG" || fail
sleep 2
echo "DONE"

section "Checking wireless settings"
ifconfig | tee -a "$LOG" | grep $WLAN -A 1 | \
    grep "inet addr:$IPADDR" > /dev/null || fail
echo "OK"

section "Configuring DHCP"
if ! [[ $(grep "interface $WLAN" "$DHCPCFG") ]]; then
    backup "$DHCPCFG"
    cat > "$DHCPCFG" <<EOF
authoritative;
default-lease-time 600;
max-lease-time 7200;
option subnet-mask $NETMASK;
option broadcast-address ${SUBNET}.255;
option routers $IPADDR;
option domain-name-servers $IPADDR;
option domain-name "outernet";

subnet ${SUBNET}.0 netmask $NETMASK {
    range ${SUBNET}.2 ${SUBNET}.254;
}
EOF
    cat > "$DHCP_UPSTART" <<EOF
description "DHCP server"

start on wifi-done
stop on shutdown
respawn

post-stop exec sleep 5

exec /usr/sbin/dhcpd -f -4 -q $WLAN
EOF
    chmod -x "$DHCP_INIT"
fi
echo "DONE"

# Configure hostapd if not configured for wlan interface
section "Configuring hotspot"
touch "$APCFG"
if ! [[ $(grep "interface=$WLAN" "$APCFG") ]]; then
    if [[ -f "$APCFG" ]]; then
        backup "$APCFG"
    fi
    cat > "$APCFG" <<EOF
interface=$WLAN
driver=nl80211
ssid=$SSID
hw_mode=$MODE
channel=$CHANNEL
wmm_enabled=1
auth_algs=1
macaddr_acl=0
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$PSK
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF
    
    cat > "$AP_UPSTART" <<EOF
description "hostapd service"

start on wifi-done
stop on shutdown

exec /usr/sbin/hostapd "$APCFG"
EOF
fi
echo "DONE"

section "Configuring DNS"
cat > "$DNSCFG" <<EOF
$IPADDR *
EOF
cat > "$DSNIFF_UPSTART" <<EOF
description "DNS spoofing server"

start on wifi-done
stop on shutdown
respawn

post-stop exec sleep 5

exec /usr/sbin/dnsspoof -i $WLAN -f $DNSCFG
EOF
echo "DONE"

section "Starting AP"
service hostapd start >> "$LOG" 2>&1 \
    || service hostapd restart >> "$LOG" 2>&1 \
    || fail
echo "DONE"

section "Starting DHCP server"
service isc-dhcp-server start >> "$LOG" 2>&1 \
    || service isc-dhcp-server restart >> "$LOG" 2>&1 \
    || fail
echo "DONE"

section "Starting DNS spoofing"
service dnsspoof start >> "$LOG" 2>&1 \
    || service dnsspoof restart >> "$LOG" 2>&1 \
    || fail
echo "DONE"
