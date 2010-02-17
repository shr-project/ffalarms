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
using ICal;

public const string VERSION = "0.3.1";
public const string EDJE_FILE = "/usr/share/ffalarms/ffalarms.edj";
public const string ALARM_SH = "/usr/share/ffalarms/alarm.sh";
public const string ATD_CONTACT_ERR =
    "Could not contact atd daemon, the alarm may not work";
public const string COMMANDS = "alsactl amixer";
public const string[] ALSASTATE_PATH = {
    "/usr/share/openmoko/scenarios", "/usr/share/shr/scenarii" };
public const string ALSASTATE = "stereoout.state";


public errordomain MyError {
    CONFIG, ERR;
}


void die(string msg)
{
    printerr("%s: %s\n", Environment.get_prgname(), msg);
    Posix.exit(1);
}


string expand_home(string s)
{
    if (s.has_prefix("~/"))
	return Path.build_filename(Environment.get_home_dir(), s.substring(2));
    else
	return s;
}


time_t next_hm(int hour, int minute)
{
    var now = time_t();
    var t = GLib.Time.local(now); t.hour=hour; t.minute=minute; t.second=0;
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


void set_alarm_inner(time_t timestamp, Config cfg, Component e)
throws MyError, FileError
{
    string alarm_cmd = cfg.alarm_cmd();
    int repeat = cfg.repeat;
    string alarm_sh, player = alarm_cmd.chug().split(" ", 2)[0];
    Posix.Stat st;
    string alsa_state = null;

    foreach (var cmd in "%s %s".printf(COMMANDS, player).split(" "))
	if (Environment.find_program_in_path(cmd) == null)
	    throw new MyError.CONFIG("command %s not found".printf(cmd));
    if (cfg.alsa_state != null) {
	if (stat(cfg.alsa_state, out st) == 0)
	    alsa_state = cfg.alsa_state;
    } else {
	foreach (var path in ALSASTATE_PATH) {
	    alsa_state = Path.build_filename(path, ALSASTATE);
	    if (stat(alsa_state, out st) == 0)
		break;
	    alsa_state = null;
	}
    }
    if (alsa_state == null)
	throw new MyError.CONFIG(
	    "%s: could not find alsa state".printf(
		(cfg.alsa_state != null) ? cfg.alsa_state : ALSASTATE));
    var trig = Path.build_filename(cfg.at_spool, "trigger");
    if (stat(trig, out st) != 0 || !S_ISFIFO(st.st_mode))
	throw new MyError.CONFIG(
	    "Could not contact atd daemon, the alarm was not set");
    var filename = Path.build_filename(
	cfg.at_spool, "%ld.ffalarms.%ld".printf(timestamp, getpid()));
    FileUtils.get_contents(cfg.alarm_script, out alarm_sh);
    var header = """FFALARMS_UID=%s
FFALARMS_ATD_SCRIPT="$0"
export FFALARMS_UID FFALARMS_ATD_SCRIPT""".printf(Shell.quote(e.get_uid()));
    FileUtils.set_contents(
	filename, alarm_sh.printf(header, Shell.quote(alsa_state),
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


void schedule_alarms(Config cfg) throws MyError
{
    // We schedule one occurence for each alarm as we do not yet have
    // a concept of unacknowledged past alarms
    var alarms = list_alarms(cfg);
    var scheduled_alarms = list_scheduled_alarms(cfg);
    foreach (var c in alarms.begin_component()) {
	var next = next_alarm_as_utc(c);
	if (! next.is_null_time()) {
	    var t = next.as_timet();
	    foreach (var a in scheduled_alarms)
		if (a.timestamp == t && a.uid == c.get_uid()) {
			t = 0;	// already scheduled
			break;
		}
	    if (t != 0)
		try {
		    set_alarm_inner(t, cfg, c);
		} catch (FileError e) {
		    throw new MyError.ERR(e.message);
		}
	}
    }
}


unowned TimeZone local_tz()
{
    string s = Environment.get_variable("TZ");
    try {
	if (s == null)
	    // XXX quick hack: the format is more complicated
	    FileUtils.get_contents("/etc/timezone", out s);
    } catch (FileError e) {
    	s = "UTC";
    }
    return TimeZone.get_builtin_timezone(s.strip());
}


ICal.Time time_from_timet_with_zone(time_t t, bool is_date, TimeZone zone)
{
    if (ICal.VERSION == "0.26") {
	// old version on OpenEmbedded
	ICal.Time result = ICal.Time.from_timet_with_zone(
	    t, is_date, TimeZone.get_utc_timezone()).convert_to_zone(zone);
	// floating time
	result.set_timezone(ref result, null);
	return result;
    } else {
	return ICal.Time.from_timet_with_zone(t, is_date, zone);
    }
}


// XXX may return time_t
ICal.Time next_alarm_as_utc(Component c)
{
    unowned TimeZone tz = local_tz();
    unowned TimeZone utc = TimeZone.get_utc_timezone();
    var t = time_t();
    var utc_now = ICal.Time.from_timet_with_zone(t, false, utc);
    ICal.Time tz_now = time_from_timet_with_zone(t, false, tz);
    ICal.Time next = ICal.Time.null_time(); // silent Vala false positive error
    unowned Property p = c.get_first_property(PropertyKind.RRULE);
    if  (p == null) {
	next = c.get_dtstart();
    } else {
	var iter = new RecurIterator(p.get_rrule(), c.get_dtstart());
	do {
	    next = iter.next();
	} while (next.compare(tz_now) < 0);
    }
    if (!next.is_utc() && next.zone == null)
	ICal.Time.set_timezone(ref next, tz);
    TimeZone.convert_time(ref next, tz, utc);
    next.set_timezone(ref next, utc);
    return (next.compare (utc_now) >= 0) ? next : ICal.Time.null_time();
}


void write_alarms(Component alarms, Config cfg) throws MyError
{
    var fn = cfg.get_alarms_filename();
    var tmp_fn = "%s.new.%ld".printf(fn, getpid());
    var f = FileStream.open(tmp_fn, "w");
    foreach (var c in alarms.begin_component())
	f.puts(c.as_ical_string());
    f = null;
    FileUtils.rename(tmp_fn, fn);
}


void set_alarm(time_t timestamp, Config cfg, string? rrule, string? summary)
throws MyError, FileError
{
    Component x = list_alarms(cfg);
    Component c = new Component.vevent();
    c.set_dtstart(time_from_timet_with_zone(timestamp, false, local_tz()));
    c.set_uid("%08x.%08x@%s".printf((uint) time_t(), Random.next_int(),
				    Environment.get_host_name()));
    if (rrule != null)
	c.add_property(new Property.rrule(Recurrence.from_string(rrule)));
    if (summary != null && !Regex.match_simple("^\\s*$", summary))
	c.set_summary(summary);
    x.add_component((owned) c);
    write_alarms(x, cfg);
    schedule_alarms(cfg);
}


void modify_alarm(time_t timestamp, Config cfg,
		  string? rrule, string? summary, string uid)
throws MyError, FileError
{
    Component x = list_alarms(cfg);
    unowned Component c = null;
    foreach (var c1 in x.begin_component())
	if (c1.get_uid() == uid) {
	    c = c1;
	    break;
	}
    if (c == null)
	throw new MyError.ERR("Could not find alarm with the given uid");
    c.set_dtstart(time_from_timet_with_zone(timestamp, false, local_tz()));
    if (rrule != null)
	c.add_property(new Property.rrule(Recurrence.from_string(rrule)));
    if (summary != null && !Regex.match_simple("^\\s*$", summary))
	c.set_summary(summary);
    delete_scheduled_alarm(c.get_uid(), cfg);
    write_alarms(x, cfg);
    schedule_alarms(cfg);
}


struct AlarmInfo
{
    public time_t timestamp;
    public string filename;
    public string localtime;
    public string uid;
}


Component list_alarms(Config cfg) throws MyError
{
    FileStream f = FileStream.open(cfg.get_alarms_filename(), "r");
    if (f != null) {
	var p = new Parser();
	p.set_gen_data(f);
	Component c = p.parse((LineGenFunc) FileStream.gets);
	if (c == null) {
	    return new Component(ComponentKind.XROOT);    
	} else if (c.isa() == ComponentKind.XROOT) {
	    return c;
	} else {
	    Component x = new Component(ComponentKind.XROOT);
	    x.add_component((owned) c);
	    return x;
	}
    } else {
	return new Component(ComponentKind.XROOT);
    }
}


[Compact]
class NextAlarm
{
    public unowned Component comp;
    public ICal.Time next;

    public string to_string(string summary_prefix=" ")
    {
	var sb = new StringBuilder(GLib.Time.local(next.as_timet())
				   .format("%a %b %d %X %Y"));
	unowned Property p = comp.get_first_property(PropertyKind.RRULE);
	if (p != null)
	    sb.append_printf(" (%s)", p.as_ical_string().strip());
	unowned string s = comp.get_summary();
	if (s != null && s.length > 0)
	    sb.append_printf("%s%s", summary_prefix, s);
	return sb.str;
    }
}


/**
 * NOTE: if alarms parameter is deleted, result is no longer valid
 */
SList<NextAlarm> list_future_alarms(Component alarms)
{
    var L = new SList<NextAlarm>();
    foreach (var c in alarms.begin_component(ComponentKind.ANY)) {
	var next = next_alarm_as_utc(c);
	if (! next.is_null_time())
	    L.prepend(new NextAlarm() { comp=c, next=next} );
    }
    L.sort((a, b) => ((NextAlarm)a).next.compare(((NextAlarm)b).next));
    return L;
}


public GLib.List<AlarmInfo?> list_scheduled_alarms(Config cfg)
throws MyError
{
    Regex re, re_uid;
    try {
	re = new Regex("^[0-9]+[.]ffalarms[.]");
	re_uid = new Regex("^FFALARMS_UID=([^ ]+)");
    } catch (RegexError e) {
	assert_not_reached();
    }
    var dir = opendir(cfg.at_spool);
    if (dir == null)
	throw new MyError.CONFIG("Could not list spool directory: %s",
				 cfg.at_spool);
    var lst = new GLib.List<AlarmInfo?>();
    unowned DirEnt de;
    MatchInfo m;
    while ((de = readdir(dir)) != null) {
	unowned string s = (string) de.d_name;
	time_t t = s.to_int();
	string uid;
	if (re.match(s)) {
	    var f = FileStream.open(Path.build_filename(cfg.at_spool, s), "r");
	    if (f != null) {
		string line;
		while ((line = f.read_line()) != null) {
		    if (line.has_prefix("#!") ||
			line.has_prefix("##ffalarms##"))
			continue;
		    if (! line.has_prefix("FFALARMS_"))
			break;
		    if (re_uid.match(line, 0, out m))
			try {
			    uid = Shell.unquote(m.fetch(1));
			} catch (ShellError e) {
			    uid = m.fetch(1);
			}
		}
	    }
	    lst.append(AlarmInfo() { timestamp=t, filename=s, uid=uid,
			localtime=GLib.Time.local(t).format("%a %b %d %X %Y")});
	}
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

weak string? nth_token(string buf, int nth)
{
    bool prev_tok = false, tok;
    int n = -1;

    for (char *p = (char *) buf; *p != '\0'; p++) {
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
    string line;
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
    while ((line = f.read_line()) != null) {
	if (alarm_cmd.match(nth_token(line, 7), 0, out m)) {
	    int alarm_pid = nth_token(line, 1).to_int();
	    if (stat(Path.build_filename(
			 at_spool, "x%s.%d".printf(
			     m.fetch(1), alarm_pid)), out st) == 0)
		if (kill(alarm_pid, SIGTERM) == 0)
		    result = true;
	}
    }
    return result;
}


void delete_scheduled_alarm(string uid, Config cfg) throws MyError
{
    foreach (var a in list_scheduled_alarms(cfg))
	if (a.uid == uid) {
	    var filename = Path.build_filename(cfg.at_spool, a.filename);
	    if (unlink(filename) != 0) {
		Posix.Stat st;
		if (Posix.errno == ENOENT)
		    throw new MyError.ERR("%s: %s\n".printf(
			filename, Posix.strerror(Posix.errno)));
		if (stat(Path.build_filename(
		    cfg.at_spool, "x%s".printf(a.filename)), out st) == 0 &&
		    ! kill_running_alarms(cfg.at_spool))
		    throw new MyError.ERR("No alarm was running");
	    }
	}
}


/**
 * NOTE: you have to call schedule_alarms after a call (or calls) to
 * delete_alarm
 */
void delete_alarm(string uid, Config cfg) throws MyError
{
    Component alarms = list_alarms(cfg);
    foreach (unowned Component c in alarms.begin_component())
	if (c.get_uid() == uid) {
	    delete_scheduled_alarm(c.get_uid(), cfg);
	    // XXX libical.vapi: we should free the component memory
	    alarms.remove_component(c);
	    write_alarms(alarms, cfg);
	    break;
	}
}


/**
 * NOTE: you have to call schedule_alarms after a call (or calls) to
 * acknowledge_alarm
 */
void acknowledge_alarm(string uid, time_t t, Config cfg) throws MyError
{
    Component alarms = list_alarms(cfg);
    foreach (unowned Component c in alarms.begin_component())
	if (c.get_uid() == uid) {
	    unowned Property p = c.get_first_property(PropertyKind.RRULE);
	    if (p == null) {
		delete_alarm(uid, cfg);
	    } else if (t != 0) {
		// we hold newest acknowlendged instance of the
		// recurring alarm in the RECURRENCE-ID
		var time = time_from_timet_with_zone(t, false, local_tz());
		var prev = c.get_recurrenceid();
		if (prev.is_null_time() || time.compare(prev) > 0) {
		    c.set_recurrenceid(time);
		    write_alarms(alarms, cfg);
		}
	    }
	    return;
	}
}


public void display_alarms_list(Config cfg) throws MyError
{
    GLib.stdout.printf("# Alarms:\n");
    var alarms = list_alarms(cfg);
    foreach (unowned NextAlarm a in list_future_alarms(alarms))
	GLib.stdout.printf("%s	%s (dtstart:%s)\n",
			   a.comp.get_uid(), a.to_string("\n	"),
			   a.comp.get_dtstart().as_ical_string());
    GLib.stdout.printf("# Scheduled:\n");
    foreach (unowned AlarmInfo? a in list_scheduled_alarms(cfg))
	GLib.stdout.printf("%11ld  %s%s\n", a.timestamp, a.localtime,
			   (a.uid != null) ? " (%s)".printf(a.uid) : "");
}


class CheckGroup
{
    public Box bx;
    public Check[] checks;

    public CheckGroup(Win parent, string[] names)
    {
	bx = new Box(parent);
	checks = new Check[names.length];
	int i = 0;
	foreach (var s in names) {
	    var ck = new Check(parent);
	    ck.label_set(s);
	    ck.size_hint_align_set(0.0, 0.0);
	    ck.show();
	    ck.state_set(true);
	    bx.pack_end(ck);
	    checks[i++] = (owned) ck;
	}
    }
}


class Base
{
    protected SList<Evas.Object> widgets;

    protected void swallow(owned Evas.Object w)
    {
	widgets.prepend((owned) w);
    }
}


class BaseWin : Base
{
    protected Win win;

    protected unowned Frame frame(string label, Elm.Object? content)
    {
    	var fr = new Frame(win);
	unowned Frame result = fr;
	fr.label_set(label);
	fr.content_set(content);
	fr.size_hint_align_set(-1.0, 0.0);
	fr.show();
	widgets.prepend((owned) fr);
	return result;
    }

    protected unowned Frame pad(string style)
    {
    	var fr = new Frame(win);
	unowned Frame result = fr;
	fr.style_set(style);
	fr.size_hint_align_set(-1.0, 0.0);
	fr.show();
	widgets.prepend((owned) fr);
	return result;
    }
}


class Calendar : Base
{

    public Table tb;
    public delegate void DateFunc(Date date);
    public DateFunc date_clicked_cb;

    Date first;
    Date today;
    int first_weekday;

    const int DAY_BTNS_CNT = 37;
    Button[] day_btns = new Button[DAY_BTNS_CNT];
    HashTable<unowned Evas.Object,int> day_btns_to_idx;
    Label cur_month;

    public const string[] days = {
	"Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" };

    public Calendar(Win parent)
    {
	tb = new Table(parent);
	tb.size_hint_weight_set(1.0, 1.0);
	tb.size_hint_align_set(-1, -1);

	var tm = GLib.Time.local(time_t());
	today = Date();
	today.set_dmy((DateDay)tm.day, tm.month + 1,
		      (DateYear)(1900 + tm.year));

	cur_month = new Label(parent);
       	tb.pack(cur_month, 1, 0, 5, 1);
	cur_month.show();

	var b = new Button(parent);
	b.label_set("<");
	b.smart_callback_add("clicked", prev_month);
       	tb.pack(b, 0, 0, 1, 1);
	b.show();
	swallow((owned) b);

	b = new Button(parent);
	b.label_set(">");
	b.smart_callback_add("clicked", next_month);
       	tb.pack(b, 6, 0, 1, 1);
	b.show();
	swallow((owned) b);

	for (int i = 0; i < 7; ++i)
	{
	    var lb = new Label(parent);
	    lb.label_set(days[i]);
	    tb.pack(lb, i, 1, 1, 1);
	    lb.show();
	    swallow((owned) lb);
	}
	day_btns_to_idx = new HashTable<unowned Evas.Object,int>(null, null);
	for (int i = 0; i < DAY_BTNS_CNT; ++i)
	{
	    b = new Button(parent);
	    b.smart_callback_add("clicked", day_button_cb);
	    tb.pack(b, i % 7, i / 7 + 2, 1, 1);
	    day_btns_to_idx.insert(b, i);
	    day_btns[i] = (owned) b;
	}
	set_month(today.get_month(), today.get_year());
	tb.show();
    }

    public void prev_month()
    {
	first.subtract_months(1);
	set_month(first.get_month(), first.get_year());
    }

    public void next_month()
    {
	first.add_months(1);
	set_month(first.get_month(), first.get_year());
    }

    public void set_month(DateMonth month, DateYear year)
    {
	first.set_dmy(1, month, year);
	int wday = first_weekday = first.get_weekday() % 7;
	int dim = first.get_month().get_days_in_month(first.get_year());
	char[] s = new char[100];
	first.strftime(s, "<b>%B %Y<b>");
	cur_month.label_set((string) s);
	for (int i = 0; i < DAY_BTNS_CNT; i++)
	{
	    int j = i - wday;
	    if (j >= 0 && j < dim) {
		day_btns[i].label_set((j + 1).to_string());
		day_btns[i].show();
	    } else {
		day_btns[i].hide();
	    }
	}
	if (today.get_month() == month && today.get_year() == year) {
	    int j = today.get_day() - 1;
	    day_btns[j + wday].label_set("[%d]".printf(j + 1));
	}
    }

    void day_button_cb(Evas.Object o, void* event_info)
    {
	Date date = first;
	date.set_day((DateDay)(day_btns_to_idx.lookup(o) - first_weekday + 1));
	if (date_clicked_cb != null)
	    date_clicked_cb(date);
    }
}


class CalendarWin : BaseWin
{
    public Calendar cal;

    public CalendarWin(Win? parent, Calendar.DateFunc? date_clicked_cb=null)
    {
	win = new Win(parent, "calendar", WinType.BASIC);
	win.smart_callback_add("delete-request", close);
	win.title_set("Calendar");

	var bg = new Bg(win);
	bg.size_hint_weight_set(1.0, 1.0);
	win.resize_object_add(bg);
	bg.show();
	swallow((owned) bg);

	var bx = new Box(win);
	bx.size_hint_weight_set(1.0, 1.0);
	win.resize_object_add(bx);
	bx.show();

	cal = new Calendar(win);
	cal.date_clicked_cb = date_clicked_cb;
	cal.tb.size_hint_align_set(0.5, 0.5);

	var b = new Button(win);
	b.size_hint_align_set(-1, -1);
	b.smart_callback_add("clicked", close);
	b.label_set("Close");
	cal.tb.pack(b, 2, 7, 5, 1);
	b.show();
	swallow((owned) b);

	bx.pack_end(cal.tb);
	swallow((owned) bx);
    }

    public void show()
    {
	win.show();
    }

    public void close()
    {
	win = null;
    }
}


class AddAlarm : BaseWin
{
    Bg bg;
    Box bx;
    Pager pager;
    Buttons btns;
    Layout lt;
    weak Edje.Object edje;
    int hour = -1;
    int minute = 0;
    bool showing_options = false;
    public delegate void SetAlarm(time_t timestamp,
				  string? recur, string? summary);
    SetAlarm set_alarm;
    Recurrence recur;
    string summary;

    public void show(Win parent, string edje_file, SetAlarm set_alarm)
    {
	recur.clear(ref recur);

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

	pager = new Pager(win);
	pager.size_hint_weight_set(1.0, 1.0);
	pager.size_hint_align_set(-1.0, -1.0);
	bx.pack_end(pager);
	pager.show();

	lt = new Layout(win);
	lt.file_set(edje_file, "clock-group");
	lt.size_hint_weight_set(1.0, 1.0);
	lt.size_hint_align_set(-1.0, -1.0);
	pager.content_push(lt);
	lt.show();

	btns = new Buttons(win);
	btns.add("Add", this.add);
	btns.add("Options", flip_page);
	btns.add("Close", this.close);
	bx.pack_end(btns.box);

	edje = (Edje.Object) lt.edje_get();
	edje.signal_callback_add("clicked", "hour-*", this.set_hour);
	edje.signal_callback_add("clicked", "minute-*", this.set_minute);

	win.resize(480, 640);
	win.show();
    }

    public void set_data(Component c)
    {
	win.title_set("Edit alarm");
	btns.buttons[0].label_set("Save");
	this.summary = c.get_summary();
	var t = c.get_dtstart();
	date.set_dmy((DateDay)t.day, t.month, (DateMonth)t.year);
	this.hour = t.hour;
	this.minute = t.minute;
	edje.signal_emit("%d".printf(hour), "set-hour");
	edje.signal_emit("%d".printf(minute), "set-minute");
    }

    void flip_page()
    {
	if (options == null) {
	    build_options();
	    pager.content_push(options);
	}
	if (showing_options) {
	    cl.time_get(out hour, out minute, null);
	    edje.signal_emit("%d".printf(hour), "set-hour");
	    edje.signal_emit("%d".printf(minute), "set-minute");
	} else {
	    cl.time_set((hour != -1) ? hour : 0, minute, 0);
	}
	pager.content_promote((showing_options) ? (Elm.Object) lt : options);
	showing_options = ! showing_options;
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
	string recur_str=null;
	if (showing_options)
	    cl.time_get(out hour, out minute, null);
	if (options != null) {
	    int i = 0, j = 0;
	    foreach (unowned Check ck in wd.checks) {
		if (ck.state_get())
		    recur.by_day[j++] = recur_weekdays[i];
		i++;
	    }
	    recur.by_day[(j < 7) ? j : 0] = Recurrence.ARRAY_MAX;
	    recur_str = recur.as_string(ref recur);
	    summary = Entry.markup_to_utf8(this.summary_e.entry_get()).strip();
	}
	if (this.hour != -1) {
	    time_t timestamp;
	    if (date.valid()) {
		GLib.Time t;
		date.to_time(out t);
		t.hour = hour;
		t.minute = minute;
		t.second = 0;
		timestamp = t.mktime();
	    } else {
		timestamp = next_hm(this.hour, this.minute);
	    }
	    this.set_alarm(timestamp, recur_str, summary);
	    close();
	}
    }

    public void close()
    {
	win = null;
    }

    Scroller options;
    Clock cl;
    Entry summary_e;
    Hoversel freq;
    /* Hoversel repeat; */
    CheckGroup wd;
    Date date;
    Button date_b;
    CalendarWin cal;

    const string[] weekdays = {"Monday", "Tuesday", "Wednesday", "Thursday",
			       "Friday", "Saturday", "Sunday"};
    const RecurrenceWeekday[] recur_weekdays = {
	RecurrenceWeekday.MONDAY,
	RecurrenceWeekday.TUESDAY,
	RecurrenceWeekday.WEDNESDAY,
	RecurrenceWeekday.THURSDAY,
	RecurrenceWeekday.FRIDAY,
	RecurrenceWeekday.SATURDAY,
	RecurrenceWeekday.SUNDAY
    };

    public void build_options()
    {
	var bx = new Box(win);
	bx.size_hint_weight_set(1.0, 0.0);
	bx.show();

	summary_e = new Entry(win);
	summary_e.single_line_set(true);
	if (summary != null)
	    this.summary_e.entry_set(Entry.utf8_to_markup(summary));
	summary_e.show();

	var sc = new Scroller(win);
	sc.policy_set(ScrollerPolicy.OFF, ScrollerPolicy.OFF);
	sc.content_min_limit(false, true);
	sc.size_hint_align_set(-1.0, -1.0);
	sc.content_set(summary_e);
	sc.show();

	bx.pack_end(frame("Summary", sc));
	swallow((owned) sc);

	var bx1 = new Box(win);

	date_b = new Button(win);
	date_b.size_hint_align_set(-1.0, -1.0);
	if (date.valid())
	    set_date_close_calendar(date);
	else
	    date_b.label_set("Nearest future date");
	date_b.smart_callback_add("clicked", select_date_from_calendar);
	bx1.pack_end(date_b);
	date_b.show();

	cl = new Clock(win);
	cl.time_set((hour != -1) ? hour : 0, minute, 0);
	cl.edit_set(true);
	bx1.pack_end(cl);
	cl.show();
	bx.pack_end(frame("Start", bx1));
	bx1.show();
	swallow((owned) bx1);

	freq = new Hoversel(win);
	freq.hover_parent_set(win);
	freq.label_set("Once");
	freq.item_add("Once", null, IconType.NONE,
		      () => freq_cb("Once", RecurrenceFrequency.NO));
	freq.item_add("Daily", null, IconType.NONE,
		      () => freq_cb("Daily", RecurrenceFrequency.DAILY));
	freq.item_add("Weekly", null, IconType.NONE,
		      () => freq_cb("Weekly", RecurrenceFrequency.WEEKLY));
	freq.item_add("Monthly", null, IconType.NONE,
		      () => freq_cb("Monthly", RecurrenceFrequency.MONTHLY));
	freq.item_add("Yearly", null, IconType.NONE,
		      () => freq_cb("Yearly", RecurrenceFrequency.YEARLY));
	bx.pack_end(frame("Frequency", freq));
	freq.show();

#if WORK_IN_PROGRESS
	repeat = new Hoversel(win);
	repeat.hover_parent_set(win);
	repeat.label_set("Forever");
	repeat.item_add("Forever", null, IconType.NONE, null);
	repeat.item_add("Until date", null, IconType.NONE, null);
	repeat.item_add("Count times", null, IconType.NONE, null);
	repeat.size_hint_align_set(-1.0, 0.1);
	repeat.show();
	bx.pack_end(frame("Repeat", repeat));
#endif

	wd = new CheckGroup(win, weekdays);
	bx.pack_end(frame("Weekdays", wd.bx));

	sc = new Scroller(win);
	sc.content_min_limit(true, false);
	sc.size_hint_weight_set(1.0, 1.0);
	sc.size_hint_align_set(-1.0, -1.0);
	sc.bounce_set(false, false);
	sc.content_set(bx);
	sc.show();
	// whether to show the scroller
	swallow((owned) bx);
	options = (owned) sc;
    }

    void select_date_from_calendar()
    {
	// without setting cal to null some elements in the calendar
	// randomly disappear, must hide some memory management problem
	cal = null;
	cal = new CalendarWin(null, set_date_close_calendar);
	cal.win.title_set("Select date");
	cal.show();
    }

    void set_date_close_calendar(Date date)
    {
	this.date = date;
	char[] s = new char[100];
	date.strftime(s, "%a %b %d %Y");
	this.date_b.label_set((string) s);
	cal = null;
    }

    void freq_cb(string name, RecurrenceFrequency freq)
    {
	this.freq.label_set(name);
	recur.freq = freq;
    }
}


class Puzzle : BaseWin
{
    Bg bg;
    Button[] b = new Button[4];
    Frame fr;
    Label lb;
    Layout lt;
    Toggle delete_tg;
    Buttons btns;
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

	if (sel != null)
	    delete_selection(label, false);
	else
	    puzzle(edje_file, label);

	win.resize(480, 640);
	win.show();
    }

    public void show_ack(string label, DeleteAlarms delete_alarms,
			 Eina.List<weak ListItem>? sel)
    {
	this.delete_alarms = delete_alarms;
	this.sel = sel;
	this.no_close = true;
	lt.hide();
	delete_selection(label, true);
    }

    void delete_selection(string label, bool ack)
    {
	var bx = new Box(win);
	bx.size_hint_weight_set(1.0, 1.0);
	win.resize_object_add(bx);
	bx.show();

	bx.pack_end(pad("pad_small"));
	var lb1 = new Label(win);
	lb1.label_set("<b>%s</b><br><br>".printf(label));
	bx.pack_end(lb1);
	lb1.show();
	swallow((owned) lb1);

	var sc = new Scroller(win);
	sc.content_min_limit(false, false);
	sc.bounce_set(false, false);
	sc.size_hint_weight_set(1.0, 1.0);
	sc.size_hint_align_set(-1.0, -1.0);

	var bx1 = new Box(win);
	bx1.size_hint_weight_set(1.0, 1.0);
	lb = new Label(win);
	var sb = new StringBuilder();
	weak ListItem item = null;
	Eina.Iterator<weak ListItem> iter = sel.iterator_new();
	while (iter.next(ref item))
	    sb.append_printf("%s<br>", item.label_get());
	lb.label_set(sb.str);
	lb.size_hint_weight_set(1.0, 1.0);
	lb.size_hint_align_set(0.5, 0.0);
	bx1.pack_end(lb);
	lb.show();
	sc.content_set(bx1);
	bx1.show();
	swallow((owned) bx1);

	bx.pack_end(sc);
	sc.show();
	swallow((owned) sc);
	bx.pack_end(pad("pad_small"));

	delete_tg = new Toggle(win);
	if (ack)
	    delete_tg.states_labels_set("Acknowledge", "Not acknowledged");
	else
	    delete_tg.states_labels_set("Delete", "Keep");
	delete_tg.scale_set(2.0);
	bx.pack_end(delete_tg);
	delete_tg.show();
	bx.pack_end(pad("pad_small"));

	btns = new Buttons(win);
	btns.add("Close", this.close_maybe_delete);
	bx.pack_end(btns.box);

	swallow((owned) bx);
    }

    public string uid;
    public time_t time;
    string time_s;
    string summary;

    public void read_env(Config cfg)
    {
	uid = Environment.get_variable("FFALARMS_UID");
	if (uid != null) {
	    try {
		var alarms = list_alarms(cfg);
		foreach (var a in alarms.begin_component()) {
		    if (a.get_uid() == uid)
			summary = a.get_summary();
		}
	    } catch (MyError e) {
		GLib.message("Could not list alarms: %s", e.message);
	    }
	}
	var s = Environment.get_variable("FFALARMS_ATD_SCRIPT");
	if (s != null) {
	    time = s.to_int();
	    if (time != 0)
		time_s = GLib.Time.local(time).format("%a %b %d %X %Y");
	} else {
	    time = 0;
	}
    }

    void puzzle(string edje_file, string label)
    {
	var bx = new Box(win);
	bx.size_hint_weight_set(1.0, 1.0);
	bx.show();

	lb = new Label(win);
	lb.label_set("<b>%s</b>".printf(label));
	lb.show();

	fr = new Frame(win);
	fr.style_set("outdent_top");
	fr.content_set(lb);
	bx.pack_end(fr);
	fr.show();

	if (time_s != null || summary != null) {
	    var lb = new Label(win);
	    if (time_s != null && summary != null)
		lb.label_set("%s<br>%s<br>".printf(time_s, summary));
	    else if (time_s != null)
		lb.label_set(time_s);
	    else
		lb.label_set(summary);
	    bx.pack_end(lb);
	    lb.show();
	    swallow((owned) lb);
	}

	lt = new Layout(win);
	lt.file_set(edje_file, "puzzle-group");
	lt.size_hint_weight_set(1.0, 1.0);
	win.resize_object_add(lt);
	lt.show();

	weak Edje.Object edje = (Edje.Object) lt.edje_get();
	edje.signal_callback_add("solved", "", this.solved);
	edje.part_swallow("frame", bx);
	for (int i = 0; i < 4; i++)
	    edje.part_swallow("%d-button".printf(i), b[i] = new Button(win));
	edje.signal_emit("start", "");
	swallow((owned) bx);
    }

    bool no_close;

    void solved()
    {
	delete_alarms(sel);
	if (no_close)
	    no_close = false;
	else
	    close();
    }

    void close_maybe_delete()
    {
	if (delete_tg.state_get())
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


class LEDClock
{
    Win win;
    Layout lt;
    int brightness = -1;
    weak Config cfg;

    public LEDClock(Config cfg)
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
    HashTable<ListItem,unowned Component?> items;
    Component alarms;
    Config cfg;

    public Alarms(Elm.Object? parent, Config cfg)
    {
	lst = new Elm.List(parent);
	this.cfg = cfg;
    }

    public void update(Config cfg) throws MyError, GLib.Error
    {
	alarms = list_alarms(cfg);
	items = new HashTable<ListItem,unowned Component?>(null, null);
	foreach (unowned NextAlarm a in list_future_alarms(alarms))
	    items.insert(lst.append(a.to_string(": "), null, null, null), a.comp);
	lst.multi_select_set(true);
	lst.go();
    }

    public void delete_alarms(Eina.List<ListItem>? sel) throws MyError
    {
	if (sel == null) {
	    kill_running_alarms(cfg.at_spool);
	    return;
	}
	weak ListItem item = null;
	Eina.Iterator<weak ListItem> iter = sel.iterator_new();
	var sb = new StringBuilder();
	while (iter.next(ref item))
	    try {
		// XXX delete_alarm could take event as argument
		delete_alarm(items.lookup(item).get_uid(), cfg);
	    } catch (MyError e) {
		sb.append(e.message);
		sb.append_c('\n');
	    }
	if (sb.len != 0)
	    throw new MyError.ERR(sb.str);
	// XXX would be nice to work from here:
	// update();
    }

    public unowned Eina.List<weak ListItem> get_selection()
    {
 	return lst.selected_items_get();
    }

    public unowned Component selected_alarm() throws MyError
    {
	unowned Eina.List<weak ListItem> sel = lst.selected_items_get();
	uint n = sel.count();
        if (n != 1)
	    throw new MyError.ERR("You must select a single alarm to be edited");
	return items.lookup(sel.nth(0));
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
    public delegate void Func();
    Func close_cb;

    unowned Frame frame(string style)
    {
	(fr[fr_num] = new Frame(w)).style_set(style);
	return fr[fr_num++];
    }

    public Message(Win win, string msg, string? title=null,
		   Func? close_cb=null)
    {
	this.close_cb = close_cb;
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
	bt.smart_callback_add("clicked", close);
	bx.pack_end(bt);
	bx.pack_end(frame("pad_small"));
	w.inwin_content_set(bx);
	w.style_set("minimal_vertical");
	bt.show();
	w.inwin_activate();
    }

    void close() {
	this.w = null;
	if (close_cb != null)
	    close_cb();
    }
}


class InwinMessageQueue
{
    public delegate void MessageFunc(string msg, string? title=null);

    unowned Win win;
    Message message;

    struct Msg {
	string msg;
	string title;
    }
    Queue<Msg?> msgs;

    public InwinMessageQueue(Win win)
    {
	this.win = win;
	msgs = new Queue<Msg?>();
    }

    public void add(string msg, string? title=null)
    {
	if (message == null)
	    message = new Message(win, msg, title, next_message);
	else
	    msgs.push_tail(Msg() {msg=msg, title=title});
    }

    void next_message()
    {
	Msg? m = msgs.pop_head();
	if (m != null)
	    message = new Message(win, m.msg, m.title, next_message);
	else
	    message = null;
    }
}


class Buttons
{
    public Box box;
    public Button[] buttons = new Button[3];
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

    public unowned Button add(string label, Evas.Callback cb)
    {
	unowned Button b;

	b = buttons[idx++] = new Button(parent);
	b.label_set(label);
	b.smart_callback_add("clicked", cb);
	b.size_hint_weight_set(1.0, 0.0);
	b.size_hint_align_set(-1.0, -1.0);
	box.pack_end(b);
	b.show();
	return b;
    }
}


class HoverButtons : Buttons
{
    public Hover hover;

    public HoverButtons(Elm.Object parent)
    {
	base(parent);
	hover = new Hover(parent);
	hover.parent_set(parent);
	box.horizontal_set(false);
	hover.content_set("top", box);
    }

    public new unowned Button add(string label, Evas.Callback cb)
    {
	unowned Button b = base.add(label, cb);
	b.smart_callback_add("clicked", hover.hide);
	return b;
    }
}


class MainWin : BaseWin
{
    Bg bg;
    Box bx;
    Buttons btns;
    Frame fr;
    LEDClock clock;
    AddAlarm aa;
    Puzzle puz;
    Alarms alarms;
    InwinMessageQueue msgs;
    InwinMessageQueue.MessageFunc message;
    Config cfg;
    string edje_file;
    string at_spool;
    string config_file;
    HoverButtons options;

    public MainWin(string edje_file, string at_spool, string? config_file)
    {
	this.edje_file = edje_file;
	this.at_spool = at_spool;
	this.config_file = config_file;
    }

    void close()
    {
	puz = null; // avoid double memory free (edje swallowed buttons)
	Elm.exit();
    }

    public void show()
    {
	win = new Win(null, "main", WinType.BASIC);
	win.title_set("Alarms");
	win.smart_callback_add("delete-request", close);
	msgs = new InwinMessageQueue(win);
	message = msgs.add;

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
	btns.add("Add", () => {
		edited_alarm_uid = null;
		(aa = new AddAlarm()).show(win, edje_file, set_alarm_);
	    });
	options = new HoverButtons(win);
	options.add("Edit", edit_alarm);
	options.add("Delete", start_delete_puzzle);
	options.hover.target_set(btns.add("Options", options.hover.show));
	btns.add("Clock", () => {
		(clock = new LEDClock(cfg)).show(win, edje_file); });
	bx.pack_end(btns.box);

	cfg = new Config(at_spool);
	try {
	    cfg.load_from_file(config_file);
	} catch (MyError e) {
	    message("%s\nDefault configuration will be used."
		    .printf(e.message), "Error reading config file");
	    cfg.use_defaults();
	}
	schedule_alarms_();
	update_alarms();
	var black_hole = new HashTable<int, EventHandler>.full(null, null,
							       null, null);
	black_hole.insert(0, new EventHandler(EventType.SIGNAL_USER,
					      sig_user));

	win.resize(480, 640);
	win.show();
    }

    void schedule_alarms_()
    {
	try {
	    schedule_alarms(cfg);
	} catch (MyError e) {
	    message("%s\nAlarms may not work."
		    .printf(e.message), "Error while scheduling alarms");
	}
    }

    bool sig_user(int type, void *event)
    {
	update_alarms();
	return false;
    }

    void set_alarm_(time_t time, string? recur, string? summary)
    {
	try {
	    if (edited_alarm_uid == null)
		set_alarm(time, cfg, recur, summary);
	    else
		modify_alarm(time, cfg, recur, summary, edited_alarm_uid);
	} catch (MyError e) {
	    message(e.message, "Problem while setting alarm");
	} catch (FileError e) {
	    message(e.message, "Problem while setting alarm");
	}
	update_alarms();
    }

    public void show_delete_puzzle()
    {
	puz = new Puzzle();
	puz.exit_when_closed = true;
	cfg = new Config(at_spool);
	try {
	    cfg.load_from_file(config_file);
	} catch (MyError e) {
	    GLib.message("Error reading config file: %s".printf(e.message));
	    cfg.use_defaults();
	}
	puz.read_env(cfg);
	puz.show(null, edje_file, "Confirm turning off the running alarm",
		 kill_running_alarms_maybe_ack, null);
    }

    Eina.List<weak ListItem> ack_sel;
    Elm.List ack_lst;
    ListItem ack_item;

    void kill_running_alarms_maybe_ack()
    {
	kill_running_alarms(at_spool);
	if (puz.uid != null && puz.time != 0) {
	    var alarms = list_alarms(cfg);
	    foreach (var c in alarms.begin_component()) {
		if (c.get_uid() == puz.uid) {
		    win = new Win(null, "fake", WinType.BASIC);
		    ack_lst = new Elm.List(win);
		    var next = time_from_timet_with_zone(
			puz.time, false, TimeZone.get_utc_timezone());
		    var a = new NextAlarm() { comp=c, next=next };
		    ack_item = ack_lst.append(a.to_string(": "),
					      null, null, null);
		    ack_sel = null;
		    ack_sel.append(ack_item);
		    puz.show_ack("Acknowledge the alarm",
				 acknowledge, ack_sel);
		    break;
		}
	    }
	}
    }

    void acknowledge(Eina.List<weak ListItem> sel)
    {
	acknowledge_alarm(puz.uid, puz.time, cfg);
	schedule_alarms(cfg);
	ack_item = null;
       	ack_sel = null;
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

    string edited_alarm_uid;
    void edit_alarm()
    {
	unowned Component c;
	try {
	    c = alarms.selected_alarm();
	    unowned Property p = c.get_first_property(PropertyKind.RRULE);
	    if (p != null)
		throw new MyError.ERR(
		    "Editing of recursive alarms not yet supported");
	    edited_alarm_uid = c.get_uid();
	    aa = new AddAlarm();
	    aa.show(win, edje_file, set_alarm_);
	    aa.set_data(c);
	} catch (MyError e) {
	    message(e.message, "Edit alarm");
	}
    }

    // hack: I recreate all the list as removing from the list
    // segfaults so the list owns the items (XXX weak?)
    // XXX probably free_function="" try

    public void delete_alarms(Eina.List<ListItem>? sel)
    {
	try {
	    alarms.delete_alarms(sel);
	} catch (MyError e) {
	    message(e.message, "Delete alarms");
	}
	schedule_alarms_();
	// XXX dirty update
	update_alarms();
    }

    public void update_alarms()
    {
	alarms = new Alarms(win, cfg);
	try {
	    alarms.update(cfg);
	} catch (MyError e) {
	    message(e.message);
	} catch (GLib.Error e) {
	    message(e.message);
	}		
	alarms.lst.show();
	fr.content_set(alarms.lst);
    }
}


public class Config
{
    KeyFile ini;
    public string at_spool;
    public const string DEFAULT_CONFIG = "~/.ffalarmsrc";
    public const int BRIGHTNESS = 33;
    public string alsa_state;
    public string alarm_script;
    public int alarm_volume_initial;
    public int alarm_volume_final;
    public int alarm_volume_inc_interval;
    string player;
    string alarm_file;
    public int repeat;
    public int brightness;
    public bool time_24hr_format;
    public int[] led_color;

    public Config(string at_spool)
    {
	use_defaults();
	this.at_spool = at_spool;
    }

    public void use_defaults()
    {
	player = "aplay -q %(file)s";
	alarm_file = "/usr/share/ffalarms/alarm.wav";
	repeat = 500;
	time_24hr_format = true;
	brightness = BRIGHTNESS;
	alarm_script = ALARM_SH;
	alarm_volume_initial = 60;
	alarm_volume_final = 100;
	alarm_volume_inc_interval = 105;
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
	    if (ini.has_key("alarm", "alsa_state"))
		alsa_state = expand_home(ini.get_value("alarm", "alsa_state"));
	    if (ini.has_key("alarm", "alarm_script"))
		alarm_script = expand_home(ini.get_value("alarm",
							 "alarm_script"));
	    if (ini.has_key("alarm", "volume"))
		read_alarm_volume();
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

    public string get_alarms_filename() throws MyError
    {
	var dir = expand_home("~/.ffalarms");
	if (DirUtils.create_with_parents(dir, 0755) != 0)
	    throw new MyError.CONFIG(
		"Could not create config directory ~/.ffalarms");
	return Path.build_filename(dir, "alarms");
    }

    void read_alarm_volume() throws MyError
    {
	try {
	    int[] volume = ini.get_integer_list("alarm", "volume");
	    if (volume.length == 1) {
		alarm_volume_initial = alarm_volume_final = volume[0];
	    } else if (volume.length == 3) {
		alarm_volume_initial = volume[0];
		alarm_volume_final = volume[1];
		alarm_volume_inc_interval = volume[2];
	    } else {
		throw new MyError.CONFIG("Alarm volume must match: \"initial_volume[, final_volume, time_interval]\"");
	    }
	} catch (KeyFileError e) {
	    throw new MyError.CONFIG(e.message);
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
    Config cfg;
    double volume;
    double volume_inc_step;
    FileStream mixer;
    GLib.MainLoop ml;
    static pid_t player_pid = 0;

    public Alarm(string play_cmd, int cnt) {
	this.cnt = cnt;
	try {
	    Shell.parse_argv(play_cmd, out play_argv);
	} catch (ShellError e) {
	    die(e.message);
	}
    }

    public void run()
    {
	int stdin;

	// XXX at_spool should be somehow given as argument
	cfg = new Config("/var/spool/at");
	try {
	    cfg.load_from_file(null); // XXX propagate filename
	} catch (MyError e) {
	    warning("Error reading config file: %s\nDefault configuration will be used."
		    .printf(e.message));
	    cfg.use_defaults();
	}
	try {
	    schedule_alarms(cfg);
	} catch (GLib.Error e) {
	    // XXX should display GUI error
	    warning(e.message);
	}

	ml = new GLib.MainLoop(null, false);
	request_resources();
	if (cfg.alarm_volume_initial != -1) {
	    try {
		volume = cfg.alarm_volume_initial;
		Process.spawn_async_with_pipes(
			null, AMIXER_CMD, null, SpawnFlags.SEARCH_PATH,
			null, null, out stdin, null, null);
		mixer = FileStream.fdopen(stdin, "w");
		mixer.printf(SET_PCM_FMT, volume);
		mixer.flush();
		if (volume < cfg.alarm_volume_final) {
		    volume_inc_step = (((double)cfg.alarm_volume_final
					- cfg.alarm_volume_initial)
				       / cfg.alarm_volume_inc_interval);
		    Timeout.add(1000, inc_volume);
		}
	    } catch (SpawnError e) {
		// we continue with default volume
		GLib.message("Alarm.run: %s", e.message);
	    }
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
	    GLib.stderr.printf("end call error: %s\n", e.message);
    }

    static void sigterm(int signal)
    {
	if (player_pid != 0)
	    kill(player_pid, SIGTERM);
	Posix.exit(1);
    }

    bool inc_volume()
    {
	volume += volume_inc_step;
	mixer.printf(SET_PCM_FMT, volume);
	mixer.flush();
	return volume < cfg.alarm_volume_final;
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
    static string summary = null;
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
	{ "summary", 0, 0, OptionArg.STRING, ref summary,
	  "alarm summary (used with --set)", "STRING" },
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

    const string[] recurrence_types = {
	"daily:", "weekly:", "monthly:", "yearly:"
    };

    public static void main(string[] args)
    {
	Config cfg = null;
	new Main();	       // just to initialize static fields
	var oc = new OptionContext(" - finger friendly alarms");
	oc.add_main_entries(options, null);
	try {
	    oc.parse(ref args);
	} catch (GLib.OptionError e) {
	    die(e.message);
	}
	if (version) {
	    GLib.stdout.printf("ffalarms-%s\n", VERSION);
	    Posix.exit(0);
	}
	if (play_cmd != null) {
	    int cnt = (args[1] != null) ? args[1].to_int() : 1;
	    var a = new Alarm(play_cmd, (cnt > 0) ? cnt : 1);
	    a.run();
	    return;
	}
	if (alarms != null || deletes != null || list) {
	    cfg = new Config(at_spool);
	    try {
		cfg.load_from_file(config_file);
	    } catch (MyError e) {
		die(e.message);
	    }
	}
	if (alarms != null) {
	    try {
		foreach (weak string? s in alarms) {
		    time_t t;
		    string s2, rrule = null;
		    foreach (var r in recurrence_types)
			if (s.has_prefix(r)) {
			    rrule = "FREQ=%s".printf(s.split(":", 2)[0].up());
			    s = s2 = s.replace(r, "");
			    break;
			}
		    if (s == "now") {
			// +1 so scheduler will not treat it as past event
			t = time_t() + 1;
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
		    set_alarm(t, cfg, rrule, summary);
		}
	    } catch (MyError e) {
		die(e.message);
	    } catch (FileError e) {
		die(e.message);
	    }
	}
	if (deletes != null) {
	    GLib.List<AlarmInfo?> lst = null;
	    try {
		lst = list_scheduled_alarms(cfg);
	    } catch (MyError e) {
		die(e.message);
	    }
	    foreach (unowned string? s in deletes)
		try {
		    delete_alarm(s, cfg);
		} catch (MyError e) {
		    try {
			schedule_alarms(cfg);
		    } catch (MyError e) {
			message(e.message);
		    }
		    die(e.message);
		}
	    try {
		schedule_alarms(cfg);
	    } catch (MyError e) {
		die(e.message);
	    }
	}
	if (kill)
	    kill_running_alarms(at_spool);
	if (list)
	    try {
		display_alarms_list(cfg);
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
