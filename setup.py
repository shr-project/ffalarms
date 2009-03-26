# -*- coding: utf-8 -*-

from distutils.core import setup
from distutils.command.build import build as _build
from distutils.command.install import INSTALL_SCHEMES


# more reasonable on Debian and used by bitbake recipes inheriting
# from distutils (through proper --install-data option)
for v in INSTALL_SCHEMES.itervalues():
    v['data'] = '$base/share'


class build(_build):

    def run(self):
        self.spawn(['edje_cc', 'data/ffalarms.edc'])
        _build.run(self)


def main():
    setup(name='ffalarms',
          version='0.2',
          description='Finger friendly alarms',
          author='Łukasz Pankowski',
          author_email='lukpank@o2.pl',
          classifiers=[
               'Development Status :: 4 - Beta',
               'Environment :: X11 Applications',
               'Environment :: Console (Text Based)',
               'Intended Audience :: End Users/Phone UI',
               'License :: OSI Approved :: GNU General Public License (GPL)',
               'Operating System :: POSIX :: Linux',
               'Programming Language :: Python',
               'Topic :: Office/Business :: Scheduling',
               'Topic :: Desktop Environment :: Screen Savers',
               ],
          url='http://ffalarms.projects.openmoko.org/',
          packages=['ffalarms'],
          scripts=['ffalarms/ffalarms'],
          data_files=[('ffalarms', ['data/ffalarms.edj', 'data/alarm.wav']),
                      ('applications', ['data/ffalarms.desktop']),
                      ('pixmaps', ['images/ffalarms.png'])],
          cmdclass={'build': build})


if __name__ == '__main__':
    main()
