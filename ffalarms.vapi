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

public Posix.sighandler_t SIG_IGN;

[CCode (cheader_filename="stdio.h")]
public GLib.FileStream? popen(string cmd, string mode);

[CCode (cheader_filename="stdlib.h")]
public long strtol(string s, out weak string endptr = null, int _base = 0);

public unowned string dbus_bus_get_unique_name(DBus.RawConnection connection);
public int dbus_bus_request_name(
    DBus.RawConnection connection, string name, uint flags,
    ref DBus.RawError error);
public int dbus_bus_release_name(
    DBus.RawConnection connection, string name, ref DBus.RawError error);

DBus.Object dbus_g_proxy_new_for_name_owner(
    DBus.Connection connection,
    string name, string path, string? interface_ = null) throws DBus.Error;

[CCode (cname = "Evas_Object_Event_Cb", instance_pos = 0)]
public delegate void ObjectEventCallback(
    Evas.Canvas e, Evas.Object obj, void* event_info);

public void evas_object_event_callback_add(
    Evas.Object self, Evas.CallbackType type, ObjectEventCallback func);

[Flags]
[CCode (cprefix = "EVAS_BUTTON_", cname = "Evas_Button_Flags")]
public enum ButtonFlags
{
    NONE,
    DOUBLE_CLICK,
    TRIPLE_CLICK
}

[Compact]
[CCode (cname = "Evas_Event_Mouse_Down")]
public class EventMouseDown
{
    public ButtonFlags flags;
}
