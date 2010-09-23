include config.mk

FFALARMS_FILES=\
COPYING \
README \
Makefile \
config.mk \
ffalarms.bb \
ffalarms.vala \
ffalarms.vapi \
ffalarms.c \
libical.vapi \
data/ffalarms.edc \
data/alarm.sh \
data/alarm.wav \
data/ffalarms.desktop \
data/ffalarms.conf \
images/circle.png \
images/ffalarms.png \
images/ffalarms.svg

all: ffalarms data/ffalarms.edj

.PHONY: all configure dist install clean

configure: .configured

.configured:
	pkg-config --atleast-version=0.44 libical
	touch .configured

ffalarms: .configured ffalarms.o
	${CC} ${LDFLAGS} ${PKG_LDFLAGS} ffalarms.o -o $@

ffalarms.o: ffalarms.c
	${CC} -c ${CFLAGS} ${PKG_CFLAGS} $< -o $@

ffalarms.c: ffalarms.vala ffalarms.vapi libical.vapi
	${VALAC} ${VALAFLAGS} -C $< ffalarms.vapi
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
	install -d ${DESTDIR}${PREFIX}/share/doc/ffalarms
	install -m 644 README ${DESTDIR}${PREFIX}/share/doc/ffalarms
	install -d ${DESTDIR}${SYSCONFDIR}/dbus-1/system.d
	install -m 644 data/ffalarms.conf \
		${DESTDIR}${SYSCONFDIR}/dbus-1/system.d/ffalarms.conf

clean:
	rm -f *.o ffalarms armv4t/ffalarms


armv4t/ffalarms: ffalarms.c
	${CROSS_CC} ${CROSS_CFLAGS} ${CROSS_LDFLAGS} $< -o $@

.PHONY: inst run

inst: armv4t/ffalarms data/ffalarms.edj
	rsync --archive data/ffalarms.edj armv4t/ffalarms ${NEO}:~/tmp/

run: inst
	ssh ${NEO} '. /etc/profile; \
		DISPLAY=:0 ~/tmp/ffalarms --edje ~/tmp/ffalarms.edj -l'


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

listtasks: do-listtasks
devshell: do-devshell
rebuild: do-clean ipk-fast
reinstall: rebuild ipk-inst

tags:
	etags --extra=q ffalarms.vala *.vala $(VAPIDIR)/*.vapi *.vapi \
		$(EFL)/TMP/st/elementary/src/lib/*.c $(EFL)/eina/src/lib/*.c \
		/usr/share/vala/vapi/glib-2.0.vapi /usr/share/vala/vapi/posix.vapi
