DESCRIPTION = "Finger friendly alarms"
HOMEPAGE = "http://ffalarms.projects.openmoko.org/"
LICENSE = "GPLv3"
LIC_FILES_CHKSUM = "file://COPYING;md5=f27defe1e96c2e1ecd4e0c9be8967949"
AUTHOR = "Łukasz Pankowski <lukpank@o2.pl>"
MAINTAINER = "Łukasz Pankowski <lukpank@o2.pl>"
SECTION = "x11/applications"
PRIORITY = "optional"
DEPENDS = "elementary libical"
PV = "0.4"
PR = "r0"

SRC_URI = "file://ffalarms-${PV}.tar.gz"

PACKAGES = "${PN} ${PN}-dbg ${PN}-doc"
FILES_${PN} += "${datadir}/${PN} ${datadir}/applications ${datadir}/pixmaps"

RDEPENDS = "atd alsa-utils-amixer ttf-dejavu-sans"

RSUGGESTS = "mplayer alsa-utils-aplay frameworkd"

# disable, otherwise linker reports undefined symbols
ASNEEDED = ""

do_configure() {
	oe_runmake configure
}

do_compile() {
	oe_runmake VAPIDIR=${STAGING_DATADIR}/vala/vapi
}

do_install() {
	oe_runmake install DESTDIR=${D} SYSCONFDIR=${sysconfdir}
}

pkg_postinst_${PN}() {
#!/bin/sh
/etc/init.d/dbus-1 reload
}

pkg_postrm_${PN}() {
#!/bin/sh
/etc/init.d/dbus-1 reload
}
