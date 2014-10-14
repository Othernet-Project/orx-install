#!/usr/bin/env bash
#
# setap-atheors.sh: Set up access point using atheros Wi-Fi dongle
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
OK=$YES
ROOT=0

# Network settings
WLAN=wlan0
MODE=g
CHANNEL=6
DOMAIN=outernet
SSID=outernet
PSK=outernet
HOSTAPDRV=nl80211
SUBNET=10.0.0
IPADDR=${SUBNET}.1
DNSADDR=$IPADDR  # Pi will be the DNS server as well
NETMASK=255.255.255.0
NETMASKB=24
DHCP_START=${SUBNET}.2
DHCP_END=${SUBNET}.254

# Files and locations
APCFG="/etc/hostapd/hostapd.conf"
NETCFG="/etc/conf.d/network@$WLAN"
NETSRV="/etc/systemd/system/network@.service"
DHCPCFG="/etc/dhcp.cfg"
DHCPSRV="/etc/systemd/system/dhcp@.service"
DNSCFG="/etc/dnsspoof.conf"
DNSSRV="/etc/systemd/system/dnsspoof@.service"
LOG=setap.log

# Command aliases
WGET="wget"
PACMAN="pacman --noconfirm --noprogressbar"

# warn_and_die(message)
#
# Prints a big fat warning message and exits
#
warn_and_die() {
    echo ""
    echo "=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*"
    echo "$1"
    echo "=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*"
    exit 1
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

# Make sure we're root
echo -n "Root permissions... "
if [[ $UID != $ROOT ]]; then
    warn_and_die "Please run this script as root."
fi
echo "OK"

# Checks internet connection. 0 means OK.
echo -n "Internet connection... "
if [[ $(checknet "http://example.com/") != $OK ]]; then
    warn_and_die "Internet connection is required."
fi
echo "OK"

echo -n "Installing packages... "
do_or_fail $PACMAN -Sqy
do_or_fail $PACMAN -Sq --needed iw hostapd dhcp dsniff
echo "DONE"

echo -n "Wi-Fi interface with AP mode support... "
if [[ $(checkiw) == $NO ]]; then
    echo "FAILED"
    warn_and_die "Wireless interface does not support AP mode"
fi
echo "OK"

# Configure networking
echo -n "Configuring $WLAN interface... "
cat > "$NETCFG" <<EOF
address=$IPADDR
netmask=$NETMASKB
broadcast=${SUBNET}.255
gateway=$IPADDR
EOF
cat > "$NETSRV" <<EOF
[Unit]
Description=Network connectivity (%i)
Wants=network.target
Before=network.target
BindsTo=sys-subsystem-net-devices-%i.device
After=sys-subsystem-net-devices-%i.device

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=/etc/conf.d/network@%i

ExecStart=/usr/bin/ip link set dev %i up
ExecStart=/usr/bin/ip addr add \${address}/\${netmask} broadcast \${broadcast} dev %i
ExecStart=/usr/bin/sh -c 'test -z \${gateway} || /usr/bin/ip route add default via \${gateway}'

ExecStop=/usr/bin/ip addr flush dev %i
ExecStop=/usr/bin/ip route flush dev %i
ExecStop=/usr/bin/ip link set dev %i down

[Install]
WantedBy=multi-user.target
EOF
echo "DONE"

# TODO: Perform check to make sure network configuration is correct

# Configure hostapd
echo -n "Configuring hotspot... "
cat > "$APCFG" <<EOF
interface=$WLAN
driver=$HOSTAPDRV
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
ieee8021x=0
eap_server=0
EOF
echo "DONE"

# Configure DHCP server
echo -n "Configuring DHCP server... "
cat > "$DHCPCFG" <<EOF
option domain-name-servers $IPADDR;
option subnet-mask $NETMASK;
option routers $IPADDR;
subnet ${SUBNET}.0 netmask $NETMASK {
  range $DHCP_START $DHCP_END;
}
EOF
cat > "$DHCPSRV" <<EOF
[Unit]
Description=IPv4 DHCP server on %i
Wants=network.target
After=network.target

[Service]
Type=forking
PIDFile=/run/dhcpd4.pid
ExecStart=/usr/bin/dhcpd -q -cf "$DHCPCFG" -pf /run/dhcpd4.pid %i
KillSignal=SIGINT

[Install]
WantedBy=multi-user.target
EOF
echo "DONE"

# Configure DNS spoofing
echo -n "Configuring DNS spoofing... "
cat > "$DNSCFG" <<EOF
$IPADDR *
EOF
cat > "$DNSSRV" <<EOF
[Unit]
Description=DNS spoofing on %i
Wants=hostapd
After=hostapd

[Service]
ExecStart=/usr/bin/dnsspoof -i %i -f "$DNSCFG"
RestartSec=5
Restart=always

[Install]
WantedBy=multi-user.target
EOF
echo "DONE"

echo -n "Configuring system services... "
do_or_fail systemctl daemon-reload
do_or_fail systemctl enable "network@$WLAN"
do_or_fail systemctl enable hostapd
do_or_fail systemctl enable "dhcp@$WLAN"
do_or_fail systemctl enable "dnsspoof@$WLAN"
echo "DONE"

echo -n "Starting hostspot... "
do_or_fail systemctl restart "network@$WLAN"
do_or_fail systemctl restart hostapd
do_or_fail systemctl restart "dhcp@$WLAN"
do_or_fail systemctl restart "dnsspoof@$WLAN"
echo "DONE"

echo "Hotspot started."
echo "SSID:         $SSID"
echo "password:     $PSK"
echo "device's IP:  $IPADDR"
