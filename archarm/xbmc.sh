#!/usr/bin/env bash
#
# xmbc.sh: Install and configure XBMC on Arch ARM
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

# Locations
LOG="xbmc.log"

# Command aliases
PACMAN="pacman --noconfirm --noprogressbar"

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
# Preflight check
###############################################################################

section "Root permissions"
if [[ $UID != $ROOT ]]; then
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

section "Installing packages"
do_or_fail $PACMAN -Sqy
do_or_fail $PACMAN -Sq --needed xbmc-rbp polkit
echo "DONE"

###############################################################################
# PolicyKit
###############################################################################

section "Configuring PolicyKit rules"
# Configure PolicyKit to allow shutdown/reboot actions
# https://github.com/chaosdorf/archlinux-xbmc/blob/master/releng/root-image/etc/polkit-1/rules.d/10-xbmc.rules
cat > "/etc/polkit-1/rules.d/10-xbmc.rules" <<EOF
polkit.addRule(function(action, subject) {
    if(action.id.match("org.freedesktop.login1.") && subject.isInGroup("power")) {
        return polkit.Result.YES;
    }
});

polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.udisks") == 0 && subject.isInGroup("storage")) {
        return polkit.Result.YES;
    }
});
EOF
echo "DONE"

###############################################################################
# System services
###############################################################################

section "Configuring system services"
do_or_fail systemctl daemon-reload
if ! [[ $(systemctl is-enabled xbmc | grep "enabled") ]]; then
    do_or_fail systemctl enable xbmc
fi
echo "DONE"

###############################################################################
# Cleanup
###############################################################################

echo "Install logs can be found in '$LOG'."
