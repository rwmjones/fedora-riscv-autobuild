#!/bin/bash -

# Script which controls the build process.  Installed as a
# firstboot service.

hostname stage4-builder
echo stage4-builder.fedoraproject.org > /etc/hostname

echo
echo "Welcome to the Fedora/RISC-V stage4 builder"
echo

# Cleanup function called on failure or exit.
cleanup ()
{
    set +e
    # Sync disks and shut down.
    sync
    sleep 5
    sync
    poweroff
}
trap cleanup INT QUIT TERM EXIT ERR

user=mockbuild
topdir=/builddir/build

set -x
set -e

exec >& /root.log

# For dnf to reread the 'local' repo.
dnf clean all
dnf makecache --verbose

# Create a 'mockbuild' user.
useradd -d /builddir $user

# Use a build directory which isn't root.
#
# Required to work around:
# /usr/lib/rpm/debugedit: -b arg has to be either the same length as -d arg, or more than 1 char longer
# and:
# https://bugzilla.redhat.com/show_bug.cgi?id=757089
# when building debuginfo.
#
# Also works around a cmake bug:
# https://github.com/rwmjones/fedora-riscv/commit/68780a3e928b01f9012f5e8cd014ff636a7467b3
su -c "mkdir $topdir" $user

# Set _topdir to point to the build directory.
echo "%_topdir $topdir" > /builddir/.rpmmacros

# Install the SRPM.
su -c "rpm -i /var/tmp/@SRPM@" $user

# Install the package BuildRequires.  We do this first as it's the
# step most likely to fail.
dnf -y builddep $topdir/SPECS/@NAME@.spec --define "_topdir $topdir"

# Pick up any updated packages since stage4 was built:
dnf -y update --best

# Install the basic build environment.
dnf -y group install buildsys-build

exec >& /build.log

# Close stdin in case build is interactive.
exec < /dev/null

rm -rf /rpmbuild
mkdir -p /rpmbuild

su -c "rpmbuild -ba $topdir/SPECS/@NAME@.spec \
           --define \"debug_package %{nil}\" \
           --undefine _annotated_build \
           --define \"_missing_doc_files_terminate_build %{nil}\" \
           --define \"_emacs_sitestartdir /usr/share/emacs/site-lisp/site-start.d\" \
           --define \"_emacs_sitelispdir /usr/share/emacs/site-lisp\" \
           --nocheck \
  " $user

touch /buildok

# cleanup() is called automatically here.
