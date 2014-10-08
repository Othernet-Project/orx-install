#!/usr/bin/env bash
#
# install.sh: Install Outernet's Librarian on Arch ARM
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

# Constants
RELEASE=0.1a6.1
ONDD_RELEASE="0.1.0-3"
NAME=librarian
ROOT=0
OK=0
YES=0
NO=1

# URLS and locations
PKGS="http://outernet-project.github.io/orx-install"
FWS="https://github.com/OpenELEC/dvb-firmware/raw/master/firmware"
EXT=".tar.gz"
TARBALL="v${RELEASE}${EXT}"
OPTDIR="/opt"
SRCDIR="$OPTDIR/$NAME"
FWDIR=/lib/firmware
BINDIR="/usr/local/bin"
SPOOLDIR=/var/spool/downloads/content
SRVDIR=/srv/zipballs
TMPDIR=/tmp
LOCK=/run/lock/orx-setup.lock
LOG="install.log"

FIRMWARES=(dvb-fe-ds3000 dvb-fe-tda10071 dvb-demod-m88ds3103)

# Command aliases
#
# NOTE: we use the `--no-check-certificate` because wget on RaspBMC thinks the
# GitHub's SSL cert is invalid when downloading the tarball.
#
PIP="pip"
WGET="wget -o $LOG --quiet --no-check-certificate"
UNPACK="tar xzf"
MKD="mkdir -p"
PYTHON=/usr/bin/python
PACMAN="pacman --noconfirm --noprogressbar"
MAKEPKG="makepkg --noconfirm"

# checknet(URL)
# 
# Performs wget dry-run on provided URL to see if it works. Echoes 0 if 
# everything is OK, or non-0 otherwise.
#
checknet() {
    $WGET -q --tries=10 --timeout=20 --spider "$1" || echo 1
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

# ensure_service(name)
#
# Ensure that service is enabled and started. It enables services only if not 
# already enabled, and restarts services that have already been started.
#
ensure_service() {
    if ! [[ $(systemctl is-enabled "$1" | grep "enabled") ]]; then
        do_or_fail systemctl enable "$1"
    fi
    if [[ $(systemctl status "$1" | grep "Active:" | grep "inactive") ]]; then
        do_or_fail systemctl start "$1"
    else
        do_or_fail systemctl restart "$1"
    fi
}

###############################################################################
# Preflight check
###############################################################################

section "Root permissions"
if [[ $UID != $ROOT ]]; then
    warn_and_die "Please run this script as root."
fi
echo "OK"

section "Lock file"
if [[ -f "$LOCK" ]]; then
    warn_and_die "Already set up. Remove lock file '$LOCK' to reinstall."
fi
echo "OK"

section "Internet connection"
if [[ $(checknet "http://example.com/") != $OK ]]; then
    warn_and_die "Internet connection is required."
fi
echo "OK"

section "Port 80 free"
if [[ $(checknet "127.0.0.1:80") == $OK ]]; then
    warn_and_die "Port 80 is taken. Disable the webservers or stop $NAME."
fi
echo "OK"

###############################################################################
# Packages
###############################################################################

section "Installing packages"
do_or_fail $PACMAN -Sqy
do_or_fail $PACMAN -Squ
do_or_fail $PACMAN -Sq --needed python python-pip git openssl avahi python2 \
    base-devel
echo "DONE"

###############################################################################
# Firmwares
###############################################################################

section "Installing firmwares"
for fw in ${FIRMWARES[*]}; do
    echo "Installing ${fw} firmware" >> "$LOG"
    if ! [[ -f "$FWDIR/${fw}.fw" ]]; then
        do_or_fail $WGET --directory-prefix "$FWDIR" "$FWS/${fw}.fw"
    fi
done
echo "DONE"

###############################################################################
# ONDD
###############################################################################

section "Installing Outernet Data Delivery agent"
if ! pacman -Q ondd 2>> "$LOG" | grep "$ONDD_RELEASE" > /dev/null;then
    do_or_fail $WGET --directory-prefix "$TMPDIR" \
        "${PKGS}/ondd-${ONDD_RELEASE}-armv6h.pkg.tar.xz"
    do_or_fail $PACMAN -U "$TMPDIR/ondd-${ONDD_RELEASE}-armv6h.pkg.tar.xz"
    do_or_pass rm -f "$TMPDIR/ondd-${ONDD_RELEASE}-armv6h.pkg.tar.xz"
    echo "DONE"
else
    echo "ONDD already installed." >> "$LOG"
    echo "SKIPPED"
fi

###############################################################################
# Librarian
###############################################################################

section "Installing Librarian"
do_or_pass $PIP install "$PKGS/$NAME-${RELEASE}.tar.gz"
echo "DONE"

section "Creating necessary directories"
do_or_fail $MKD "$SPOOLDIR"
do_or_fail $MKD "$SRVDIR"
echo "DONE"

section "Creating $NAME systemd unit"
cat > "/etc/systemd/system/${NAME}.service" <<EOF
[Unit]
Description=$NAME service
After=network.target

[Service]
ExecStart=/usr/bin/python -m '${NAME}.app'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
echo "DONE"

###############################################################################
# TVHeadend
###############################################################################

section "Installing TVHeadend from AUR"
if ! pacman -Q tvheadend 1> /dev/null 2>> "$LOG"; then
    do_or_fail $WGET --directory-prefix "$TMPDIR" \
        https://aur.archlinux.org/packages/tv/tvheadend/tvheadend.tar.gz
    do_or_fail $UNPACK "$TMPDIR/tvheadend.tar.gz"
    do_or_fail rm "$TMPDIR/tvheadend.tar.gz"
    cd tvheadend
    do_or_fail $MAKEPKG --asroot -i
    cd ..
    do_or_fail rm -rf tvheadend
    echo "DONE"
else
    echo "TVHeadend already installed." >> "$LOG"
    echo "SKIPPED"
fi

###############################################################################
# System services
###############################################################################

# Configure system services
section "Configuring system services"
do_or_fail systemctl daemon-reload
ensure_service ondd
ensure_service $NAME
ensure_service tvheadend
echo "DONE"

###############################################################################
# Cleanup
###############################################################################

touch "$LOCK"

echo "Install logs can be found in '$LOG'."
