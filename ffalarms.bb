DESCRIPTION = "Finger friendly alarms"
HOMEPAGE = "http://ffalarms.projects.openmoko.org/"
LICENSE = "GPLv3"
AUTHOR = "Łukasz Pankowski <lukpank@o2.pl>"
MAINTAINER = "Łukasz Pankowski <lukpank@o2.pl>"
SECTION = "x11/applications"
PRIORITY = "optional"
DEPENDS = "vala-native libeflvala elementary"
PV = "0.0"
PR = "r0"

SRC_URI = "file://ffalarms-${PV}.tar.gz"

FILES_${PN} += "${datadir}/${PN} ${datadir}/applications ${datadir}/pixmaps"

RDEPENDS = "elementary glib-2.0 dbus-glib atd alsa-utils-amixer \
	    alsa-utils-alsactl openmoko-alsa-scenarios ttf-dejavu-sans"

RSUGGESTS = "mplayer alsa-utils-aplay"

do_compile() {
	oe_runmake VALAC=/usr/bin/valac VAPIDIR=${STAGING_DATADIR}/vala/vapi
}

do_install() {
	oe_runmake install DESTDIR=${D}
}