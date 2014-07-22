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
SRCDIR="/opt/$NAME"
SPOOLDIR=/var/spool/downloads/content
SRVDIR=/srv/zipballs
TMPDIR=/tmp
LOCK=/run/lock/orx-setup.lock

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

# checknet(URL)
# 
# Performs wget dry-run on provided URL to see if it works. Echoes 0 if 
# everything is OK, or non-0 otherwise.
#
checknet() {
    $WGET -q --tries=10 --timeout=20 --spider "$1" > /dev/null || echo 1
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
    warn_and_die "Port 80 is taken. Disable the XBMC webserver and try again."
fi

# Add jessie repository
if ! [[ $(grep jessie /etc/apt/sources.list) ]]; then
    # Adds Raspbian's jessie repositories to sources.list
    cat >> /etc/apt/sources.list <<END
# Added by install-librarian.sh
deb http://archive.raspbian.org/raspbian jessie main contrib non-free
deb-src http://archive.raspbian.org/raspbian jessie main contrib non-free
END
fi

# Install necessary packages from jessie
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y --force-yes install python3.4 \
    python3.4-dev python3-setuptools

# Obtain and unpack the Librarian source
rm "$TMPDIR/$TARBALL" || true # Make sure there aren't any old ones
$WGET --directory-prefix "$TMPDIR" "${TARS}${TARBALL}"
$UNPACK "$TMPDIR/$TARBALL" -C /opt 
rm "$SRCDIR" || true # For some reason `ln -f` doesn't work, so we remove first
ln -s "${SRCDIR}-${RELEASE}" "$SRCDIR"
rm "$TMPDIR/$TARBALL" # Remove tarball, since it's no longer needed

# Install python dependencies globally
$EI pip
$PIP install -r "$SRCDIR/conf/requirements.txt"

# Create paths necessary for the software to run
$MKD "$SPOOLDIR"
$MKD "$SRVDIR"

# Create upstart job
cat > "/etc/init/${NAME}.conf" <<EOF
description "Outernet Librarian v$RELEASE"

start on custom-network-done
stop on shutdown
respawn

script
PYTHONPATH=$SRCDIR python3 "$SRCDIR/$NAME/app.py"
end script
EOF

service $NAME start

touch "$LOCK"
