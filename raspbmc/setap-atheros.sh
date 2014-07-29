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
DHCPDFL=/etc/default/isc-dhcp-server
APDFL=/etc/default/hostapd
APCFG=/etc/hostapd/hostapd.conf
DNSCFG=/etc/dnsspoof.conf
DHCP_UPSTART=/etc/init/udhcpd.conf
DSNIFF_UPSTART=/etc/init/dnsspoof.conf
WIFI_UPSTART=/etc/init/wifiback.conf
LOGFILE=setap.log

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
    echo "=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*"
    echo "$1"
    echo "=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*"
    exit 1
}

fail_and_die() {
    echo "FAILED"
    exit 1
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

echo -n "Root permissions... "
if [[ $UID != $ROOT ]]; then
    echo "FAILED"
    warn_and_die "Please run this script as root."
fi
echo "OK"

echo -n "Internet connection... "
if [[ $(checknet) == $NO ]]; then
    echo "FAILED (see '$LOGFILE' for details)"
    warn_and_die "Internet connection is required."
fi
echo "OK"

echo -n "Wi-Fi interface with AP mode support... "
if [[ $(checkiw) == $NO ]]; then
    echo "FAILED"
    warn_and_die "Wireless interface does not support AP mode"
fi
echo "OK"

echo -n "Driver support... "
if [[ $(checkdriver) == $NO ]]; then
    echo "FAILED"
    warn_and_die "Please use a device that works with cfg80211 driver."
fi
echo "OK"

env >> "$LOGFILE"

# Install necessary packages
echo -n "Updating package database... "
apt-get update 2>&1 >> "$LOGFILE"
echo "DONE"

echo -n "Installing dependencies... "
DEBIAN_FRONTEND=noninteractive apt-get -y --force-yes install hostapd \
    isc-dhcp-server dsniff >> "$LOGFILE" \
    || echo "IGNORING ERROR (see '$LOGFILE' for details)"
echo "DONE"

# TODO: First check if network-manager is enabled, and do something else if 
# it's not. Don't just assume it's up and running.

# Configure Wi-Fi interface, release network-manager control over it
if ! [[ $(nmcli dev | grep wlan0 | grep unmanaged) ]]; then
    backup "$NETCFG"
    # Disable network-manager control over wlan0
    grep "iface $WLAN" "$NETCFG" || cat >> "$NETCFG" <<EOF
auto $WLAN
iface $WLAN inet static
 address $IPADDR
 netmask $NETMASK
EOF
fi

# Restart network-related services to and check network-manager devices
echo -n "Restarting network manager... "
service network-manager stop >> "$LOGFILE" || true 
service network-manager start >> "$LOGFILE" || fail_and_die
echo "DONE"
sleep 1

# Check again and bail if we couldn't get network-manager to behave
nmcli dev | grep $WLAN | grep unmanaged > /dev/null || \
    warn_and_die "Failed to configure Wi-Fi interface '$WLAN'."

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

echo -n "Restarting Wi-Fi interface... "
service wifiback start >> "$LOGFILE" || fail_and_die
sleep 2
echo "DONE"

# Final check
ifconfig -a | grep $WLAN -A 1 | grep "inet addr:$IPADDR" > /dev/null || \
    warn_and_die "Network configuration failed."

# Configure udhcpd if it's not configured for wlan interface
if ! [[ $(grep "interface $WLAN" "$DHCPCFG") ]]; then
    backup "$DHCPCFG"
    cat > "$DHCPCFG" <<EOF
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
fi

backup "$DHCPDFL"
sed 's/^INTERFACES=""/INTERFACES="'$WLAN'"/' "${DHCPDFL}.old" > "${DHCPDFL}"

# Configure hostapd if not confiugred for wlan interface
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

    # Edit the DAEMON_CONF= line in /etc/defaults/hostapd and point it to our
    # new configuration file.
    backup "$APDFL"
    sed 's|^#\(DAEMON_CONF\)=""|\1="'"$APCFG"'"|' "${APDFL}.old" > "$APDFL"
fi

# Configure DNS spoofing
cat > "$DNSCFG" <<EOF
$IPADDR outernet
EOF
cat > "$DSNIFF_UPSTART" <<EOF
description "DNS spoofing server"

start on wifi-done
stop on shutdown
respawn

exec /usr/sbin/dnsspoof -i $WLAN -f $DNSCFG
EOF

echo -n "Starting AP... "
service hostapd start >> "$LOGFILE" \
    || service hostapd restart >> "$LOGFILE" \
    || fail_and_die
echo "OK"

sleep 4  # Wait for hostapd to set up a new interface

echo -n "Starting DHCP server... "
service isc-dhcp-server start >> "$LOGFILE" \
    || service-isc-dhcp-server restart >> "$LOGFILE" \
    || fail_and_die
echo "OK"

echo -n "Starting DNS spoofing... "
service dnsspoof start >> "$LOGFILE" \
    || service dnsspoof restart >> "$LOGFILE" \
    || fail_and_die
echo "OK"

echo -n "Enabling services on boot... "
update-rc.d hostapd enable >> "$LOGFILE" || fail_and_die
update-rc.d isc-dhcp-server enable >> "$LOGFILE" || fail_and_die
echo "OK"
