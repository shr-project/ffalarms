VERSION=0.2.4

FFALARMS_FILES=\
COPYING \
README \
Makefile \
ffalarms.bb \
ffalarms.vala \
ffalarms.vapi \
ffalarms.c \
ffalarms.h \
data/ffalarms.edc \
data/alarm.sh \
data/alarm.wav \
data/ffalarms.desktop \
images/circle.png \
images/ffalarms.png \
images/ffalarms.svg

FIX_CFLAGS = -I.

PREFIX=/usr
PKG = elementary gobject-2.0 dbus-glib-1
PKG_CFLAGS = `pkg-config --cflags ${PKG}`
PKG_LDFLAGS = `pkg-config --libs ${PKG}`

# XXX this is local conf
VALAC=valac
VAPIDIR = $(HOME)/src/libeflvala/vapi
VALAFLAGS = --vapidir=${VAPIDIR} \
	--pkg=elm --pkg=edje --pkg=dbus-glib-1 --pkg posix

SHR=${HOME}/shr/shr-unstable
NATIVE_BIN=$(SHR)/tmp/staging/i686-linux/usr/bin
CROSS_CC=$(SHR)/tmp/cross/armv4t/bin/arm-angstrom-linux-gnueabi-gcc
CROSS_STAGING_DIR=$(SHR)/tmp/staging/armv4t-angstrom-linux-gnueabi
CROSS_PKG_CONFIG_PATH=${CROSS_STAGING_DIR}/usr/lib/pkgconfig
CROSS_PKG_CONFIG=PKG_CONFIG_PATH=${CROSS_PKG_CONFIG_PATH} \
	PKG_CONFIG_SYSROOT_DIR=${CROSS_STAGING_DIR} \
	${NATIVE_BIN}/pkg-config
CROSS_CFLAGS = `${CROSS_PKG_CONFIG} --cflags ${PKG}`
CROSS_LDFLAGS = `${CROSS_PKG_CONFIG} --libs ${PKG}`

NEO=192.168.0.202


all: ffalarms data/ffalarms.edj

.PHONY: all dist install clean

ffalarms: ffalarms.o
	${CC} ${LDFLAGS} ${PKG_LDFLAGS} $< -o $@

ffalarms.o: ffalarms.c
	${CC} -c ${FIX_CFLAGS} ${CFLAGS} ${PKG_CFLAGS} $< -o $@

ffalarms.c: ffalarms.vala ffalarms.vapi
	${VALAC} ${VALAFLAGS} -C $^
	@touch $@  # seems to be sometimes needed

data/ffalarms.edj: data/ffalarms.edc
	edje_cc $< $@

dist: ffalarms-${VERSION}.tar.gz

ffalarms-${VERSION}.tar.gz: ${FFALARMS_FILES}
	mkdir -p ffalarms-${VERSION}
	mkdir -p ffalarms-${VERSION}/data ffalarms-${VERSION}/images
	for x in ${FFALARMS_FILES}; do cp $$x ffalarms-${VERSION}/$$x; done
	tar zcf ffalarms-${VERSION}.tar.gz ffalarms-${VERSION}
	rm -r ffalarms-${VERSION}

install: all
	install -d ${DESTDIR}${PREFIX}/bin 
	install -m 755  ffalarms ${DESTDIR}${PREFIX}/bin
	install -d ${DESTDIR}${PREFIX}/share/ffalarms
	install -m 644 data/alarm.wav ${DESTDIR}${PREFIX}/share/ffalarms
	install -m 644 data/alarm.sh ${DESTDIR}${PREFIX}/share/ffalarms
	install -m 644 data/ffalarms.edj ${DESTDIR}${PREFIX}/share/ffalarms
	install -d ${DESTDIR}${PREFIX}/share/applications
	install -m 644 data/ffalarms.desktop ${DESTDIR}${PREFIX}/share/applications
	install -d ${DESTDIR}${PREFIX}/share/pixmaps
	install -m 644 images/ffalarms.png ${DESTDIR}${PREFIX}/share/pixmaps

clean:
	rm -f *.o ffalarms armv4t/ffalarms


armv4t/ffalarms: ffalarms.c
	${CROSS_CC} ${FIX_CFLAGS} ${CROSS_CFLAGS} ${CROSS_LDFLAGS} $< -o $@

.PHONY: inst run

inst: armv4t/ffalarms data/ffalarms.edj
	rsync --archive data/ffalarms.edj armv4t/ffalarms ${NEO}:~/tmp/

run: inst
	ssh ${NEO} sh -c '". /etc/profile; \
		DISPLAY=:0 ~/tmp/ffalarms --edje ~/tmp/ffalarms.edj"'

PN=ffalarms
PV=${VERSION}
PR=r0
IPK=$(TOPDIR)/tmp/deploy/glibc/ipk/armv4t/$(PN)_$(PV)-$(PR)_armv4t.ipk

TOPDIR=~/shr/shr-unstable
RECIPE_DIR=~/shr/local/recipes
RECIPE=${RECIPE_DIR}/ffalarms/${PN}_${PV}.bb

.PHONY: ipk ipk-fast ipk-info ipk-inst rebuild reinstall tags

# STRANGE: somehow does not work with dash, I went back to bash
ipk: dist
	mkdir -p $(RECIPE_DIR)/ffalarms
	sed s/"r0"/"$(PR)"/ ffalarms.bb > ${RECIPE}
	cp -f ffalarms-$(PV).tar.gz $(RECIPE_DIR)/ffalarms
	cd ${TOPDIR} && . ${TOPDIR}/setup-env && bitbake ffalarms-${PV}

ipk-fast: dist
	mkdir -p $(RECIPE_DIR)/ffalarms
	sed s/"r0"/"$(PR)"/ ffalarms.bb > ${RECIPE}
	cp -f ffalarms-$(PV).tar.gz $(RECIPE_DIR)/ffalarms
	cd ${TOPDIR} && . ${TOPDIR}/setup-env && \
		bitbake -c package_write -b ${RECIPE}

ipk-info:
	dpkg -I $(IPK)
	dpkg -c $(IPK)
	ls -lh $(IPK)

ipk-inst:
	rsync $(IPK) root@${NEO}:
	ssh root@${NEO} opkg install -force-reinstall `basename $(IPK)`

full-do-%:
	cd ${TOPDIR} && . ${TOPDIR}/setup-env && bitbake -c $* ffalarms-${PV}

do-%:
	cd ${TOPDIR} && . ${TOPDIR}/setup-env && bitbake -c $* -b ${RECIPE}

rebuild: do-clean ipk-fast
reinstall: rebuild ipk-inst

EFL=~/local/src/e
tags:
	etags --extra=q ffalarms.vala *.vala $(VAPIDIR)/*.vapi \
		$(EFL)/TMP/st/elementary/src/lib/*.c $(EFL)/eina/src/lib/*.c \
		/usr/share/vala/vapi/glib-2.0.vapi /usr/share/vala/vapi/posix.vapi
