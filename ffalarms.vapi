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

[CCode (cheader_filename="stdio.h")]
public GLib.FileStream? popen(string cmd, string mode);

// getline is GNU extension
[CCode (cheader_filename="stdio.h")]
public size_t getline(ref char[] line, GLib.FileStream stream);

[CCode (cheader_filename="stdlib.h")]
public long strtol(string s, out weak string endptr = null, int _base = 0);
