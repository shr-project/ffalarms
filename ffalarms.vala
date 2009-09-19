/* ffalarms -- finger friendly alarms
 * Copyright (C) 2009 Łukasz Pankowski <lukpank@o2.pl>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

using Elm;
using Edje;
using Ecore;
using Posix;

public const string VERSION = "0.2.4";
public const string EDJE_FILE = "/usr/share/ffalarms/ffalarms.edj";
public const string ALARM_SH = "/usr/share/ffalarms/alarm.sh";
public const string ATD_CONTACT_ERR =
    "Could not contact atd daemon, the alarm may not work";
public const string COMMANDS = "alsactl amixer";
public const string ALSASTATE =
    "/usr/share/openmoko/scenarios/stereoout.state";


public errordomain MyError {
    CONFIG, ERR;
}


void die(string msg)
{
    printerr("%s: %s\n", Environment.get_prgname(), msg);
    Posix.exit(1);
}


string lstrip(string s)
{
    return new Regex("^\\s+").replace(s, s.length, 0, "");
}


string expand_home(string s)
{
    if (new Regex("^~/").match(s))
	return Path.build_filename(Environment.get_home_dir(), s.substring(2));
    else
	return s;
}


time_t next_hm(int hour, int minute)
{
    var now = time_t();
    var t = Time.local(now) { hour=hour, minute=minute, second=0 };
    var timestamp = t.mktime();
    if (timestamp <= now) {
	t.day += 1;
	timestamp = t.mktime(); // also normalizes Time
    }
    if (t.hour != hour) {
	t.hour = hour;
	timestamp = t.mktime();
    }
    return timestamp;
}


void set_alarm(time_t timestamp, string alarm_cmd, int repeat,
	       string at_spool) throws MyError, FileError
{
    string alarm_sh, player = lstrip(alarm_cmd).split(" ", 2)[0];
    Posix.Stat st;

    foreach (var cmd in "%s %s".printf(COMMANDS, player).split(" "))
	if (Environment.find_program_in_path(cmd) == null)
	    throw new MyError.CONFIG("command %s not found".printf(cmd));
    if (stat(ALSASTATE, out st) != 0)
	throw new MyError.CONFIG("%s: file not found".printf(ALSASTATE));
    var trig = Path.build_filename(at_spool, "trigger");
    if (stat(trig, out st) != 0 || !S_ISFIFO(st.st_mode))
	throw new MyError.CONFIG(
	    "Could not contact atd daemon, the alarm was not set");
    var filename = Path.build_filename(
	at_spool,"%ld.ffalarms.%ld".printf(timestamp, getpid()));
    FileUtils.get_contents(ALARM_SH, out alarm_sh);
    FileUtils.set_contents(
	filename, alarm_sh.printf(Shell.quote(ALSASTATE),
				  repeat, Shell.quote(alarm_cmd)));
    FileUtils.chmod(filename, 0755);
    int fd = open(trig, O_WRONLY | O_NONBLOCK);
    bool atd_error = (fd == -1 || fstat(fd, out st) != 0 ||
		      !S_ISFIFO(st.st_mode) || write(fd, "\n", 1) != 1);
    if (fd != -1)
	close(fd);
    if (atd_error)
	throw new MyError.CONFIG(ATD_CONTACT_ERR);
}



struct AlarmInfo
{
    public time_t timestamp;
    public string filename;
    public string localtime;
}


public GLib.List<AlarmInfo?> list_alarms(string at_spool) throws MyError, RegexError
{
    var re = new Regex("^[0-9]+[.]ffalarms[.]");
    var dir = opendir(at_spool);
    if (dir == null)
	throw new MyError.CONFIG("Could not list spool directory: %s",
				 at_spool);
    var lst = new GLib.List<AlarmInfo?>();
    unowned DirEnt de;
    while ((de = readdir(dir)) != null) {
	unowned string s = (string) de.d_name;
	time_t t = s.to_int();
	if (re.match(s))
	    lst.append(AlarmInfo() { timestamp=t, filename=s,
			localtime=Time.local(t).format("%a %b %d %X %Y")});
    }
    lst.sort((aa, bb) => {
	    time_t a = ((AlarmInfo *) aa)->timestamp;
	    time_t b = ((AlarmInfo *) bb)->timestamp;
	    return (a < b) ? -1 : (a == b) ? 0 : 1;
	});
    return lst;
}


// Return nth tok (indices start with 0) where tokens are delimitied
// by any number of spaces or null if not found

weak string? nth_token(char[] buf, int nth)
{
    bool prev_tok = false, tok;
    int n = -1;

    for (char *p = buf; *p != '\0'; p++) {
	tok = *p != ' ';
	if (tok != prev_tok) {
	    prev_tok = tok;
	    if (tok && ++n == nth)
		    return (string?) p;
	}
    }
    return null;
}


bool kill_running_alarms(string at_spool)
{
    Regex alarm_cmd;
    char[] buf = new char[100];
    bool result = false;
    MatchInfo m;
    Posix.Stat st;

    FileStream? f = popen("ps -ef", "r");
    if (f == null) {
	error("could not exec ps");
	return false;
    }
    try {
	alarm_cmd = new Regex("^/bin/sh ([0-9]+[.]ffalarms[.][0-9]+)");
    } catch (RegexError e) {
	assert_not_reached();
    }
    while (getline(ref buf, f) != -1) {
	if (alarm_cmd.match(nth_token(buf, 7), 0, out m)) {
	    int alarm_pid = nth_token(buf, 1).to_int();
	    if (stat(Path.build_filename(
			 at_spool, "x%s.%d".printf(
			     m.fetch(1), alarm_pid)), out st) == 0)
		if (kill(alarm_pid, SIGTERM) == 0)
		    result = true;
	}
    }
    return result;
}


void delete_alarm(AlarmInfo a, string at_spool) throws MyError
{
    Posix.Stat st;

    var filename = Path.build_filename(at_spool, a.filename);
    if (unlink(filename) != 0) {
	if (Posix.errno == ENOENT)
	    throw new MyError.ERR(
		"%s: %s\n".printf(filename, Posix.strerror(Posix.errno)));
	if (stat(Path.build_filename(at_spool, "x%s".printf(a.filename)),
		 out st) == 0)
	    if (! kill_running_alarms(at_spool))
		throw new MyError.ERR("No alarm was running");
    }
}


public void display_alarms_list(string at_spool) throws MyError
{
    foreach (unowned AlarmInfo? a in list_alarms(at_spool))
	stdout.printf("%11ld  %s\n", a.timestamp, a.localtime);
}


class AddAlarm
{
    Win win;
    Bg bg;
    Box bx;
    Buttons btns;
    Layout lt;
    int hour = -1;
    int minute = 0;
    public delegate void SetAlarm(int hour, int minute);
    SetAlarm set_alarm;

    public void show(Win parent, string edje_file, SetAlarm set_alarm)
    {
	// NOTE do not use parent to avoid window decorations
	win = new Win(null, "add", WinType.BASIC);
	win.title_set("Add alarm");
	win.smart_callback_add("delete-request", () => { this.win = null; });
	this.set_alarm = set_alarm;

	bg = new Bg(win);
	bg.size_hint_weight_set(1.0, 1.0);
	win.resize_object_add(bg);
	bg.show();

	bx = new Box(win);
	bx.size_hint_weight_set(1.0, 1.0);
	win.resize_object_add(bx);
	bx.show();

	lt = new Layout(win);
	lt.file_set(edje_file, "clock-group");
	lt.size_hint_weight_set(1.0, 1.0);
	lt.size_hint_align_set(-1.0, -1.0);
	bx.pack_end(lt);
	lt.show();

	btns = new Buttons(win);
	btns.add("Add", this.add);
	btns.add("Close", this.close);
	bx.pack_end(btns.box);

	weak Edje.Object edje = (Edje.Object) lt.edje_get();
	edje.signal_callback_add("clicked", "hour-*", this.set_hour);
	edje.signal_callback_add("clicked", "minute-*", this.set_minute);

	win.resize(480, 640);
	win.show();
    }

    void set_hour(Edje.Object obj, string sig, string src)
    {
	int h = src.split("-")[1].to_int();
	if (h >= 0 && h < 24)
	    this.hour = h;
    }

    void set_minute(Edje.Object obj, string sig, string src)
    {
	int m = src.split("-")[1].to_int();
	if (m >= 0 && m < 60)
	    this.minute = m;
    }

    public void add()
    {
	if (this.hour != -1) {
	    this.set_alarm(this.hour, this.minute);
	    close();
	}
    }

    public void close()
    {
	win = null;
    }
}


class Puzzle
{
    Win win;
    Bg bg;
    Button[] b = new Button[4];
    Frame fr;
    Label lb;
    Layout lt;
    public delegate void DeleteAlarms(Eina.List<weak ListItem> sel);
    DeleteAlarms delete_alarms;
    weak Eina.List<weak ListItem> sel;
    public bool exit_when_closed;

    public void show(Win? parent, string edje_file,
		     string label, DeleteAlarms delete_alarms,
		     Eina.List<weak ListItem>? sel)
    {
	this.delete_alarms = delete_alarms;
	this.sel = sel;
	win = new Win(null, "puzzle", WinType.BASIC);
	win.title_set("Delete alarm");
	win.smart_callback_add("delete-request", this.close);

	bg = new Bg(win);
	bg.size_hint_weight_set(1.0, 1.0);
	win.resize_object_add(bg);
	bg.show();

	lb = new Label(win);
	lb.label_set("<b>%s<b>".printf(label));
	lb.show();

	fr = new Frame(win);
	fr.style_set("outdent_top");
	fr.content_set(lb);
	fr.show();

	lt = new Layout(win);
	lt.file_set(edje_file, "puzzle-group");
	lt.size_hint_weight_set(1.0, 1.0);
	win.resize_object_add(lt);
	lt.show();

	weak Edje.Object edje = (Edje.Object) lt.edje_get();
	edje.signal_callback_add("solved", "", this.solved);
	edje.part_swallow("frame", fr);
	for (int i = 0; i < 4; i++)
	    edje.part_swallow("%d-button".printf(i), b[i] = new Button(win));
	edje.signal_emit("start", "");

	win.resize(480, 640);
	win.show();
    }

    void solved()
    {
	delete_alarms(sel);
	close();
    }

    public void close()
    {
	win = null;
	if (exit_when_closed)
	    Elm.exit();
    }
}


class Clock
{
    Win win;
    Layout lt;
    int brightness = -1;
    weak Config cfg;

    public Clock(Config cfg)
    {
	this.cfg = cfg;
    }

    public void show(Win parent, string edje_file)
    {
	// NOTE do not use parent for the fullscreen to work
	win = new Win(null, "clock", WinType.BASIC);
	win.title_set("Clock");
	win.smart_callback_add("delete-request", this.close);

	lt = new Layout(win);
	lt.file_set(edje_file, "landscape-clock-group");
	lt.size_hint_weight_set(1.0, 1.0);
	win.resize_object_add(lt);
	lt.show();

	weak Edje.Object edje = (Edje.Object) lt.edje_get();
	if (cfg.led_color != null) {
	    weak int[] c = cfg.led_color;
	    edje.color_class_set("led-color", c[0], c[1], c[2], 255,
				 0, 0, 0, 0, 0, 0, 0, 0);
	}
	edje.signal_callback_add("mouse,clicked,1", "cancel-button", this.close);
	edje.signal_emit((cfg.time_24hr_format) ?
			 "24hr-format" : "12hr-format", "");
	edje.signal_emit("start", "");

	win.resize(480, 640);
	win.show();
	win.fullscreen_set(true);
	set_brightness(cfg.brightness);
    }

    public void close()
    {
	set_brightness(-1);
	win = null;
    }

    void set_brightness(int value)
    {
	if (value == -1 && brightness == -1)
	    return;
	try {
 	    var bus = DBus.Bus.get(DBus.BusType.SYSTEM);
	    dynamic DBus.Object o = bus.get_object(
		"org.freesmartphone.odeviced", "/org/freesmartphone/Device/Display/0",
		"org.freesmartphone.Device.Display");
	    if (brightness == -1)
		brightness = o.GetBrightness();
	    o.SetBrightness((value != -1) ? value : brightness);
	    if (value == -1)
		brightness = -1;
	} catch (DBus.Error e) {
		debug("D-Bus error: %s", e.message);
	}
    }
}


class Alarms
{
    public Elm.List lst;
    HashTable<ListItem,unowned AlarmInfo?> items;
    GLib.List<AlarmInfo?> alarms;
    string at_spool;

    public Alarms(Elm.Object? parent, string at_spool)
    {
	lst = new Elm.List(parent);
	this.at_spool = at_spool;
    }

    public void update() throws MyError
    {
	alarms = list_alarms(at_spool);
	items = new HashTable<ListItem,unowned AlarmInfo?>.full(null, null, null, null);
	// NOTE only "unowned StructType?" avoids any type of copying
	// just uses pointer
	foreach (unowned AlarmInfo? a in alarms)
	    items.insert(lst.append(a.localtime, null, null, null), a);
	lst.multi_select_set(true);
	lst.go();
    }

    public void delete_alarms(Eina.List<ListItem>? sel)
    {
	if (sel == null) {
	    kill_running_alarms(at_spool);
	    return;
	}
	weak ListItem item = null;
	Eina.Iterator<weak ListItem> iter = sel.iterator_new();
	while (iter.next(ref item))
	    try {
		delete_alarm(items.lookup(item), at_spool);
	    } catch (MyError e) {
		GLib.message("delete_alarm: %s", e.message);
	    }
	// XXX would be nice to work from here:
	// update();
    }

    public unowned Eina.List<weak ListItem> get_selection()
    {
 	return lst.selected_items_get();
    }
}


class Message
{
    Win w;
    Label tt;
    Box bx;
    Box hbx;
    Button bt;
    Anchorblock ab;
    int fr_num = 0;
    Frame[] fr = new Frame[6];

    unowned Frame frame(string style)
    {
	(fr[fr_num] = new Frame(w)).style_set(style);
	return fr[fr_num++];
    }

    public Message(Win win, string msg, string? title=null)
    {
	w = win.inwin_add();
	bx = new Box(w);
	bx.scale_set(1.0);
	bx.pack_end(frame("pad_small"));
	if (title != null) {
	    tt = new Label(w);
	    tt.label_set("<b>%s</b>".printf(title));
	    tt.show();
	    bx.pack_end(tt);
	    bx.pack_end(frame("pad_medium"));
	}
	hbx = new Box(w);
	hbx.horizontal_set(true);
	hbx.size_hint_align_set(-1.0, 0.5); // fill horizontally
 	hbx.pack_end(frame("pad_small"));
	ab = new Anchorblock(w);
	ab.text_set(msg.replace("<", "&lt;").replace("\n", "<br>"));
	ab.size_hint_align_set(-1.0, 0.5); // fill horizontally
	ab.size_hint_weight_set(1.0, 1.0); // expand
	ab.show();
 	hbx.pack_end(ab);
 	hbx.pack_end(frame("pad_small"));
	hbx.show();
	bx.pack_end(hbx);
	bx.pack_end(frame("pad_medium"));
	bt = new Button(w);
	bt.label_set("  Ok  ");
	bt.scale_set(1.5);
	bt.smart_callback_add("clicked", () => { this.w = null; });
	bx.pack_end(bt);
	bx.pack_end(frame("pad_small"));
	w.inwin_content_set(bx);
	w.inwin_style_set("minimal_vertical");
	bt.show();
	w.inwin_activate();
    }
}


class Buttons
{
    public Box box;
    Button[] buttons = new Button[3];
    int idx = 0;
    weak Elm.Object parent;

    public Buttons(Elm.Object parent)
    {
	box = new Box(parent);
	box.size_hint_weight_set(1.0, 0.0);
	box.size_hint_align_set(-1.0, -1.0);
	box.horizontal_set(true);
	box.homogenous_set(true);
	box.show();
	this.parent = parent;
    }

    public void add(string label, Evas.SmartCallback cb)
    {
	unowned Button b;

	b = buttons[idx++] = new Button(parent);
	b.label_set(label);
	b.smart_callback_add("clicked", cb);
	b.size_hint_weight_set(1.0, 0.0);
	b.size_hint_align_set(-1.0, -1.0);
	box.pack_end(b);
	b.show();
    }
}


class MainWin
{
    Win win;
    Bg bg;
    Box bx;
    Buttons btns;
    Frame fr;
    Clock clock;
    AddAlarm aa;
    Puzzle puz;
    Alarms alarms;
    Message msg;
    Config cfg;
    string edje_file;
    string at_spool;
    string config_file;

    public MainWin(string edje_file, string at_spool, string? config_file)
    {
	this.edje_file = edje_file;
	this.at_spool = at_spool;
	this.config_file = config_file;
    }

    public void show()
    {
	win = new Win(null, "main", WinType.BASIC);
	win.title_set("Alarms");
	win.smart_callback_add("delete-request", Elm.exit);

	bg = new Bg(win);
	bg.size_hint_weight_set(1.0, 1.0);
	bg.show();
	win.resize_object_add(bg);

	bx = new Box(win);
	bx.size_hint_weight_set(1.0, 1.0);
	win.resize_object_add(bx);
	bx.show();

	fr = new Frame(win);
	fr.size_hint_weight_set(0.0, 1.0);
	fr.size_hint_align_set(-1.0, -1.0);
	fr.style_set("outdent_top");
       	bx.pack_end(fr);
	fr.show();

	btns = new Buttons(win);
	btns.add("Add", () => { (aa = new AddAlarm()).show(win, edje_file,
	 						   set_alarm_); });
	btns.add("Delete", start_delete_puzzle);
	btns.add("Clock", () => { (clock = new Clock(cfg)).show(win,
	 							edje_file); });
	bx.pack_end(btns.box);

	update_alarms();
	var black_hole = new HashTable<int, EventHandler>.full(null, null,
							       null, null);
	black_hole.insert(0, new EventHandler(EventType.SIGNAL_USER,
					      sig_user));

	win.resize(480, 640);
	win.show();

	cfg = new Config();
	try {
	    cfg.load_from_file(config_file);
	} catch (MyError.CONFIG e) {
	    message("%s\nDefault configuration will be used."
		    .printf(e.message), "Error reading config file");
	    cfg.use_defaults();
	}
    }

    bool sig_user(int type, void *event)
    {
	update_alarms();
	return false;
    }

    void set_alarm_(int hour, int minute)
    {
	string msg = null;
	try {
	    set_alarm(next_hm(hour, minute), cfg.alarm_cmd(), cfg.repeat,
		      at_spool);
	} catch (MyError e) {
	    msg = e.message;
	} catch (FileError e) {
	    msg = e.message;
	}
	if (msg == null)
	    update_alarms();
	else
	    message(msg, "Unable to add alarm");
    }

    public void show_delete_puzzle()
    {
	puz = new Puzzle();
	puz.exit_when_closed = true;
	puz.show(null, edje_file, "Confirm turning off the running alarm",
		 () => { kill_running_alarms(at_spool); }, null);
    }

    void start_delete_puzzle()
    {
	puz = new Puzzle();
	unowned Eina.List<weak ListItem> sel = alarms.get_selection();
	uint n = sel.count();
	string label;
        if (n == 1)
            label = "Confirm removing of the selected alarm";
        else if (n > 1)
            label = "Confirm removing of %u selected alarms".printf(n);
        else
            label = "Confirm turning off the running alarm";
	puz.show(win, edje_file, label, delete_alarms, sel);
    }

    void message(string msg, string? title=null)
    {
	this.msg = new Message(win, msg, title);
    }

    // hack: I recreate all the list as removing from the list
    // segfaults so the list owns the items (XXX weak?)
    // XXX probably free_function="" try

    public void delete_alarms(Eina.List<ListItem>? sel)
    {
	alarms.delete_alarms(sel);
	// XXX dirty update
	update_alarms();
    }

    public void update_alarms()
    {
	alarms = new Alarms(win, at_spool);
	try {
	    alarms.update();
	} catch (MyError e) {
	    message(e.message);
	}
	alarms.lst.show();
	fr.content_set(alarms.lst);
    }
}


class Config
{
    KeyFile ini;
    public const string DEFAULT_CONFIG = "~/.ffalarmsrc";
    public const int BRIGHTNESS = 33;
    string player;
    string alarm_file;
    public int repeat;
    public int brightness;
    public bool time_24hr_format;
    public int[] led_color;

    public Config()
    {
	use_defaults();
    }

    public void use_defaults()
    {
	player = "aplay -q %(file)s";
	alarm_file = "/usr/share/ffalarms/alarm.wav";
	repeat = 500;
	time_24hr_format = true;
	brightness = BRIGHTNESS;
    }

    public void load_from_file(string? filename) throws MyError
    {
	ini = new KeyFile();
	try {
	    ini.load_from_file(
		(filename != null) ? filename : expand_home(DEFAULT_CONFIG),
		KeyFileFlags.NONE);
	    ini.set_list_separator(',');
	    alarm_file = expand_home(ini.get_value("alarm", "file"));
	    player = ini.get_value("alarm", "player");
	    repeat = (ini.has_key("alarm", "repeat")) ?
		ini.get_integer("alarm", "repeat") : 1;
	    time_24hr_format = (ini.has_key("ledclock", "24hr_format")) ?
		ini.get_boolean("ledclock", "24hr_format") : false;
	    brightness = (ini.has_key("ledclock", "brightness")) ?
		ini.get_integer("ledclock", "brightness") : BRIGHTNESS;
	    if (ini.has_key("ledclock", "color"))
		led_color = get_color("ledclock", "color");
	} catch (KeyFileError e) {
	    throw new MyError.CONFIG(e.message);
	} catch (FileError e) {
	    if (filename != null || ! (e is FileError.NOENT))
		throw new MyError.CONFIG("Configuration file error: %s"
					 .printf(e.message));
	    else
		use_defaults();
	}
    }

    int[] get_color(string group, string key) throws MyError
    {
	int[] color;
	try {
	    color = ini.get_integer_list(group, key);
	} catch (KeyFileError e) {
	    color = null;
	}
	if (color == null || color.length != 3 ||
	    color[0] < 0 || color[0] > 255 ||
	    color[1] < 0 || color[1] > 255 ||
	    color[2] < 0 || color[2] > 255)
	    throw new MyError.CONFIG("Value \"%s\" could not be interpreted as a color: should match \"0-255, 0-255, 0-255\"."
				     .printf(ini.get_value(group, key)));
	return color;
    }

    // could be a property if Vala properties would support throws
    public string alarm_cmd() throws MyError {
	if (! FileUtils.test(alarm_file, FileTest.IS_REGULAR)) {
	    throw new MyError.CONFIG("%s: Alarm file does not exist"
				     .printf(alarm_file));
	}
	return player.replace("%(file)s", Shell.quote(alarm_file));
    }
}


class Alarm {
    const string[] AMIXER_CMD = {"amixer", "--stdin", "--quiet", null};
    const string SET_PCM_FMT = "sset PCM %g%%\n";

    string[] play_argv;
    int cnt;
    double volume = 60;
    FileStream mixer;
    GLib.MainLoop ml;
    static pid_t player_pid = 0;

    public Alarm(string play_cmd, int cnt) {
	this.cnt = cnt;
	Shell.parse_argv(play_cmd, out play_argv);
    }

    public void run()
    {
	int stdin;

	ml = new GLib.MainLoop(null, false);
	request_resources();
	try {
	    Process.spawn_async_with_pipes(
		null, AMIXER_CMD, null, SpawnFlags.SEARCH_PATH,
		null, null, out stdin, null, null);
	    mixer = FileStream.fdopen(stdin, "w");
	    mixer.printf(SET_PCM_FMT, volume);
	    mixer.flush();
	    Timeout.add(1000, inc_volume);
	} catch (SpawnError e) {
	    // we continue with default volume
	    GLib.message("Alarm.run: %s", e.message);
	}
	signal(SIGTERM, sigterm);
	alarm_loop();
	ml.run();
    }

    void request_resources()
    {
	try {
	    var bus = DBus.Bus.get(DBus.BusType.SYSTEM);
	    dynamic DBus.Object usage = bus.get_object(
		"org.freesmartphone.ousaged", "/org/freesmartphone/Usage",
		"org.freesmartphone.Usage");
	    usage.RequestResource("CPU", async_result);
	    usage.RequestResource("Display", async_result);
	} catch (DBus.Error e) {
		debug("Could not connect to dbus or other dbus error");
	}
    }

    void async_result(GLib.Error e) {
	if (e != null)
	    stderr.printf("end call error: %s\n", e.message);
    }

    static void sigterm(int signal)
    {
	if (player_pid != 0)
	    kill(player_pid, SIGTERM);
	Posix.exit(1);
    }

    bool inc_volume()
    {
	volume += 0.38;
	mixer.printf(SET_PCM_FMT, volume);
	mixer.flush();
	return volume < 100;
    }

    void alarm_loop(Pid p = 0, int status = 0)
    {
	Pid pid;

	if (cnt-- == 0) {
	    ml.quit();
	    return;
	}
	if (p != (Pid) 0)
	    usleep(300000);
	signal(SIGTERM, SIG_IGN);
	try {
	    Process.spawn_async(
		null, play_argv, null,
		SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD,
		null, out pid);
	} catch (SpawnError e) {
	    die(e.message);
	}
	player_pid = (pid_t) pid;
	signal(SIGTERM, sigterm);
	ChildWatch.add(pid, alarm_loop);
    }
}


class Main {
    static string edje_file = EDJE_FILE;
    static string at_spool = "/var/spool/at";
    static string config_file = null;
    static bool version = false;
    static bool list = false;
    static bool kill = false;
    static bool puzzle = false;
    static string play_cmd = null;

    [CCode (array_length = false, array_null_terminated = true)]
    static string[] alarms = null;
    [CCode (array_length = false, array_null_terminated = true)]
    static string[] deletes;

    const OptionEntry[] options = {
	{ "edje",  'e', 0, OptionArg.FILENAME, ref edje_file,
	  "use Edje interface from FILE", "FILE" },
	{ "at-spool", 0, 0, OptionArg.FILENAME, ref at_spool,
	  "use DIR as the at spool directory instead of", "DIR" },
	{ "config", 'c', 0, OptionArg.FILENAME, ref config_file,
	  "use config file other than ~/.ffalarmsrc", "FILE" },
	{ "set", 's', 0, OptionArg.STRING_ARRAY, ref alarms,
	  "set alarm at given time", "HH:MM|now" },
	{ "del", 0, 0, OptionArg.STRING_ARRAY, ref deletes,
	  "delete alarm with a given timestamp", "TIMESTAMP" },
	{ "kill", 0, 0, OptionArg.NONE, ref kill,
	  "kill running alarm", null },
	{ "list", 'l', 0, OptionArg.NONE, ref list,
	  "list scheduled alarms", null },
	{ "puzzle", 0, 0, OptionArg.NONE, ref puzzle,
	  "run turn off puzzle", null },
	{ "play-alarm", 0, 0, OptionArg.STRING, ref play_cmd,
	  "play alarm", null },
	{ "version", 0, 0, OptionArg.NONE, ref version,
	  "display version and exit", null },
	{null}
    };

    public static void main(string[] args)
    {
	new Main();	       // just to initialize static variables;
	var oc = new OptionContext(" - finger friendly alarms");
	oc.add_main_entries(options, null);
	try {
	    oc.parse(ref args);
	} catch (GLib.OptionError e) {
	    die(e.message);
	}
	if (version) {
	    stdout.printf("ffalarms-%s\n", VERSION);
	    Posix.exit(0);
	}
	if (play_cmd != null) {
	    int cnt = (args[1] != null) ? args[1].to_int() : 1;
	    var a = new Alarm(play_cmd, (cnt > 0) ? cnt : 1);
	    a.run();
	    return;
	}
	if (alarms != null) {
	    var cfg = new Config();
	    try {
		cfg.load_from_file(config_file);
		foreach (weak string? s in alarms) {
		    time_t t;
		    if (s == "now") {
			t = time_t();
		    } else {
			int h = -1, m = 0;
			if (Regex.match_simple("^[0-9]+:[0-9]+$", s)) {
			    var hm = s.split(":");
			    h = hm[0].to_int();
			    m = hm[1].to_int();
			}
			if (h < 0 || h > 23 || m < 0 || m > 59)
			    die("argument to -s or --set must be of the form HH:MM or be the word now");
			t = next_hm(h, m);
		    }
		    set_alarm(t, cfg.alarm_cmd(), cfg.repeat, at_spool);
		}
	    } catch (MyError e) {
		die(e.message);
	    } catch (FileError e) {
		die(e.message);
	    }
	}
	if (deletes != null) {
	    time_t[] del = new time_t[deletes.length];
	    int i = 0;
	    foreach (weak string? s in deletes) {
		weak string? v;
		del[i++] = (time_t) strtol(s, out v);
		if (v[0] != '\0' || Posix.errno == ERANGE)
		    die("%s: not a valid timestamp".printf(s));
	    }
	    GLib.List<AlarmInfo?> lst = null;
	    try {
		lst = list_alarms(at_spool);
	    } catch (MyError e) {
		die(e.message);
	    }
	    foreach (unowned AlarmInfo? a in lst)
		foreach (time_t t in del)
		    if (a.timestamp == t)
			try {
			    delete_alarm(a, at_spool);
			} catch (MyError e) {
			    die(e.message);
			}
	}
	if (kill)
	    kill_running_alarms(at_spool);
	if (list)
	    try {
		display_alarms_list(at_spool);
	    } catch (MyError e) {
		die(e.message);
	    }
	if (list || kill || alarms != null || deletes != null)
	    Posix.exit(0);

	Elm.init(args);
	var mw = new MainWin(edje_file, at_spool, config_file);
	if (! puzzle) {
	    mw.show();
	} else {
	    mw.show_delete_puzzle();
	}
	Elm.run();
	Elm.shutdown();
    }
}
