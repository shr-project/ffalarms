# ffalarms -- finger friendly alarms                 -*- coding: utf-8 -*-
# Copyright (C) 2009 Łukasz Pankowski <lukpank@o2.pl>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

"""\
usage: %(prog)s [OPTIONS]

Options:
  -e, --edje=FILE            use Edje interface from FILE
      --at-spool=DIR         use DIR as the at spool directory instead of
                             /var/spool/at
  -c, --config=FILE          use config file other than ~/.ffalarms
  -s, --set=HH:MM            set alarm at given time
      --del=TIMESTAMP        delete alarm with a given timestamp
      --kill                 kill running alarm
      --puzzle               run turn off puzzle
  -l, --list                 list scheduled alarms
  -h, --help                 display this help and exit
      --version              display version and exit
"""

__version__ = "0.2"

import sys
import os
import os.path
import re
import time
import datetime
import signal
import stat
import getopt
import ConfigParser

import evas
import ecore.evas
import edje

from kinetic_list import KineticList


EDJE_FILE='/usr/share/ffalarms/ffalarms.edj'
ATSPOOL='/var/spool/at'
CONFIG_FILE='~/.ffalarmsrc'

COMMANDS = ['alsactl', 'amixer']
ALSASTATE='/usr/share/openmoko/scenarios/stereoout.state'
MSG_TIMEOUT=5
BRIGHTNESS_FILE_2_6_28='/sys/class/backlight/gta02-bl/brightness'
BRIGHTNESS_FILE_2_6_24='/sys/class/backlight/pcf50633-bl/brightness'

MAGIC='\n##ffalarms##'
MAGIC_LEN=30
ALARM_SCRIPT = r"""#!/bin/sh
##ffalarms##

ALSASTATE=%(ALSASTATE)s
AMIXER_PID=
ORIG_ALSASTATE=`mktemp /tmp/$0.XXXXXX`
DISPLAY=:0

COPY=
for NAME in `ls x*.ffalarms.* | sed s/^x//`; do
   ps -C "$NAME" > /dev/null && cp "/tmp/$NAME."* "$ORIG_ALSASTATE" \
       && COPY=1 && break
done
[ -n "$COPY" ] || alsactl -f "$ORIG_ALSASTATE" store

SS_TIMEOUT=$(expr "$(xset q -display $DISPLAY)" : ".*timeout:[ ]*\([0-9]\+\)")
if [ -z "$SS_TIMEOUT" ]; then
    SS_TIMEOUT=0
fi

quit() {
        kill "$AMIXER_PID" $!
        wait
        alsactl -f "$ORIG_ALSASTATE" restore
        if [ "$SS_TIMEOUT" -gt 0 ]; then
            xset -display $DISPLAY s "$SS_TIMEOUT"
        fi
        rm -f "x$0" "$ORIG_ALSASTATE"
        exit
}
trap quit TERM

mv "$0" "x$0"

PIDS=`ps -C ffalarms --no-heading --format "pid"` && \
    for PID in $PIDS; do kill -USR1 $PID && break; done || \
    { DISPLAY=$DISPLAY ffalarms --puzzle & }

xset -display $DISPLAY s off
xset -display $DISPLAY s reset

alsactl -f "$ALSASTATE" restore
amixer --quiet sset PCM,0 150
for x in `seq 150 255`; do echo sset PCM,0 $x || break; sleep 1; done \
    | amixer --stdin --quiet &
AMIXER_PID=$!

i=0
while [ $i -lt %(REPEAT)s ]; do
    %(ALARM_CMD)s &
    wait $!
    i=$((i+1));
done

quit
"""

if not MAGIC in ALARM_SCRIPT[:MAGIC_LEN]:
    raise RuntimeError('Magic failed')


DEFAULT_CONFIG="""\
[alarm]
player=aplay %(file)s
file=/opt/Qtopia/sounds/alarm.wav
## repeat playing the file that many times
repeat=300

## with mplayer you can use its -loop option instead of setting repeat
## (if not given defaults to 1)
#player=mplayer -really-quiet -loop 300 %(file)s
#repeat=1

[ledclock]
24hr_format=yes
"""

ATD_CONTACT_ERR='Could not contact atd daemon, the alarm may not work'

ECORE_EVENT_SIGNAL_USER = 1


class ConfigError(ConfigParser.Error):
    pass


def alarm_handler(*a):
    raise IOError(ATD_CONTACT_ERR)
    

def set_alarm(hour, minute, alarm_cmd, repeat):
    for cmd in COMMANDS + [alarm_cmd.split(' ', 1)[0],]:
        if os.system('which %s > /dev/null' % cmd) !=0:
            raise ConfigError('command %s not found' % cmd)
    for fn in (ALSASTATE,):
        if not os.path.exists(fn):
            raise ConfigError('%s: file not found' % fn)
    trig = os.path.join(ATSPOOL, 'trigger')
    if not os.path.exists(trig) or not stat.S_ISFIFO(os.stat(trig).st_mode):
        raise IOError('Could not contact atd daemon, the alarm was not set')

    now = datetime.datetime.now()
    t = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if t < now:
        t = t + datetime.timedelta(1)
    timestamp = time.mktime(t.timetuple())

    atfile = os.path.join(ATSPOOL, '%d.ffalarms.%d' % (timestamp, os.getpid()))
    f = file(atfile, 'w')
    f.write(ALARM_SCRIPT % dict(ALARM_CMD=alarm_cmd, REPEAT=repeat,
                                ALSASTATE=ALSASTATE))
    f.close()
    os.chmod(atfile, 0755)

    signal.alarm(1)
    f = file(trig, 'a')
    try:
        if not stat.S_ISFIFO(os.fstat(f.fileno()).st_mode):
            raise IOError(ATD_CONTACT_ERR)
        f.write('\n')
    finally:
        f.close()
        signal.alarm(0)
    return t


def list_alarms():
    a = []
    for fn in os.listdir(ATSPOOL):
        if (re.match(r'\d+[.]', fn) and
            MAGIC in file(os.path.join(ATSPOOL, fn)).read(MAGIC_LEN)):
            a.append((int(fn.split('.', 1)[0]), fn))
    a.sort()
    return a


def kill_running_alarms():
    killed = False
    running_alarms = []
    atspool = os.path.abspath(ATSPOOL)
    for fn in os.listdir(ATSPOOL):
        if (re.match(r'x\d+[.]', fn) and
            MAGIC in file(os.path.join(ATSPOOL, fn)).read(MAGIC_LEN)):
            running_alarms.append(fn[1:])
    SHELL= '/bin/sh\0'
    if running_alarms:
        cmdlen = len(SHELL) + max(map(len, running_alarms)) + 1
        for pid in os.listdir('/proc'):
            if re.match(r'\d+$', pid):
                try:
                    cmd = file('/proc/%s/cmdline' % pid).read(cmdlen)
                    if cmd.startswith(SHELL):
                        cmd = cmd.split('\0', 2)
                        if (len(cmd) > 1 and cmd[1] in running_alarms and
                            os.readlink('/proc/%s/cwd' % pid) == atspool):
                            scriptfile = os.path.join(atspool, 'x' + cmd[1])
                            fd_dir = '/proc/%s/fd' % pid
                            for fd in os.listdir(fd_dir):
                                if (os.readlink(os.path.join(fd_dir, fd)) ==
                                    scriptfile):
                                    os.kill(int(pid), signal.SIGTERM)
                                    killed = True
                                    break
                except (IOError, OSError):
                    pass        # process may have been finished
    return killed


def delete_alarms(basenames):
    msg = []
    kill_running = False
    for fn in basenames:
        try:
            os.unlink(os.path.join(ATSPOOL, fn))
        except OSError, e:
            if os.path.exists(os.path.join(ATSPOOL, 'x' + fn)):
                kill_running = True
            else:
                msg.append(str(e))
    if kill_running:
        if not kill_running_alarms():
            msg.append('No alarm was running')
    if msg:
        return '\n'.join(msg)
    else:
        return None


def shquote(s):
    if "'" not in s:
        return "'%s'" % s
    else:
        return '"%s"' % re.sub(r'([$`\\"])', r'\\\1', s)


class EdjeStack(object):

    def __init__(self, ee, remove_on_empty=False):
        self.ee = ee
        self.remove_on_empty = remove_on_empty
        self.canvas = ee.evas
        self._stack = []
        ee.callback_resize = self.resize

    def __iter__(self):
        return iter(self._stack)

    def resize(self, ee):
        for edj in self._stack:
            edj.size = self.canvas.rect.size

    def push(self, edj):
        edj.size = self.canvas.rect.size
        edj.show()
        self._stack.append(edj)

    def pop(self, edj):
        edj.hide()
        if edj in self._stack:
            self._stack.remove(edj)
        if not self._stack and self.remove_on_empty:
            self.ee = None


class ClockFace(edje.Edje):

    names = ["hour-button", "minute-button"]

    def __init__(self, stack, filename, callback):
        edje.Edje.__init__(self, stack.canvas, file=filename, group='clock-group')
        self.stack = stack
        self.signal_callback_add("mouse,clicked,1", "ok-button", self.dismiss)
        self.signal_callback_add("mouse,clicked,1", "cancel-button", self.dismiss)
        self.signal_callback_add("clicked", "hour-*", self.set_hour)
        self.signal_callback_add("clicked", "minute-*", self.set_minute)
        self.callback = callback

    def start(self):
        self.hour = None
        self.minute = 0
        self.stack.push(self)

    def dismiss(self, edj, signal, source):
        if self.hour is None and source == 'ok-button':
            return
        self.stack.pop(self)
        if source == 'ok-button':
            self.callback(self.hour, self.minute)

    def set_hour(self, edj, signal, source, **ka):
        try:
            h = int(source.split('-')[1])
        except ValueError:
            return
        if h >= 0 and h < 24:
            self.hour = h

    def set_minute(self, edj, signal, source, **ka):
        try:
            h = int(source.split('-')[1])
        except ValueError:
            return
        if h >= 0 and h < 60:
            self.minute = h


class Puzzle(edje.Edje):

    def __init__(self, stack, filename, callback, *args):
        edje.Edje.__init__(self, stack.canvas, file=filename, group='puzzle-group')
        self.stack = stack
        self.callback = callback
        self.args = args
        self.started = False
        self.signal_callback_add("mouse,clicked,1", "cancel-button", self.dismiss)
        self.signal_callback_add("solved", "", self.solved)

    def start(self, label):
        self.part_text_set("label", label)
        self.signal_emit("start", "");
        self.started = True
        self.stack.push(self)

    def solved(self, *a):
        if self.started:
            self.dismiss()
            self.callback(*self.args)

    def dismiss(self, *a):
        self.started = False
        self.stack.pop(self)


class LandscapeClock(edje.Edje):

    def __init__(self, stack, filename):
        edje.Edje.__init__(self, stack.canvas, file=filename,
                           group='landscape-clock-group')
        self.stack = stack
        self.hour = self.minute = self.brightness = None
        self.signal_callback_add("mouse,clicked,1", "cancel-button", self.stop)
        self.on_key_down_add(self.key_down_cb)
        if os.path.exists(BRIGHTNESS_FILE_2_6_28):
            self.brightness_file = BRIGHTNESS_FILE_2_6_28
            self.dim_brightness = 85
        else:
            self.brightness_file = BRIGHTNESS_FILE_2_6_24
            self.dim_brightness = 21

    def start(self, h24=True):
        try:
            self.brightness = int(file(self.brightness_file).readline())
        except IOError:
            self.brightness = None
        else:
            self._set_brightness(self.dim_brightness)
        self.signal_emit(("12hr-format", "24hr-format")[bool(h24)], "")
        self.signal_emit("start", "")
        self.stack.push(self)
        self.stack.ee.fullscreen = True
        self.focus = True

    def stop(self, edc, signal, source):
        self.focus = False
        self.signal_emit("stop", "");
        self.stack.ee.fullscreen = False
        self.stack.pop(self)
        if self.brightness is not None:
            self._set_brightness(self.brightness)

    def _set_brightness(self, value):
        f = file(self.brightness_file, 'w')
        f.write('%d\n' % value)
        f.close()

    def key_down_cb(self, edj, event):
        if event.key == "q":
            self.stop(None, None, None)


class Config(object):

    def __init__(self):
        self.cfg = self.mtime = None

    def _read_config(self):
        fn = os.path.expanduser(CONFIG_FILE)
        try:
            mtime = os.stat(fn).st_mtime
        except OSError:
            if not os.path.exists(fn):
                # default example which has some chance to work
                f = file(fn, 'w')
                f.write(DEFAULT_CONFIG)
                f.close()
                mtime = os.stat(fn).st_mtime
        if mtime == self.mtime:
            return
        cfg = ConfigParser.SafeConfigParser()
        cfg.add_section('ledclock')
        cfg.set('ledclock', '24hr_format', 'yes')
        cfg.add_section('alarm')
        cfg.set('alarm', 'repeat', '1')
        cfg.read([fn])
        self.cfg = cfg
        self.mtime = mtime

    @property
    def alarm_cmd(self):
        self._read_config()
        try:
            alarm_file = os.path.expanduser(self.cfg.get('alarm', 'file'))
            alarm_cmd = self.cfg.get(
                'alarm', 'player', vars={'file': shquote(alarm_file)})
            if not os.path.exists(alarm_file):
                raise ConfigError('%s: given alarm file does not exist' %
                                  alarm_file)
        except ConfigParser.Error, e:
            raise ConfigError('%s: %s' % (CONFIG_FILE, e))
        return alarm_cmd

    @property
    def alarm_repeat(self):
        self._read_config()
        try:
            return self.cfg.getint('alarm', 'repeat')
        except (ConfigParser.Error, ValueError), e:
            raise ConfigError('%s: repeat: %s' % (CONFIG_FILE, e))

    @property
    def time_24hr_format(self):
        self._read_config()
        try:
            return self.cfg.getboolean('ledclock', '24hr_format')
        except ValueError, e:
            raise ConfigError('%s: 24hr_format: %s' % (CONFIG_FILE, e))


class AlarmList(edje.Edje):

    def __init__(self, stack, filename):
        edje.Edje.__init__(self, stack.canvas, file=filename, group='main-group')
        self.stack = stack
        self.filename = filename
        self.cfg = Config()
        self.signal_callback_add("mouse,clicked,1", "new-alarm-button", self.new_alarm)
        self.signal_callback_add("mouse,clicked,1", "delete-alarm-button",
                                 self.delete_alarm_after_puzzle)
        self.signal_callback_add("mouse,clicked,1", "show-clock-button",
                                 self.show_clock)
        self.signal_callback_add("SIGUSR1", "", self.turn_off_puzzle)
        self.list = KineticList(self.stack.canvas, file=filename, item_height=85,
                                with_thumbnails=False)
        self.signal_callback_add("open", "*", self.new_alarm)
        self.msg_timer = None
        self.msg = edje.Edje(self.stack.canvas, file=filename, group='message-group')
        self.update_list()
        self.part_swallow('list', self.list)
        self.msg.signal_callback_add("mouse,clicked,1", "cancel-button", self.message_hide)
        self.clock = LandscapeClock(self.stack, filename)
        self._dirty_add_sigusr1_handler()

    def _dirty_add_sigusr1_handler(self):
        class SigUsr1Event(ecore.Event):
            def __init__(_self):
                self.signal_emit("SIGUSR1", "")
        ecore.c_ecore._event_mapping_register(ECORE_EVENT_SIGNAL_USER, SigUsr1Event)
        self._dirty_update_sigusr1_handler()

    def _dirty_update_sigusr1_handler(self):
        ecore.EventHandler(ECORE_EVENT_SIGNAL_USER, lambda *a: True)

    def message(self, msg, timeout=None, title=None):
        if self.msg_timer is not None:
            self.msg_timer.stop()
        self.msg.part_text_set("message", msg)
        self.msg.part_text_set("title", title or "")
        self.stack.push(self.msg)
        self.msg.raise_()
        if timeout is not None:
            self.msg_timer = ecore.timer_add(timeout, self.message_hide)

    def message_hide(self, *ignore):
        self.stack.pop(self.msg)
        if self.msg_timer is not None:
            self.msg_timer.stop()

    def update_list(self):
        k = self.list
        k.elements = []
        k.selection = [] # XXX?
        k.freeze()
        try:
            lst = list_alarms()
        except OSError, e:
            self.message(str(e), title="Unable to update list of alarms")
            return
        for t, fn in lst:
            name = time.asctime(time.localtime(t))
            k.row_add(name, t, fn)
        k.thaw()
        # XXX dirty hack to redraw after list change
        h = k.h
        k.resize(k.w, h - 1)
        k.resize(k.w, h + 1)

    def turn_off_puzzle(self, *a):
        self._dirty_update_sigusr1_handler()
        if not self.clock in self.stack:
            puzzle = Puzzle(self.stack, self.filename, self.delete_alarm, [])
            puzzle.start("Confirm turning off the running alarm")
        self.stack.ee.raise_()

    def delete_alarm_after_puzzle(self, edj, signal, source):
        puzzle = Puzzle(self.stack, self.filename, self.delete_alarm,
                        list(self.list.selection))
        n = len(self.list.selection)
        if n == 1:
            label = "Confirm removing of the selected alarm"
        elif n > 1:
            label = "Confirm removing of %s selected alarms" % n
        else:
            label = "Confirm turning off the running alarm";
        puzzle.start(label)

    def delete_alarm(self, selection):
        if selection:
            msg = delete_alarms([row[2] for row in selection])
        else:
            kill_running_alarms()
            msg = None
        if msg is not None:
            self.message(msg, title='Problems while deleting alarms')
        self.update_list()

    def new_alarm(self, edj, signal, source):
        clock = ClockFace(self.stack, self.filename, self.add_alarm)
        clock.start()

    def add_alarm(self, hour, minute):
        try:
            set_alarm(hour, minute, self.cfg.alarm_cmd, self.cfg.alarm_repeat)
        except Exception, e:
            if isinstance(e, (ConfigParser.Error, IOError)):
                msg = str(e)
            else:
                msg = '%s: %s' % (e.__class__.__name__, e)
            self.message(msg, title="Unable to add alarm")
        else:
            self.update_list()

    def show_clock(self, edj, signal, source):
        self.clock.raise_()
        try:
            self.clock.start(self.cfg.time_24hr_format)
        except ConfigParser.Error, e:
            self.message(str(e))


def main():
    global ATSPOOL, EDJE_FILE, CONFIG_FILE
    prog = os.path.basename(sys.argv[0])
    try:
        opts, args = getopt.getopt(
            sys.argv[1:], 'e:c:s:lh', ['edje=', 'at-spool=', 'config=',
                                       'list', 'set=', 'del=', 'kill',
                                       'puzzle', 'version', 'help'])
    except getopt.GetoptError, e:
        sys.exit('%s: %s' % (prog, e))
    actions = []
    show_list = puzzle = False
    for o, a in opts:
        if o in ['-e', '--edje']:
            EDJE_FILE = a
        elif o == '--at-spool':
            ATSPOOL = a
        elif o in ['-c', '--config']:
            CONFIG_FILE = a
        elif o in ['-l', '--list']:
            show_list = True
        elif o in ['-s', '--set', '--del', '--kill']:
            actions.append((o, a))
        elif o == '--puzzle':
            puzzle = True
        elif o in ['-h', '--help']:
            print __doc__ % dict(prog=prog)
            sys.exit()
        elif o == '--version':
            print 'ffalarms-%s' % __version__
            sys.exit()
        else:
            raise RuntimeError('%s: unhandled option: %s' % (prog, o))
    signal.signal(signal.SIGALRM, alarm_handler)
    if actions:
        cfg = None
        for o, a in actions:
            if o in ['-s', '--set']:
                try:
                    hour, minute = map(int, a.split(':', 1))
                except ValueError:
                    sys.exit('%s: argument of %s must be of the form HH:MM'
                             % (prog, o))
                try:
                    if cfg is None:
                        cfg = Config()
                    set_alarm(hour, minute, cfg.alarm_cmd, cfg.alarm_repeat)
                except ConfigParser.Error, e:
                    sys.exit('%s: %s' % (prog, e))
            elif o == '--del':
                try:
                    a = int(a)
                except ValueError:
                    sys.exit('%s: argument of %s must be integer' % (prog, o))
                basenames = [fn for t, fn in list_alarms() if t == a]
                if basenames:
                    msg = delete_alarms(basenames)
                    if msg is not None:
                        sys.stderr('%s' % msg)
                else:
                    sys.exit('%s: no alarm shedulued at timestamp %d' %
                             (prog, a))
            elif o == '--kill':
                if not kill_running_alarms():
                    sys.stderr.write('No alarm was running\n')
    if show_list:
        for t, fn in list_alarms():
            print '%11d  %s' % (t, time.asctime(time.localtime(t)))
    if actions or show_list:
        sys.exit()

    if ecore.evas.engine_type_supported_get('software_x11_16'):
        engine = ecore.evas.SoftwareX11_16
    else:
        engine = ecore.evas.SoftwareX11

    ee = engine(w=480, h=640)
    ee.name_class = ('FFAlarms', 'FFAlarms')
    ee.title = 'Alarms'

    stack = EdjeStack(ee)
    edj = AlarmList(stack, EDJE_FILE)
    stack.push(edj)
    if puzzle:
        edj.turn_off_puzzle()

    ee.callback_delete_request = lambda *a: ecore.main_loop_quit()
    ee.show()

    ecore.main_loop_begin()


if __name__ == '__main__':
    main()
