#!/usr/bin/env bash
#
# xbmc.sh: Install and set up XBMC in stand-alone mode on Raspbian
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
ROOT=0
OK=0
YES=0
NO=1
XBMC_USER=xbmc
XBMC_GROUPS=(input audio video dialout plugdev tty)

# Command aliases
WGET="wget --no-check-certificate"

# URLS and locations
TMPDIR=/tmp
PKGLISTS=/etc/apt/sources.list.d
INPUT_RULES=/etc/udev/rules.d/99-input.rules
LOG="install.log"

# checknet(URL)
# 
# Performs wget dry-run on provided URL to see if it works. Echoes 0 if 
# everything is OK, or non-0 otherwise.
#
checknet() {
    $WGET -q --tries=10 --timeout=20 --spider "$1" > /dev/null || echo $NO
    echo $?
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

# ensure_group(name)
#
# Ensure system group with given name exists.
#
ensure_group() {
    grep "$1" /etc/group &> /dev/null || do_or_fail addgroup --system "$1"
}

# is_in_sources(name)
#
# Find out if any of the package source lists contain the name
is_in_sources() {
    result=$(grep -h ^deb /etc/apt/sources.list /etc/apt/sources.list.d/*.list | grep -o "$1")
    case "$result" in
        "$1") echo $YES ;;
        *) echo $NO ;;
    esac
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

###############################################################################
# Preflight checks
###############################################################################

section "Root permissions"
if [[ $EUID -ne $ROOT ]]; then
    warn_and_die "Please run this script as root."
fi
echo "OK"

section "Internet connection"
if [[ $(checknet "http://example.com/") != $OK ]]; then
    warn_and_die "Internet connection is required."
fi
echo "OK"

###############################################################################
# Packages
###############################################################################

section "Adding additional repositories"
if [[ $(is_in_sources mene.za.net) == $NO ]]; then
    cat > "$PKGLISTS/mene.list" << EOF
deb http://archive.mene.za.net/raspbian wheezy contrib
EOF
fi
do_or_fail apt-key adv --keyserver keyserver.ubuntu.com --recv-key 5243CDED
echo "DONE"

section "Installing packages"
do_or_fail apt-get update
DEBIAN_FRONTEND=noninteractive do_or_fail apt-get -y --force-yes install \
    python3.4 python3.4-dev python3-setuptools tvheadend
echo "DONE"

###############################################################################
# XBMC
###############################################################################

section "Configuring XBMC"
# Create 'xbmc' user
if ! [[ $(grep "$XBMC_USER" /etc/passwd) ]]; then
    do_or_fail useradd "$XBMC_USER"
fi
# Create any missing groups
for grp in ${XBMC_GROUPS[@]}; do
    ensure_group "$grp"
done
# Ensure it belongs to necessary groups
for grp in ${XBMC_GROUPS[@]}; do
    do_or_pass gpasswd -a "$XBMC_USER" "$grp"
done
# Add udev rules
backup "$INPUT_RULES"
cat > "$INPUT_RULES" <<EOF
SUBSYSTEM=="input", GROUP="input", MODE="0660"
KERNEL=="tty[0-9]*", GROUP="tty", MODE="0660"
EOF
# Configure XBMC to start on boot
if ! [[ $(grep "ENABLED=1" /etc/default/xbmc) ]]; then
    backup /etc/default/xbmc
    cat /etc/default/xbmc.old | sed 's|ENABLED=0|ENABLED=1|' \
        > /etc/default/xbmc
fi
do_or_fail update-rc.d xbmc defaults
echo "DONE"

echo "You may want to reboot the system now."
