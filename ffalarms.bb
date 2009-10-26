DESCRIPTION = "Finger friendly alarms"
HOMEPAGE = "http://ffalarms.projects.openmoko.org/"
LICENSE = "GPLv3"
AUTHOR = "Łukasz Pankowski <lukpank@o2.pl>"
MAINTAINER = "Łukasz Pankowski <lukpank@o2.pl>"
SECTION = "x11/applications"
PRIORITY = "optional"
DEPENDS = "elementary libical"
PV = "0.3"
PR = "r0"

SRC_URI = "file://ffalarms-${PV}.tar.gz"

PACKAGES = "${PN} ${PN}-dbg ${PN}-doc"
FILES_${PN} += "${datadir}/${PN} ${datadir}/applications ${datadir}/pixmaps"

RDEPENDS = "atd alsa-utils-amixer alsa-utils-alsactl ttf-dejavu-sans"

RSUGGESTS = "mplayer alsa-utils-aplay frameworkd openmoko-alsa-scenarios"

do_configure() {
	oe_runmake configure
}

do_compile() {
	oe_runmake VAPIDIR=${STAGING_DATADIR}/vala/vapi
}

do_install() {
	oe_runmake install DESTDIR=${D}
}
