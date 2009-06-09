DESCRIPTION = "Finger friendly alarms"
HOMEPAGE = "http://ffalarms.projects.openmoko.org/"
LICENSE = "GPLv3"
AUTHOR = "Łukasz Pankowski <lukpank@o2.pl>"
MAINTAINER = "Łukasz Pankowski <lukpank@o2.pl>"
SECTION = "x11/applications"
PRIORITY = "optional"
DEPENDS = "edje-native python-native"
PV = "0.2.2"
PR = "r0"

# Pure Python plus Edje interface
PACKAGE_ARCH = "all"

SRC_URI = "file://ffalarms-${PV}.tar.gz"

inherit distutils

FILES_${PN} += "${datadir}/${PN} ${datadir}/applications/ffalarms.desktop ${datadir}/pixmaps"

RDEPENDS += "python-re python-datetime python-edje python-ecore \
             atd alsa-utils-amixer alsa-utils-alsactl openmoko-alsa-scenarios \
             ttf-dejavu-sans"

RSUGGESTS += "mplayer alsa-utils-aplay"
