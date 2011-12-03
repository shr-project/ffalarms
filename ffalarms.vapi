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

[CCode (cname = "Evas_Object_Event_Cb", instance_pos = 0)]
public delegate void ObjectEventCallback(
    Evas.Canvas e, Evas.Object obj, void* event_info);

public void evas_object_event_callback_add(
    Evas.Object self, Evas.CallbackType type, ObjectEventCallback func);

[Compact]
[CCode (cname = "Evas_Event_Mouse_Down")]
public class EventMouseDown
{
    public Evas.ButtonFlags flags;
}

[CCode (cheader_filename = "sys/stat.h")]
int lstat(string filename, out Posix.Stat buf);
