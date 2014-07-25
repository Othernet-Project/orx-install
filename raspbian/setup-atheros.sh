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
PLUGCFG=/etc/default/ifplugd
DHCPCFG=/etc/dhcp/dhcpd.conf
DHCPDFL=/etc/default/isc-dhcp-server
APDFL=/etc/default/hostapd
APCFG=/etc/hostapd/hostapd.conf
DNSCFG=/etc/dnsspoof.conf
DHCP_UPSTART=/etc/init/udhcpd.conf
DSNIFF_UPSTART=/etc/init/dnsspoof.conf
WIFI_UPSTART=/etc/init/wifiback.conf
DHCP_INIT=/etc/init.d/udhcpd
DSNIFF_INIT=/etc/init.d/dnsspoof
WIFI_INIT=/etc/init.d/wifiback
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
EDIT=${EDITOR:-nano}

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

# fail()
#
# Echo failure and exit with satus code 1
#
fail() {
    echo "FAILED"
    exit 1
}

# checknet(URL)
# 
# Performs wget dry-run on provided URL to see if it works. Echoes 0 if 
# everything is OK, or non-0 otherwise.
#
checknet() {
    $WGET -q --tries=10 --timeout=20 --spider "$1" > /dev/null || echo $NO
    echo $?
}

# warn_and_die(message)
#
# Prints a big fat warning message and exits
#
warn_and_die() {
    echo "FAIL"
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
        echo "Backed up '$1' to '${1}.old'" >> "$LOG"
    fi
}

###############################################################################
# Preflight checks 1
###############################################################################

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

###############################################################################
# Packages
###############################################################################

# Install necessary packages
section "Installing packages"
do_or_fail apt-get update
echo "DONE"
DEBIAN_FRONTEND=noninteractive do_or_pass apt-get -y --force-yes install \
    iw hostapd isc-dhcp-server dsniff
echo "DONE"

###############################################################################
# Preflight checks 2
###############################################################################

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


###############################################################################
# Networking
###############################################################################

cat <<EOF

If you ran this script before, the wireless interface 
may already be configured correctly and you may safely 
ignore this message and answer with 'N'.

Network configuration for $WLAN already exists in 
'$NETCFG'. The correct configuration for $WLAN
should look like this:

    allow-hotplug $WLAN
    iface $WLAN inet static
     address $IPADDR
     netmask $NETMASK

You also want to set eth0 to be 'auto' instead of 
'allow-hotplug'.

EOF
read -p "Would you like to edit network configuration now? [y/N] " -n 1 editnow
echo ""
if [[ "$editnow" == y ]] || [[ "$editnow" == Y ]]; then
    $EDIT "$NETCFG"
fi

cat <<EOF

You probably also want to disable hotplugging for eth0 
in '$PLUGCFG'.

EOF
read -p "Disable hotplugging for eth0? [y/N]" -n 1 editnow
echo ""
if [[ "$editnow" == y ]] || [[ "$editnow" == Y ]]; then
    backup "$PLUGCFG"
    cat "${PLUGCFG}.old" | \
        sed 's|^HOTPLUG_INTERFACES=".*"|HOTPLUG_INTERFACE=""|' > "$PLUGCFG"
fi


section "Checking network configuration"
do_or_fail ifdown $WLAN
sleep 2
do_or_fail ifup $WLAN
sleep 2
# Final check
ifconfig -a | tee -a "$LOG" | grep $WLAN -A 1 | grep "inet addr:$IPADDR" \
    > /dev/null || fail
echo "DONE"

###############################################################################
# DHCP
###############################################################################

section "Configuring DHCP server"
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
fi
backup "$DHCPDFL"
sed 's/^INTERFACES=""/INTERFACES="'$WLAN'"/' "${DHCPDFL}.old" > "${DHCPDFL}"
echo "DONE"

###############################################################################
# hostapd
###############################################################################

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

    # Edit the DAEMON_CONF= line in /etc/defaults/hostapd and point it to our
    # new configuration file.
    backup "$APDFL"
    sed 's|^#\(DAEMON_CONF\)=""|\1="'"$APCFG"'"|' "${APDFL}.old" > "$APDFL"
fi
echo "DONE"

###############################################################################
# DNS
###############################################################################

section "Configuring DNS"
cat > "$DNSCFG" <<EOF
$IPADDR outernet
EOF
cat > "$DSNIFF_UPSTART" <<EOF
description "DNS spoofing server"

start on (started networking)
stop on (stopped networking)
respawn

exec /usr/sbin/dnsspoof -i $WLAN -f $DNSCFG
EOF
cat > "$DSNIFF_INIT" << EOF
#! /bin/sh
### BEGIN INIT INFO
# Provides:          dnsspoof
# Required-Start:    \$network \$remote_fs
# Required-Stop:     \$network \$remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: DNS spoofing
# Description:       Starts dnsspoof from dnsiff package as DNS server
### END INIT INFO

# Author Outernet Inc <branko@outernet.is>

NAME="dnsspoof"
SCRIPTNAME="/etc/init.d/\$NAME"
DESC="DNS spoofing service"
PIDFILE="/var/run/\${NAME}.pid"
DAEMON=/usr/sbin/dnsspoof
DAEMON_ARGS="-i $WLAN -f $DNSCFG"

# Load init settings and LSB functions
. /lib/init/vars.sh
. /lib/lsb/init-functions

do_start() {
    start-stop-daemon --start --quiet --background --make-pid \\
        --pidfile "\$PIDFILE" --exec \$DAEMON -- \$DAEMON_ARGS
    return \$?
}

do_stop() {
    start-stop-daemon --stop --quiet --pidfile "\$PIDFILE"
    return \$?
}

case "\$1" in
    start)
        log_daemon_msg "Starting \$DESC" "\$NAME"
        do_start
        case "\$?" in
            0|1) log_end_msg 0 ;;
            2) log_end_msg 1 ;;
        esac
        ;;
    stop)
        log_daemon_msg "Stopping \$DESC" "\$NAME"
        do_stop
        case "\$?" in
            0|1) log_end_msg 0 ;;
            2) log_end_msg 1 ;;
        esac
        ;;
    restart|force-reload)
        do_stop
        case "\$?" in
            0|1)
                do_start
                case "\$?" in
                    0|1) log_end_msg 0 ;;
                    2) log_end_msg 1 ;;
                esac
                ;;
            2)
                log_end_msg 1
                ;;
        esac
        ;;
    status)
        status_of_proc "\$DAEMON" "\$NAME" && exit 0 || exit \$?
        ;;
    *)
        echo "Usage: \$SCRIPTNAME {start|stop|status|restart|force-reload}" >&2
        exit 3
        ;;
esac

:
EOF
chmod +x "$DSNIFF_INIT"
echo "DONE"

###############################################################################
# Start/configure system services 
###############################################################################

section "Configuring system services"
do_or_fail insserv hostapd
do_or_fail insserv isc-dhcp-server
do_or_fail insserv dnsspoof
echo "DONE"

section "Starting AP"
service hostapd start >> "$LOG" \
    || service hostapd restart >> "$LOG" \
    || fail
echo "DONE"

section "Starting DHCP server"
service isc-dhcp-server start >> "$LOG" \
    || service-isc-dhcp-server restart >> "$LOG" \
    || fail
echo "DONE"

section "Starting DNS spoofing"
service dnsspoof start >> "$LOG" \
    || service dnsspoof restart >> "$LOG" \
    || fail
echo "DONE"

