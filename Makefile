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

configure: .configured

.configured:
	@${VALAC} --version | awk \
		'{ if ($$1 == "Vala" && split($$2, v, ".") >= 3 && \
			(v[1] > 0 || v[2] >= 8)) { \
				exit 0 \
			} else { \
				print "error: valac >= 0.8.0 is required"; \
				exit 1 \
			} \
		}'
	pkg-config --print-errors --exists 'libical >= 0.44'
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
	rm -f ffalarms.o ffalarms data/ffalarms.edj

tags:
	etags --extra=q ffalarms.vala *.vapi

do_%:
	bitbake -c $* -b ffalarms.bb

listtasks: do_listtasks

devshell: do_devshell

ipk: clean do_clean do_package_write

ipk-install:
	scp -q ${IPK_DIR}/${IPK_BASENAME} ${NEO}:
	ssh ${NEO} opkg install ${IPK_BASENAME}

ipk-info:
	dpkg --info ${IPK_DIR}/${IPK_BASENAME}
	dpkg --contents ${IPK_DIR}/${IPK_BASENAME}
	ls -lh ${IPK_DIR}/${IPK_BASENAME}

cross-compile:
	bitbake -f -c compile -b ffalarms.bb

neo-install:
	rsync --archive data/ffalarms.edj ffalarms ${NEO}:~/tmp/

neo-run:
	ssh ${NEO} '. /etc/profile; \
		DISPLAY=:0 ~/tmp/ffalarms --edje ~/tmp/ffalarms.edj -l'

.PHONY: all configure dist install clean tags
.PHONY: listtasks devshell ipk ipk-install ipk-info
.PHONY: cross-compile neo-install neo-run
