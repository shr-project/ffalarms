# ffalarms version
VERSION=0.4

PREFIX=/usr
SYSCONFDIR=/etc
PKG = elementary ecore evas edje gobject-2.0 dbus-glib-1 libical
PKG_CFLAGS = `pkg-config --cflags ${PKG}`
PKG_LDFLAGS = `pkg-config --libs ${PKG}`
VALAC=valac
VAPIDIR = .
VALAFLAGS = --vapidir=${VAPIDIR} --vapidir=. --pkg=elementary --pkg=edje --pkg=dbus-glib-1 \
	--pkg=posix --pkg=libical
CC ?= cc

OE_TOPDIR = `which bitbake | sed s:/bitbake/bin/bitbake::`
NEO = root@192.168.0.202

BASE_PACKAGE_ARCH = armv4t
DEPLOY_DIR_IPK = ${OE_TOPDIR}/tmp/deploy/ipk

PV=${VERSION}
PR=r0
DISTRO_PR=.5
IPK_BASENAME = ffalarms_${PV}-${PR}${DISTRO_PR}_${BASE_PACKAGE_ARCH}.ipk
IPK_DIR = ${DEPLOY_DIR_IPK}/${BASE_PACKAGE_ARCH}
