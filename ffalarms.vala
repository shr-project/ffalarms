/* ffalarms -- finger friendly alarms
 * Copyright (C) 2009-2010 Łukasz Pankowski <lukpank@o2.pl>
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
using Ecore;
using Posix;
using ICal;

namespace Ffalarms {

public const string VERSION = "0.4";
public const string EDJE_FILE = "/usr/share/ffalarms/ffalarms.edj";
public const string ALARM_SH = "/usr/share/ffalarms/alarm.sh";
public const string ATD_CONTACT_ERR =
    "Could not contact atd daemon, the alarm may not work";
public const string AMIXER = "amixer";
public const string DBUS_NAME = "org.openmoko.projects.ffalarms.alarm";


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

    foreach (unowned string cmd in new string[] {AMIXER, player})
	if (Environment.find_program_in_path(cmd) == null)
	    throw new MyError.CONFIG("command %s not found".printf(cmd));
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
	filename, alarm_sh.printf(header, repeat, Shell.quote(alarm_cmd)));
    FileUtils.chmod(filename, 0755);
    int fd = open(trig, O_WRONLY | O_NONBLOCK);
    bool atd_error = (fd == -1 || fstat(fd, out st) != 0 ||
		      !S_ISFIFO(st.st_mode) || write(fd, "\n", 1) != 1);
    if (fd != -1)
	close(fd);
    if (atd_error)
	throw new MyError.CONFIG(ATD_CONTACT_ERR);
}


void schedule_alarms(Config cfg, Component? alarms=null) throws MyError
{
    // We schedule one occurence for each alarm as we do not yet have
    // a concept of unacknowledged past alarms
    Component alarms_;
    if (alarms == null)
	alarms = alarms_ = list_alarms(cfg);
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


// XXX may return time_t
ICal.Time next_alarm_as_utc(Component c)
{
    unowned TimeZone tz = local_tz();
    unowned TimeZone utc = TimeZone.get_utc_timezone();
    var t = time_t();
    var utc_now = ICal.Time.from_timet_with_zone(t, false, utc);
    ICal.Time tz_now = ICal.Time.from_timet_with_zone(t, false, tz);
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
    c.set_dtstart(ICal.Time.from_timet_with_zone(timestamp, false, local_tz()));
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
    c.set_dtstart(ICal.Time.from_timet_with_zone(timestamp, false, local_tz()));
    unowned Property p_rrule = c.get_first_property(PropertyKind.RRULE);
    if (rrule != null) {
	Recurrence r = Recurrence.from_string(rrule);
	if (p_rrule != null)
	    p_rrule.set_rrule(r);
	else
	    c.add_property(new Property.rrule(r));
    } else if (p_rrule != null) {
	c.remove_property(p_rrule);
    }
    if (summary != null && !Regex.match_simple("^\\s*$", summary)) {
	c.set_summary(summary);
    } else {
	unowned Property p = c.get_first_property(PropertyKind.SUMMARY);
	if (p != null)
	    c.remove_property(p);
    }
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
    static Regex rrule_re;

    public string to_string(string summary_prefix=" ")
    {
	var sb = new StringBuilder(GLib.Time.local(next.as_timet())
				   .format("%a %b %d %X %Y"));
	unowned Property p = comp.get_first_property(PropertyKind.RRULE);
	if (p != null)
	    sb.append_printf(" (%s)", rrule_str(p));
	unowned string s = comp.get_summary();
	if (s != null && s.length > 0)
	    sb.append_printf("%s%s", summary_prefix, s);
	return sb.str;
    }

    public string get_label(string part)
    {
	if (part == "elm.text") {
	    var sb = new StringBuilder(GLib.Time.local(next.as_timet())
				       .format("%a %b %d %X %Y"));
	    unowned Property p = comp.get_first_property(PropertyKind.RRULE);
	    if (p != null)
		sb.append_printf(" (%s)", rrule_str(p));
	    return sb.str;
	} else {
	    return comp.get_summary() ?? "";
	}
    }

    static string rrule_str(Property p)
    {
	var s = p.as_ical_string().strip();
	MatchInfo m;
	if (rrule_re == null)
	    try {
		rrule_re = new Regex("RRULE:FREQ=([A-Z]+)$");
	    } catch (RegexError e) {
		assert_not_reached();
	    }
	if (rrule_re.match(s, 0, out m))
	    return m.fetch(1).down();
	else
	    return s;
    }
}


/**
 * NOTE: if alarms parameter is deleted, result is no longer valid
 */
NextAlarm[] list_future_alarms(Component alarms)
{
    var arr = new NextAlarm[0];
    foreach (var c in alarms.begin_component(ComponentKind.ANY)) {
	var next = next_alarm_as_utc(c);
	if (! next.is_null_time())
	    arr += new NextAlarm() { comp=c, next=next };
    }
    Posix.qsort_r(arr, arr.length, sizeof(NextAlarm),
		  (a, b) => (((NextAlarm **)a)[0])->next.compare(
		      (((NextAlarm **)b)[0])->next), null);
    return arr;
}


public SList<AlarmInfo?> list_scheduled_alarms(Config cfg)
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
    var lst = new SList<AlarmInfo?>();
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

unowned string? nth_token(string buf, int nth)
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
		var time = ICal.Time.from_timet_with_zone(t, false, local_tz());
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
    unowned Edje.Object edje;
    int hour = -1;
    int minute = 0;
    bool showing_options = false;
    public delegate void SetAlarm(time_t timestamp,
				  string? recur, string? summary);
    SetAlarm set_alarm;
    Recurrence recur;
    bool recur_editable = true;
    string summary;

    public AddAlarm()
    {
	recur.clear(ref recur);
    }

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
	unowned Property p = c.get_first_property(PropertyKind.RRULE);
	if (p != null) {
	    recur = p.get_rrule();
	    recur_editable = (freq_cb(recur.freq) &&
			      recur.until.is_null_time() &&
			      recur.count == 0 &&
			      recur.interval == 1 &&
			      recur.by_second[0] == Recurrence.ARRAY_MAX &&
			      recur.by_minute[0] == Recurrence.ARRAY_MAX &&
			      recur.by_hour[0] == Recurrence.ARRAY_MAX &&
			      recur.by_month_day[0] == Recurrence.ARRAY_MAX &&
			      recur.by_year_day[0] == Recurrence.ARRAY_MAX &&
			      recur.by_week_no[0] == Recurrence.ARRAY_MAX &&
			      recur.by_month_day[0] == Recurrence.ARRAY_MAX &&
			      recur.by_set_pos[0] == Recurrence.ARRAY_MAX);
	}
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
	if (showing_options)
	    cl.time_get(out hour, out minute, null);
	if (options != null) {
	    if (recur_editable) {
		int i = 0, j = 0;
		foreach (unowned Check ck in wd.checks) {
		    if (ck.state_get())
			recur.by_day[j++] = recur_weekdays[i];
		    i++;
		}
		recur.by_day[(j < 7) ? j : 0] = Recurrence.ARRAY_MAX;
	    }
	    summary = Entry.markup_to_utf8(this.summary_e.entry_get());
	    if (summary != null)
		summary = summary.strip();
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
	    this.set_alarm(timestamp, recur.as_string(ref recur), summary);
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
	summary_e.size_hint_weight_set(1.0, 1.0);
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

	if (recur_editable) {
	    freq = new Hoversel(win);
	    freq.hover_parent_set(win);
	    freq_cb(recur.freq);
	    freq.item_add("Once", null, IconType.NONE,
			  () => freq_cb(RecurrenceFrequency.NO));
	    freq.item_add("Daily", null, IconType.NONE,
			  () => freq_cb(RecurrenceFrequency.DAILY));
	    freq.item_add("Weekly", null, IconType.NONE,
			  () => freq_cb(RecurrenceFrequency.WEEKLY));
	    freq.item_add("Monthly", null, IconType.NONE,
			  () => freq_cb(RecurrenceFrequency.MONTHLY));
	    freq.item_add("Yearly", null, IconType.NONE,
			  () => freq_cb(RecurrenceFrequency.YEARLY));
	    bx.pack_end(frame("Frequency", freq));
	    freq.show();

	    wd = new CheckGroup(win, weekdays);
	    if (recur.by_day[0] != Recurrence.ARRAY_MAX) {
		foreach (unowned Check ck in wd.checks)
		    ck.state_set(false);
		for (int i = 0; i < Recurrence.ARRAY_MAX &&
			 recur.by_day[i] != Recurrence.ARRAY_MAX; i++)
		    for (int j = 0; j < recur_weekdays.length; j++)
			if (recur.by_day[i] == recur_weekdays[j]) {
			    wd.checks[j].state_set(true);
			    break;
			}
	    }
	    bx.pack_end(frame("Weekdays", wd.bx));
	} else {
	    var lb = new Label(win);
	    lb.label_set(Recurrence.as_string(ref recur));
	    bx.pack_end(frame("Recurrence", lb));
	    swallow((owned) lb);
	}

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

    bool freq_cb(RecurrenceFrequency freq)
    {
	unowned string label;

	switch (freq) {
	case RecurrenceFrequency.NO:
	    label = "Once";
	    break;
	case RecurrenceFrequency.DAILY:
	    label = "Daily";
	    break;
	case RecurrenceFrequency.WEEKLY:
	    label = "Weekly";
	    break;
	case RecurrenceFrequency.MONTHLY:
	    label = "Monthly";
	    break;
	case RecurrenceFrequency.YEARLY:
	    label = "Yearly";
	    break;
	default:
	    return false;
	}
	recur.freq = freq;
	if (this.freq != null)
	    this.freq.label_set(label);
	return true;
    }
}

class Confirm : BaseWin
{
    Buttons bs;
    public delegate void Callback(string item);
    Callback yes_cb;
    unowned string item;

    public Confirm(Win? parent, string msg, string title,
		   Confirm.Callback cb, string item)
    {
	yes_cb = cb;
	this.item = item;

	win = new Win(parent);
	win.title_set(title);
	win.smart_callback_add("delete-request", this.close);
	win.resize(480, 640);

	var bg = new Bg(win);
	bg.size_hint_weight_set(1.0, 1.0);
	win.resize_object_add(bg);
	bg.show();
	swallow((owned) bg);

	var bx = new Box(win);
	bx.size_hint_weight_set(1.0, 1.0);
	win.resize_object_add(bx);
	bx.show();

	var hbx = new Box(win);
	hbx.horizontal_set(true);
	hbx.size_hint_weight_set(1.0, 1.0);
	hbx.size_hint_align_set(-1.0, 0.5);
	hbx.pack_end(pad("pad_small"));

	var lb = new Label(win);
	lb.line_wrap_set(true);
	lb.label_set(msg.replace("<", "&lt;").replace("\n", "<br>"));
	lb.size_hint_weight_set(1.0, 1.0);
	lb.size_hint_align_set(-1.0, 0.5);
	lb.show();
	hbx.pack_end(lb);

	hbx.pack_end(pad("pad_small"));
	hbx.show();
	bx.pack_end(hbx);

	bs = new Buttons(win);
	bs.add("Yes", this.yes);
	bs.add("No", this.close);
	bx.pack_end(bs.box);

	swallow((owned) bx);
	swallow((owned) hbx);
	swallow((owned) lb);
    }

    public void show()
    {
	win.show();
    }

    void yes()
    {
	yes_cb(item);
	close();
    }

    void close()
    {
	win = null;
    }
}

class AckWin : BaseWin
{
    Bg bg;
    Toggle ack;
    Buttons btns;
    Evas.Rectangle r;
    public delegate void Acknowledge(string uid, time_t time);
    Acknowledge acknowledge;
    bool exit_when_closed;
    dynamic DBus.Object alarm;
    string uid;
    time_t time;
    string time_s;
    string summary;

    public AckWin(dynamic DBus.Object alarm)
    {
	this.alarm = alarm;
    }

    public AckWin.standalone(Config cfg)
    {
	var uid = Environment.get_variable("FFALARMS_UID");
	var s = Environment.get_variable("FFALARMS_ATD_SCRIPT");
	time_t time = (s != null) ? s.to_int() : 0;
	dynamic DBus.Object alarm;
	if (uid == null) {
	    alarm = Main.bus.get_object(DBUS_NAME, "/", DBUS_NAME);
	} else {
	    // XXX night hack
	    while (true) {
		try {
		    alarm = dbus_g_proxy_new_for_name_owner(
			Main.bus, DBUS_NAME, "/", DBUS_NAME);
		    string a_uid = alarm.GetUID();
		    int a_time = alarm.GetTime();
		    if (uid == a_uid && time == a_time)
			break;
		} catch (DBus.Error e) {
		    if (! (e is DBus.Error.NAME_HAS_NO_OWNER))
			message("dbus error: %s", e.message);
		}
		usleep(300000);
	    }
	}
	this(alarm);
	exit_when_closed = true;
	set_data(cfg, uid, time);
    }

    public void show(Win? parent, Acknowledge acknowledge)
    {
	this.acknowledge = acknowledge;
	win = new Win(null, "acknowledge", WinType.BASIC);
	win.title_set("Acknowledge alarm");
	win.smart_callback_add("delete-request", this.close);

	bg = new Bg(win);
	bg.size_hint_weight_set(1.0, 1.0);
	win.resize_object_add(bg);
	bg.show();

	var bx = new Box(win);
	bx.size_hint_weight_set(1.0, 1.0);
	win.resize_object_add(bx);
	bx.show();

	var hbx = new Box(win);
	hbx.horizontal_set(true);
	hbx.size_hint_weight_set(1.0, 1.0);
	hbx.size_hint_align_set(-1.0, 0.5);
	hbx.pack_end(pad("pad_small"));

	var lb = new Label(win);
	lb.line_wrap_set(true);
	lb.label_set(
	    "<b>Acknowledge the running alarm</b><br><br>%s<br><br>%s"
	    .printf(time_s ?? "",
		    (summary != null) ?
		    summary.replace("<", "&lt;").replace("\n", "<br>") : ""));
	lb.size_hint_weight_set(1.0, 1.0);
	lb.size_hint_align_set(-1.0, 0.5);
	lb.show();
	hbx.pack_end(lb);
	swallow((owned) lb);

	hbx.pack_end(pad("pad_small"));
	hbx.show();
	bx.pack_end(hbx);
	swallow((owned) hbx);

	lb = new Label(win);
	lb.label_set("(double click anywhere to snooze)");
	bx.pack_end(lb);
	lb.show();
	swallow((owned) lb);
	bx.pack_end(pad("pad_medium"));

	ack = new Toggle(win);
	ack.states_labels_set("Acknowledge", "Not acknowledged");
	ack.scale_set(2.0);
	bx.pack_end(ack);
	ack.show();
	ack.smart_callback_add("changed", ack_changed);
	bx.pack_end(pad("pad_small"));

	btns = new Buttons(win);
	unowned Button close = btns.add("Close", this.close_maybe_ack);
	close.hide();
	bx.pack_end(btns.box);

	swallow((owned) bx);

	r = new Evas.Rectangle(win.evas_get());
	r.size_hint_weight_set(1.0, 1.0);
	win.resize_object_add(r);
	r.color_set(0, 0, 0, 0);
	r.repeat_events_set(true);
	evas_object_event_callback_add(r, Evas.CallbackType.MOUSE_DOWN, snooze_clicked);
	r.show();

	win.resize(480, 640);
	win.show();
    }

    void snooze_clicked(Evas.Canvas e, Evas.Object obj, void *event_info)
    {
	var ev = (EventMouseDown *) event_info;
	if ((ev->flags & ButtonFlags.DOUBLE_CLICK) != 0) {
	    try {
		alarm.Snooze(uid);
	    } catch (DBus.Error e) {
		debug("dbus error: %s", e.message);
	    }
	}
    }

    void ack_changed()
    {
	if (ack.state_get())
	    btns.buttons[0].show();
    }

    public void set_data(Config cfg, string? uid, time_t time)
    {
	this.uid = uid;
	this.time = time;
	try {
	    var alarms = list_alarms(cfg);
	    foreach (var a in alarms.begin_component())
		if (a.get_uid() == uid)
		    summary = a.get_summary();
	} catch (MyError e) {
	    GLib.message("Could not list alarms: %s", e.message);
	}
	if (time != 0)
	    time_s = (GLib.Time.local(time).format("%a %b %d %X %Y"));
    }

    void close_maybe_ack()
    {
	if (ack.state_get()) {
	    try {
		alarm.Stop(uid);
	    } catch (DBus.Error e) {
		message("dbus error %s", e.message);
	    }
	    acknowledge(uid, time);
	}
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
    unowned Config cfg;

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

	unowned Edje.Object edje = (Edje.Object) lt.edje_get();
	if (cfg.led_color != null) {
	    unowned int[] c = cfg.led_color;
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
	if (value == -1 && brightness == -1 || Main.bus == null)
	    return;
	try {
	    dynamic DBus.Object display = Main.bus.get_object(
		"org.freesmartphone.odeviced",
		"/org/freesmartphone/Device/Display/0",
		"org.freesmartphone.Device.Display");
	    if (brightness == -1)
		brightness = display.GetBrightness();
	    display.SetBrightness((value != -1) ? value : brightness);
	    if (value == -1)
		brightness = -1;
	} catch (DBus.Error e) {
		debug("D-Bus error: %s", e.message);
	}
    }
}

class Alarms
{
    public Genlist lst;
    GenlistItemClass itc;
    public Component alarms;
    NextAlarm[] future;

    public Alarms(Elm.Object parent)
    {
	lst = new Genlist(parent);
	itc.item_style = "double_label";
	itc.func.label_get = (GenlistItemLabelGetFunc) get_label;
    }

    public void update(Config cfg) throws MyError
    {
	if (alarms != null)
	    lst.clear();
	alarms = list_alarms(cfg);
	future = list_future_alarms(alarms);
	foreach (unowned NextAlarm a in future)
	    lst.item_append(itc, a, null, Elm.GenlistItemFlags.NONE, null);
    }

    public unowned NextAlarm? selected_item_get()
    {
	unowned GenlistItem item = lst.selected_item_get();
	return (item != null) ? (NextAlarm) item.data_get() : null;
    }

    public unowned Component? selected_alarm()
    {
	unowned GenlistItem item = lst.selected_item_get();
	return (item != null) ? ((NextAlarm) item.data_get()).comp : null;
    }

    static string get_label(void *data, Elm.Object? obj, string part)
    {
	return ((NextAlarm) data).get_label(part);
    }
}


class Message
{
    Win w;
    Label tt;
    Box bx;
    Box hbx;
    Button bt;
    Label lb;
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
	lb = new Label(w);
	lb.line_wrap_set(true);
	lb.label_set(msg.replace("<", "&lt;").replace("\n", "<br>"));
	lb.size_hint_align_set(-1.0, 0.5); // fill horizontally
	lb.size_hint_weight_set(1.0, 1.0); // expand
	lb.show();
	hbx.pack_end(lb);
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
    unowned Elm.Object parent;

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
    LEDClock clock;
    AddAlarm aa;
    AckWin ack;
    Confirm del;
    Alarms alarms;
    InwinMessageQueue msgs;
    InwinMessageQueue.MessageFunc message;
    Config cfg;
    string edje_file;
    string at_spool;
    string config_file;
    HoverButtons options;
    string edited_alarm_uid;

    public MainWin(string edje_file, string at_spool, string? config_file)
    {
	this.edje_file = edje_file;
	this.at_spool = at_spool;
	this.config_file = config_file;
    }

    void close()
    {
	ack = null; // avoid double memory free (edje swallowed buttons)
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

	alarms = new Alarms(win);
	alarms.lst.size_hint_weight_set(1.0, 1.0);
	alarms.lst.size_hint_align_set(-1.0, -1.0);
	bx.pack_end(alarms.lst);
	alarms.lst.show();

	btns = new Buttons(win);
	btns.add("Add", add_alarm);
	options = new HoverButtons(win);
	options.add("Acknowledge", show_ack);
	options.add("Edit", edit_alarm);
	options.add("Delete", show_delete_alarm);
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
	update_alarms();
	this.schedule_alarms(alarms.alarms);
	(void *) new EventHandler(EventType.SIGNAL_USER, sig_user);

	win.resize(480, 640);
	win.show();
    }

    void schedule_alarms(Component? alarms=null)
    {
	try {
	    Ffalarms.schedule_alarms(cfg, alarms);
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

    public void show_standalone_ack()
    {
	cfg = new Config(at_spool);
	try {
	    cfg.load_from_file(config_file);
	} catch (MyError e) {
	    GLib.message("Error reading config file: %s".printf(e.message));
	    cfg.use_defaults();
	}
	ack = new AckWin.standalone(cfg);
	ack.show(null, acknowledge);
    }

    void show_ack()
    {
	dynamic DBus.Object alarm;
	string uid;
	int time;

	try {
	    alarm = dbus_g_proxy_new_for_name_owner(Main.bus,
						    DBUS_NAME, "/", DBUS_NAME);
	    uid = alarm.GetUID();
	    time = alarm.GetTime();
	} catch (DBus.Error e) {
	    message((e is DBus.Error.NAME_HAS_NO_OWNER) ?
		    "No alarm is playing" : "dbus error: %s".printf(e.message),
		    "Acknowledge alarm");
	    return;
	}
	ack = new AckWin(alarm);
	ack.set_data(cfg, (owned) uid, (time_t) time);
	ack.show(win, acknowledge);
    }

    void acknowledge(string uid, time_t time)
    {
	acknowledge_alarm(uid, time, cfg);
	Ffalarms.schedule_alarms(cfg);
    }

    void show_delete_alarm()
    {
	unowned NextAlarm item = alarms.selected_item_get();
        if (item != null) {
	    del = null;
	    del = new Confirm(
		null, "Do you really want to delete the alarm:\n\n%s"
		.printf(item.to_string()),
		"Delete alarm", this.delete_alarm, item.comp.get_uid());
	    del.show();
        } else {
	    message("No alarm selected", "Delete alarm");
	}
    }

    void add_alarm()
    {
	edited_alarm_uid = null;
	(aa = new AddAlarm()).show(win, edje_file, set_alarm_);
    }

    void edit_alarm()
    {
	unowned Component c = alarms.selected_alarm();
	if (c != null) {
	    edited_alarm_uid = c.get_uid();
	    (aa = new AddAlarm()).show(win, edje_file, set_alarm_);
	    aa.set_data(c);
	} else {
	    message("You must select a single alarm to be edited",
		    "Edit alarm");
	}
    }

    // hack: I recreate all the list as removing from the list
    // segfaults so the list owns the items (XXX unowned?)
    // XXX probably free_function="" try

    public void delete_alarm(string uid)
    {
	try {
	    Ffalarms.delete_alarm(uid, cfg);
	} catch (MyError e) {
	    message(e.message, "Delete alarms");
	}
	this.schedule_alarms();
	// XXX dirty update
	update_alarms();
    }

    public void update_alarms()
    {
	try {
	    alarms.update(cfg);
	} catch (MyError e) {
	    message(e.message);
	}
    }
}


public class Config
{
    KeyFile ini;
    public string at_spool;
    public const string DEFAULT_CONFIG = "~/.ffalarmsrc";
    public const int BRIGHTNESS = 33;
    public string alarm_script;
    public int alarm_volume_initial;
    public int alarm_volume_final;
    public int alarm_volume_inc_interval;
    public int snooze_cnt;
    public int snooze_interval;
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
	snooze_cnt = 5;
	snooze_interval = 60;
    }

    public void load_from_file(string? filename) throws MyError
    {
	ini = new KeyFile();
	try {
	    ini.load_from_file(
		(filename != null) ? filename : expand_home(DEFAULT_CONFIG),
		KeyFileFlags.NONE);
	    ini.set_list_separator(',');
	    if (ini.has_key("alarm", "file"))
		alarm_file = expand_home(ini.get_value("alarm", "file"));
	    if (ini.has_key("alarm", "player"))
		player = ini.get_value("alarm", "player");
	    if (ini.has_key("alarm", "repeat"))
		repeat = ini.get_integer("alarm", "repeat");
	    else if (ini.has_key("alarm", "file") ||
		     ini.has_key("alarm", "player"))
		repeat = 1;
	    if (ini.has_key("alarm", "alarm_script"))
		alarm_script = expand_home(ini.get_value("alarm",
							 "alarm_script"));
	    if (ini.has_key("alarm", "volume"))
		read_alarm_volume();
	    if (ini.has_key("alarm", "snooze"))
		read_snooze();
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

    void read_snooze() throws MyError
    {
	try {
	    int[] snooze = ini.get_integer_list("alarm", "snooze");
	    if (snooze.length == 2) {
		snooze_cnt = snooze[0];
		snooze_interval = snooze[1];
	    } else {
		throw new MyError.CONFIG("Snooze must match: \"snooze_cnt, snooze_interval\"");
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
	    throw new MyError.CONFIG("Key file contains key '%s' in group '%s' which has value that does not match \"0-255, 0-255, 0-255\"", key, group);
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


[DBus (name = "org.freesmartphone.Notification")]
interface Notification {
    public abstract void alarm() throws DBus.Error;
}

[DBus (name = "org.openmoko.projects.ffalarms.alarm")]
interface AlarmControler {
    public abstract string GetUID() throws DBus.Error;
    public abstract int GetTime() throws DBus.Error;
    public abstract void Snooze(string uid) throws DBus.Error;
    public abstract void Stop(string uid) throws DBus.Error;
}


class Alarm : GLib.Object, Notification, AlarmControler {
    const string[] AMIXER_CMD = {AMIXER, "--stdin", "--quiet", null};
    const string[] AMIXER_GET_PCM_CMD = {AMIXER, "sget", "PCM", null};
    const string SET_PCM_FMT = "sset PCM %g%%\n";
    const string SET_PCM_2_FMT = "sset PCM %d,%d\n";

    string[] play_argv;
    int cnt;
    int repeat;
    int snooze_cnt;
    uint snooze_id = 0;
    static bool snoozing;
    Config cfg;
    double volume;
    double volume_inc_step;
    uint inc_volume_id = 0;
    FileStream mixer;
    GLib.MainLoop ml;
    static pid_t player_pid = 0;
    enum Action { NONE = 0, EXIT, SNOOZE }
    static Action action = Action.NONE;
    DBus.Connection bus;
    string unique_name;
    bool in_queue;
    dynamic DBus.Object usage;
    dynamic DBus.Object audio;
    dynamic DBus.Object xbus;
    bool scenario_pushed = false;
    string uid;
    int[] saved_pcm_volume = {-1, -1};

    public Alarm(string play_cmd, int cnt, Config cfg) {
	this.cnt = this.repeat = cnt;
	try {
	    Shell.parse_argv(play_cmd, out play_argv);
	} catch (ShellError e) {
	    die(e.message);
	}
	this.cfg = cfg;
	uid = Environment.get_variable("FFALARMS_UID") ?? "";
    }

    public void run()
    {
	try {
	    schedule_alarms(cfg);
	} catch (GLib.Error e) {
	    // XXX should display GUI error
	    warning(e.message);
	}

	ml = new GLib.MainLoop(null, false);
	try {
	    bus = DBus.Bus.get(DBus.BusType.SYSTEM);
	    unique_name = dbus_bus_get_unique_name(
		(DBus.RawConnection*)bus.get_connection());
	} catch (DBus.Error e) {
	    debug("dbus error: %s", e.message);
	}
	if (bus != null) {
	    usage = bus.get_object(
		"org.freesmartphone.ousaged", "/org/freesmartphone/Usage",
		"org.freesmartphone.Usage");
	    request_resources();
	    bus.register_object("/", this);
	    audio = bus.get_object(
		"org.freesmartphone.odeviced",
		"/org/freesmartphone/Device/Audio",
		"org.freesmartphone.Device.Audio");
	    xbus = bus.get_object("org.freedesktop.DBus",
				  "/org/freedesktop/DBus",
				  "org.freedesktop.DBus");
	    xbus.NameOwnerChanged += wait_for_name_ownership;
	}
	signal(SIGTERM, sigterm);
	signal(SIGINT, sigterm);
	snooze_cnt = cfg.snooze_cnt;

	alarm_begin();
	ml.run();
    }

    void request_resources()
    {
	usage.RequestResource("CPU", async_result);
	usage.RequestResource("Display", async_result);
    }

    void async_result(GLib.Error e) {
	if (e != null)
	    GLib.stderr.printf("end call error: %s\n", e.message);
    }

    static void sigterm(int signal)
    {
	if (player_pid != 0) {
	    kill(player_pid, SIGTERM);
	    player_pid = 0;
	}
	if (snoozing)
	    Posix.exit(0);
	else
	    action = Action.EXIT;
    }

    public void Snooze(string uid) throws DBus.Error
    {
	if (uid != this.uid)
	    return;
	if (action == Action.NONE)
	    action = Action.SNOOZE;
	if (player_pid != 0) {
	    kill(player_pid, SIGTERM);
	    player_pid = 0;
	}
    }

    public void Stop(string uid) throws DBus.Error
    {
	if (uid != this.uid)
	    return;
	action = Action.EXIT;
	if (player_pid != 0) {
	    kill(player_pid, SIGTERM);
	    player_pid = 0;
	}
	// XXX similar for sigterm
	if (snoozing)
	    ml.quit();
    }

    public string GetUID() throws DBus.Error
    {
	return uid;
    }

    public int GetTime() throws DBus.Error
    {
	var s = Environment.get_variable("FFALARMS_ATD_SCRIPT");
	return (s != null) ? s.to_int() : 0;
    }

    void wait_for_name_ownership(dynamic DBus.Object o, string name,
				 string prev_owner, string new_owner)
    {
	if (in_queue && name == DBUS_NAME && new_owner == unique_name) {
	    in_queue = false;
	    alarm_begin();
	}
    }

    void alarm_begin()
    {
	if (bus != null) {
	    var err = DBus.RawError();
	    int reply = dbus_bus_request_name(
		(DBus.RawConnection*)bus.get_connection(),
		DBUS_NAME, 0, ref err);
	    if (err.is_set()) {
		warning("dbus error: %s\n", err.message);
	    } else if (reply == DBus.RequestNameReply.IN_QUEUE) {
		in_queue = true;
		return;	  /* waiting */
	    }
	}
	in_queue = false;
	begin_volume_inc_loop();
	alarm_loop();
    }

    void begin_volume_inc_loop()
    {
	if (audio != null && !scenario_pushed) {
	    try {
		string scenario = audio.GetScenario();
		if (scenario != "stereoout") {
		    audio.PushScenario("stereoout");
		    scenario_pushed = true;
		}
	    } catch (DBus.Error e) {
		debug("D-Bus error: %s", e.message);
	    }
	}
	if (cfg.alarm_volume_initial == -1)
	    return;
	if (mixer == null) {
	    if (cfg.alarm_volume_initial < cfg.alarm_volume_final)
		volume_inc_step = (((double)cfg.alarm_volume_final
				    - cfg.alarm_volume_initial)
				   / cfg.alarm_volume_inc_interval);
	    try {
		int stdin;
		Process.spawn_async_with_pipes(
		    null, AMIXER_CMD, null, SpawnFlags.SEARCH_PATH,
		    null, null, out stdin, null, null);
		mixer = FileStream.fdopen(stdin, "w");
	    } catch (SpawnError e) {
		// we continue with default volume
		GLib.message("Alarm.run: %s", e.message);
		return;
	    }
	}
	try {
	    string pcm_volume;
	    Process.spawn_sync(null, AMIXER_GET_PCM_CMD, null,
			       SpawnFlags.SEARCH_PATH,
			       null, out pcm_volume, null, null);
	    saved_pcm_volume[0] = -1;
	    MatchInfo m;
	    var re = new Regex(
		" +Front (?:Left|Right):(?: Playback)? ([0-9]+)");
	    if (re.match(pcm_volume, 0, out m)) {
		int i = 0;
		while (m.matches() && i < 2) {
		    saved_pcm_volume[i++] = m.fetch(1).to_int();
		    m.next();
		}
	    }
	} catch (SpawnError e) {
	    GLib.message("Alarm.run: %s", e.message);
	} catch (RegexError e) {
	    debug("regex error: %s", e.message);
	}
	volume = cfg.alarm_volume_initial;
	mixer.printf(SET_PCM_FMT, volume);
	mixer.flush();
	if (volume < cfg.alarm_volume_final)
	    inc_volume_id = Timeout.add(1000, inc_volume);
    }

    bool inc_volume()
    {
	volume += volume_inc_step;
	if (volume > cfg.alarm_volume_final)
	    volume = cfg.alarm_volume_final;
	mixer.printf(SET_PCM_FMT, volume);
	mixer.flush();
	if (volume == cfg.alarm_volume_final)
	    inc_volume_id = 0;
	return volume < cfg.alarm_volume_final;
    }

    void release_audio()
    {
	if (inc_volume_id != 0) {
	    Source.remove(inc_volume_id);
	    inc_volume_id = 0;
	}
	if (saved_pcm_volume[0] != -1) {
	    mixer.printf(SET_PCM_2_FMT,
			 saved_pcm_volume[0], saved_pcm_volume[1]);
	    mixer.flush();
	    saved_pcm_volume[0] = -1;
	}
	if (scenario_pushed) {
	    try {
		string s = audio.PullScenario();
		scenario_pushed = false;
	    } catch (DBus.Error e) {
		debug("D-Bus error: %s", e.message);
	    }
	}
    }

    void snooze()
    {
	cnt = repeat;
	usage.ReleaseResource("Display", async_result);
	dynamic DBus.Object alarm = bus.get_object(
	    "org.freesmartphone.otimed", "/org/freesmartphone/Time/Alarm",
	    "org.freesmartphone.Time.Alarm");
	// XXX if we release name after SetAlarm notification will not come
	var err = DBus.RawError();
	dbus_bus_release_name(
	    (DBus.RawConnection*)bus.get_connection(), DBUS_NAME, ref err);
	if (err.is_set())
	    warning("dbus error: %s\n", err.message);
	try {
	    // register alarm
	    alarm.SetAlarm(unique_name, (int)(time_t() + cfg.snooze_interval));
	    // SetAlarm is cheating, we have to wait to release CPU
	    snoozing = true;
	    if (action == Action.EXIT)
		ml.quit();
	    snooze_id = Timeout.add(3000, _snooze);
	} catch (DBus.Error e) {
	    warning("quit instead of snooze: dbus error: %s", e.message);
	    ml.quit();
	}
    }

    bool _snooze()
    {
	usage.ReleaseResource("CPU", async_result);
	return false;
    }

    public void alarm() throws DBus.Error
    {
	Source.remove(snooze_id);
	snooze_id = 0;
	action = Action.NONE;
	snoozing = false;
	request_resources();
	alarm_begin();
    }

    void alarm_loop(Pid p = 0, int status = 0)
    {
	Pid pid;

	if (cnt-- == 0 || action != Action.NONE) {
	    release_audio();
	    if (snooze_cnt-- > 0 && bus != null && action != Action.EXIT)
		snooze();
	    else
		ml.quit();
	    return;
	}
	if (p != (Pid) 0)
	    usleep(300000); // XXX handle snooze coming during usleep
	signal(SIGTERM, SIG_IGN);
	signal(SIGINT, SIG_IGN);
	try {
	    Process.spawn_async(
		null, play_argv, null,
		SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD,
		null, out pid);
	} catch (SpawnError e) {
	    release_audio();
	    die(e.message);
	}
	player_pid = (pid_t) pid;
	signal(SIGTERM, sigterm);
	signal(SIGINT, sigterm);
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

    public static DBus.Connection bus;

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
	  "show the acknowledge window", null },
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
	new Main();	       // just to initialize static fields
	if (args.length > 1)
	    process_args(ref args);
	Elm.init(args);
	try {
	    bus = DBus.Bus.get(DBus.BusType.SYSTEM);
	} catch (DBus.Error e) {
	    debug("dbus error: %s", e.message);
	}
	var mw = new MainWin(edje_file, at_spool, config_file);
	if (! puzzle) {
	    mw.show();
	} else {
	    mw.show_standalone_ack();
	}
	Elm.run();
	Elm.shutdown();
    }

    static void process_args(ref unowned string[] args)
    {
	Config cfg = null;
	{
	    var oc = new OptionContext(" - finger friendly alarms");
	    oc.add_main_entries(options, null);
	    try {
		oc.parse(ref args);
	    } catch (GLib.OptionError e) {
		die(e.message);
	    }
	}
	if (version) {
	    GLib.stdout.printf("ffalarms-%s\n", VERSION);
	    Posix.exit(0);
	}
	if (play_cmd != null) {
	    int cnt = (args[1] != null) ? args[1].to_int() : 1;
	    cfg = new Config(at_spool);
	    try {
		cfg.load_from_file(config_file);
	    } catch (MyError e) {
		warning("Error reading config file: %s. Default configuration will be used."
			.printf(e.message));
		cfg.use_defaults();
	    }
	    new Alarm(play_cmd, (cnt > 0) ? cnt : 1, cfg).run();
	    Posix.exit(0);
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
		foreach (unowned string? s in alarms) {
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
	    SList<AlarmInfo?> lst = null;
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
	if (kill) {
	    try {
		bus = DBus.Bus.get(DBus.BusType.SYSTEM);
		dynamic DBus.Object alarm = dbus_g_proxy_new_for_name_owner(
		    bus, DBUS_NAME, "/", DBUS_NAME);
		string uid = alarm.GetUID();
		alarm.Stop(uid);
	    } catch (DBus.Error e) {
		if (e is DBus.Error.NAME_HAS_NO_OWNER)
		    die("No alarm is playing");
		else
		    die("dbus error: %s".printf(e.message));
	    }
	}
	if (list)
	    try {
		display_alarms_list(cfg);
	    } catch (MyError e) {
		die(e.message);
	    }
	if (list || kill || alarms != null || deletes != null)
	    Posix.exit(0);
    }
}

}
