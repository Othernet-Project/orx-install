#!/usr/bin/env bash
#
# install-librarian.sh: Install Outernet's Librarian on RaspBMC
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
RELEASE=0.1a3
NAME=librarian
ROOT=0
OK=0

# URLS and locations
TARS="https://github.com/Outernet-Project/$NAME/archive/"
EXT=".tar.gz"
TARBALL="v${RELEASE}${EXT}"
OPTDIR="/opt"
SRCDIR="$OPTDIR/$NAME"
BINDIR="/usr/local/bin"
SPOOLDIR=/var/spool/downloads/content
SRVDIR=/srv/zipballs
TMPDIR=/tmp
LOCK=/run/lock/orx-setup.lock
LOG="install.log"

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
    echo "FAILED"
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

# Make sure we're root
if [[ $UID != $ROOT ]]; then
    warn_and_die "Please run this script as root."
fi

# Check if there's a lock file
if [[ -f "$LOCK" ]]; then
    warn_and_die "Already set up. Remove lock file '$LOCK' to reinstall."
fi

# Checks internet connection. 0 means OK.
if [[ $(checknet "http://example.com/") != $OK ]]; then
    warn_and_die "Internet connection is required."
fi

# Check if port 80 is taken
if [[ $(checknet "127.0.0.1:80") == $OK ]]; then
    warn_and_die "Port 80 is taken. Disable the XBMC webserver or stop $NAME."
fi

echo -n "Installing packages... "
do_or_fail $PACMAN -Sqy
do_or_fail $PACMAN -Sq --needed xbmc-rbp python python-pip
echo "DONE"

# Obtain and unpack the Librarian source
echo -n "Getting $NAME v$RELEASE sources... "
do_or_pass rm "$TMPDIR/$TARBALL" # Make sure there isn't any old one
$WGET --directory-prefix "$TMPDIR" "${TARS}${TARBALL}" || fail
do_or_fail $UNPACK "$TMPDIR/$TARBALL" -C "$OPTDIR"
do_or_pass rm "$SRCDIR" # for some reason `ln -f` doesn't work, so we remove
do_or_fail ln -s "${SRCDIR}-${RELEASE}" "$SRCDIR"
do_or_fail rm "$TMPDIR/$TARBALL" # Remove tarball, no longer needed
echo "DONE"

# Install dependencies globally
echo -n "Installing Python packages... "
do_or_fail $PIP install -r "$SRCDIR/conf/requirements.txt"
echo "DONE"

# Create necessary directories
echo -n "Creating necessary directories... "
do_or_fail $MKD "$SPOOLDIR"
do_or_fail $MKD "$SRVDIR" >> $LOG 2>&1
echo "DONE"

echo -n "Creating $NAME startup script... "
cat > "$BINDIR/$NAME" <<EOF
#!/usr/bin/bash
PYTHONPATH="$SRCDIR" $PYTHON "$SRCDIR/$NAME/app.py"
EOF
do_or_fail chmod +x "$BINDIR/$NAME"
echo "DONE"

# Create systemd unit for Librarian
echo -n "Creating $NAME systemd unit... "
cat > "/etc/systemd/system/${NAME}.service" <<EOF
[Unit]
Description=$NAME service
After=network.target

[Service]
ExecStart=$BINDIR/$NAME
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
echo "DONE"

echo -n "Configuring system services... "
do_or_fail systemctl daemon-reload
if ! [[ $(systemctl is-enabled $NAME | grep "enabled") ]]; then
    do_or_fail systemctl enable librarian
fi
if [[ $(systemctl status $NAME | grep "Active:" | grep "inactive") ]]; then
    do_or_fail systemctl start librarian
else
    do_or_fail systemctl restart librarian
fi
if ! [[ $(systemctl is-enabled xbmc | grep "enabled") ]]; then
    do_or_fail systemctl enable xbmc
fi
echo "DONE"

touch "$LOCK"

echo "Install logs can be found in '$LOG'."
