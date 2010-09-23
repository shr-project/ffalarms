# ffalarms version
VERSION=0.4

PREFIX=/usr
SYSCONFDIR=/etc
PKG = elementary gobject-2.0 dbus-glib-1 libical
PKG_CFLAGS = `pkg-config --cflags ${PKG}`
PKG_LDFLAGS = `pkg-config --libs ${PKG}`

# XXX this is local conf
VALAC=valac
VAPIDIR = ${HOME}/src/libeflvala/vapi
VALAFLAGS = --vapidir=${VAPIDIR} --vapidir=. \
	--pkg=elm --pkg=edje --pkg=dbus-glib-1 --pkg=posix --pkg=libical

SHR=${HOME}/src/shr/shr-unstable
NATIVE_BIN=${SHR}/tmp/sysroots/i686-linux/usr/bin
CROSS_CC=${SHR}/tmp/sysroots/i686-linux/usr/armv4t/bin/arm-oe-linux-gnueabi-gcc -march=armv4t
CROSS_STAGING_DIR=${SHR}/tmp/sysroots/armv4t-oe-linux-gnueabi
CROSS_PKG_CONFIG_PATH=${CROSS_STAGING_DIR}/usr/lib/pkgconfig
CROSS_PKG_CONFIG=PKG_CONFIG_PATH=${CROSS_PKG_CONFIG_PATH} \
	PKG_CONFIG_SYSROOT_DIR=${CROSS_STAGING_DIR} \
	${NATIVE_BIN}/pkg-config
CROSS_CFLAGS = `${CROSS_PKG_CONFIG} --cflags ${PKG}`
CROSS_LDFLAGS = `${CROSS_PKG_CONFIG} --libs ${PKG}`

NEO=192.168.0.202

PN=ffalarms
PV=${VERSION}
PR=r0
DISTRO_PR=.5
IPK=${TOPDIR}/tmp/deploy/ipk/armv4t/${PN}_${PV}-${PR}${DISTRO_PR}_armv4t.ipk

TOPDIR=${SHR}
RECIPE_DIR=~/src/shr/local/recipes
RECIPE=${RECIPE_DIR}/ffalarms/${PN}_${PV}.bb

EFL=~/src/e
