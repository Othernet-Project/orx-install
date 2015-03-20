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
RELEASE="0.1b3-1"
ONDD_RELEASE="0.1.0-4"
TVHE_RELEASE="3.4.27-2"
BJOERN_RELEASE="1.4.2-1"
SU3K_RELEASE="3.18.9-1"
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
PIP="pip2"
WGET="wget -o $LOG --quiet --no-check-certificate"
UNPACK="tar xzf"
MKD="mkdir -p"
PYTHON=/usr/bin/python2
PACMAN="pacman --noconfirm --noprogressbar"
MAKEPKG="makepkg --noconfirm"

# checknet()
# 
# Pings example.com and echoes 0 if it can be reached, 1 otherwise.
#
checknet() {
    ping -c 1 github.com > /dev/null && echo 0 || echo 1
}

# check80()
#
# Checks if port 80 is taken on localhost and echoes 0 if it isn't, 1 otherwise
#
check80() {
    # FIXME: Silence the next line or redirect it to logs
    exec 6<>/dev/tcp/127.0.0.1/80 >> /dev/null 2>&1 && echo "1" || echo "0"
    exec 6>&- # close output connection
    exec 6<&- # close input connection
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

# install_package(name, release, title, arch)
#
# Installs binary package from Outernet's package URL
#
install_package() {
    pkgname=$1
    pkgrel=$2
    pkgtitle=$3
    arch=$4
    : ${arch:=armv6h}
    pkgfile="${pkgname}-${pkgrel}-${arch}.pkg.tar.xz"
    if ! pacman -Q "$pkgname" 1> /dev/null 2>> "$LOG"; then
        do_or_fail $WGET --directory-prefix "$TMPDIR" \
            "$PKGS/packages/$pkgfile"
        do_or_fail $PACMAN -U "$TMPDIR/$pkgfile"
        do_or_pass rm -f "$TMPDID/$pkgfile"
        echo "DONE"
    else
        echo "${pkgtitle} already installed." >> "$LOG"
        echo "SKIPPED"
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
# License
###############################################################################

cat <<EOF

=======================================================
Outernet Data Delivery agent End User License Agreement
=======================================================

Among other things, this script installs ONDD (Outernet Data Delivery agent) 
which is licensed to you under the following conditions:

This software is provided as-is with no warranty and is for use exclusively
with the Outernet satellite datacast. This software is intended for end user
applications and their evaluation. Due to licensing agreements with third
parties, commercial use of the software is strictly prohibited. 

YOU MUST AGREE TO THESE TERMS IF YOU CONTINUE.

EOF
read -p "Press any key to continue (CTRL+C to quit)..." -n 1
echo ""

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
if [[ $(checknet) != $OK ]]; then
    warn_and_die "Internet connection is required."
fi
echo "OK"

section "Port 80 free"
if [[ $(check80) != $OK ]]; then
    warn_and_die "Port 80 is taken. Disable the webservers or stop $NAME."
fi
echo "OK"

###############################################################################
# Packages
###############################################################################

section "Updating package database"
do_or_fail $PACMAN -Sqy
echo "DONE"

section "Upgrading system packages"
do_or_fail $PACMAN -Squ
echo "DONE"

section "Installing packages"
do_or_fail $PACMAN -Sq --needed python2 python2-pip git openssl avahi libev \
    base-devel wget python2-greenlet python2-gevent python2-six \
    python2-babel python2-dateutil python2-pytz python2-bottle
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
# Custom packages
###############################################################################

section "Installing Outernet Data Delivery agent v$ONDD_RELEASE"
install_package ondd "$ONDD_RELEASE" ONDD

section "Installing TVHeadend v$TVHE_RELEASE"
install_package tvheadend "$TVHE_RELEASE" TVHeadend

section "Installing Bjoern v$BJOERN_RELEASE"
install_package python2-bjoern "$BJOERN_RELEASE" Bjoern

section "Installing Librarian v${RELEASE}"
install_package python2-librarian "$RELEASE" Librarian any

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
echo "Please reboot the system now."
