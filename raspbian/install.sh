#!/usr/bin/env bash
#
# install.sh: Install Outernet's Librarian on Raspbian
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
RELEASE=0.1a5.1
ONDD_RELEASE="0.1.0-0"
NAME=librarian
ROOT=0
OK=0
YES=0
NO=1

# Command aliases
#
# NOTE: we use the `--no-check-certificate` because wget on RaspBMC thinks the
# GitHub's SSL cert is invalid when downloading the tarball.
#
EI="easy_install-3.4"
PIP="pip"
WGET="wget --no-check-certificate"
UNPACK="tar xzf"
MKD="mkdir -p"
PYTHON=/usr/bin/python3

# URLS and locations
PKGS="http://outernet-project.github.io/orx-install"
FWS="https://github.com/OpenELEC/dvb-firmware/raw/master/firmware"
SRCDIR="/opt/$NAME"
FWDIR=/lib/firmware
SPOOLDIR=/var/spool/downloads/content
SRVDIR=/srv/zipballs
TMPDIR=/tmp
PKGLISTS=/etc/apt/sources.list.d
INPUT_RULES=/etc/udev/rules.d/99-input.rules
LOCK=/run/lock/orx-setup.lock
LOG="install.log"

FIRMWARES=(dvb-fe-ds3000 dvb-fe-tda10071 dvb-demod-m88ds3103)

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
# Prints a big fat warning message and exitsdvb-demod-m88ds3103.fw
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
        echo "Backed up '$1' to '${1}.old'" >> "$LOG"
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
# Preflight checks
###############################################################################

section "Root permissions"
if [[ $EUID -ne $ROOT ]]; then
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
    warn_and_die "Port 80 is taken. Disable any webservers and try again."
fi
echo "OK"

###############################################################################
# Packages
###############################################################################

section "Adding additional repositories"
if [[ $(is_in_sources jessie) == $NO ]]; then
    # Adds Raspbian's jessie repositories to sources.list
    cat > "$PKGLISTS/jessie.list" <<EOF
deb http://archive.raspbian.org/raspbian jessie main contrib non-free
deb-src http://archive.raspbian.org/raspbian jessie main contrib non-free
EOF
fi
if [[ $(is_in_sources tvheadend.org) == $NO ]]; then
    cat > "$PKGLISTS/tvheadend.list" << EOF
deb http://apt.tvheadend.org/stable wheezy main
EOF
fi
do_or_fail apt-key adv --keyserver keyserver.ubuntu.com --recv-key 5243CDED
curl -s --stderr "$LOG" http://apt.tvheadend.org/repo.gpg.key \
    | sudo apt-key add - \
    >> $LOG 2>&1 || fail
echo "DONE"

section "Installing packages"
do_or_fail apt-get update
DEBIAN_FRONTEND=noninteractive do_or_fail apt-get -y --force-yes install \
    python3.4 python3.4-dev python3-setuptools tvheadend
do_or_fail $EI pip
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
# Outernet Data Delivery agent
###############################################################################

section "Installing Outernet Data Delivery agent"
do_or_fail wget --directory-prefix "$TMPDIR" \
    "$PKGS/ondd_${ONDD_RELEASE}_armhf.deb"
do_or_fail dpkg -i "$TMPDIR/ondd_${ONDD_RELEASE}_armhf.deb"
do_or_pass rm "$TMPDIR/ondd_${ONDD_RELEASE}_armhf.deb"
echo "DONE"

###############################################################################
# Librarian
###############################################################################

# Obtain and unpack the Librarian source
section "Installing Librarian"
do_or_fail $PIP install "$PKGS/$NAME-${RELEASE}.tar.gz"
echo "DONE"

# Create paths necessary for the software to run
section "Creating necessary directories"
do_or_fail $MKD "$SPOOLDIR"
do_or_fail $MKD "$SRVDIR"
echo "DONE"

###############################################################################
# System services
###############################################################################

section "Configuring system services"
# Create upstart job
cat > "/etc/init/${NAME}.conf" <<EOF
description "Outernet Librarian v$RELEASE"

start on (started networking)
stop on (stopped networking)
respawn

exec $PYTHON -m librarian.app
EOF
# Create init script
cat > "/etc/init.d/${NAME}" <<EOF
#! /bin/sh
### BEGIN INIT INFO
# Provides:          librarian
# Required-Start:    \$network \$remote_fs
# Required-Stop:     \$network \$remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Librarian v$RELEASE
# Description:       Starts the Librarian, Outernet archive manager
### END INIT INFO

# Author Outernet Inc <branko@outernet.is>

DESC="Outernet archive manager"
NAME="$NAME"
PATH=/sbin:/usr/sbin:/bin:/usr/bin
LOGFILE=/var/log/${NAME}.log
USER=root
DAEMON="/usr/bin/python3 -m ${NAME}.app"

# Load init settings and LSB functions
. /lib/init/vars.sh
. /lib/lsb/init-functions

#
# Function to check if process is running
#
is_running() {
    ps ax | grep "\$DAEMON" | grep -v grep > /dev/null
    return \$?
}

#
# Function to get process ID(s) of running processes
#
pids() {
    ps ax | grep "\$DAEMON" | grep -v grep | awk '{print \$1;}'
}

#
# Function to start daemon
#
do_start() {
    # Return
    #   0 if daemon has been started
    #   1 if daemon was already started
    #   2 if daemon could not be started
    is_running
    case "\$?" in
        0)
            return 1
            ;;
        *)
            \$DAEMON &
            if [ "\$?" != 0 ]; then
                # Failed to start
                return 2
            fi
            sleep 30
            return 0
            ;;
    esac
}

#
# Function to stop the daemon
#
do_stop() {
    # Return
    #   0 if daemon has been stopped
    #   1 if daemon was already stopped
    #   2 if daemon could not be stopped
    is_running
    case "\$?" in
        0)
            for pid in \$(pids); do
                kill \$pid || return 2
            done
            return 0
            ;;
        *) 
            return 1
            ;;
    esac
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
    status)
        is_running
        status=\$?
        case \$status in
            0) 
                log_success_msg "\$DESC is started: \$NAME"
                exit 0;
                ;;
            1) 
                log_failure_msg "\$DESC is not started: \$NAME"
                exit 3;
                ;;
            *)
                log_failure_msg "\$DESC status unknown: \$NAME"
                exit 4;
                ;;
        esac
        ;;
    restart|force-reload)
        log_daemon_msg "Restaring \$DESC" "\$NAME"
        do_stop
        case "\$?" in
            0|1)
                do_start
                case "\$?" in
                    0) log_end_msg 0 ;;
                    1) log_end_msg 1 ;; # Still running
                    *) log_end_msg 1 ;; # WTF?
                esac
                ;;
            *)
                log_end_msg 1 # WTF?
                ;;
        esac
        ;;
    *)
        echo "Usage: \$SCRIPTNAME {start|stop|status|restart|force-reload}" >&2
        exit 3
        ;;
esac

:
EOF
echo "DONE"

if ! grep "--noacl" "/etc/init.d/tvheadend" > /dev/null 2> "$LOG"; then
    read -p "Do you wish to disable superuser for TVHeadend? [y/N] " -n 1 tvacl
    echo ""
    if [[ "$tvacl" == "Y" ]] || [[ "$tvacl" == "y" ]]; then
        backup "/etc/init.d/tvheadend"
        chmod -x "/etc/init.d/tvheadend.old"
        sed -i 's|ARGS="-f"|ARGS="-f --noacl"|' "/etc/init.d/tvheadend"
        backup "/etc/init/tvheadend.conf"
        sed -i 's|ARGS="-f"|ARGS="-f --noacl"|' "/etc/init/tvheadend.conf"
    else
        read -p "Do you want to set up superuser for TVHeadend? [y/N] " -n 1 tvsu
        echo ""
        if [[ "$tvsu" == "Y" ]] || [[ "$tvsu" == "y" ]]; then
            dpkg-reconfigure tvheadend
        else
            cat <<EOF
If you wish to manually configure the superuser account for 
TVHeadend, you can run:

    dpkg-reconfigure tvheadend

EOF
        fi
    fi
fi


section "Configuring system services"
chmod +x "/etc/init.d/$NAME"
do_or_fail update-rc.d $NAME defaults
do_or_fail update-rc.d ondd defaults
do_or_fail service $NAME start
do_or_fail service ondd start
do_or_fail service tvheadend restart
echo "DONE"

###############################################################################
# Cleanup
###############################################################################

touch "$LOCK"

echo "Install logs can be found in '$LOG'."
