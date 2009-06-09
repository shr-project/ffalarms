using GLib;
using Posix;

// XXX IMHO should be in posix.vapi
[CCode (cheader_filename="unistd.h,sys/types.h")]
public pid_t getpid();

[CCode (cheader_filename="stdio.h")]
public FileStream? popen(string cmd, string mode);

// getline is GNU extension
[CCode (cheader_filename="stdio.h")]
public size_t getline(ref char[] line, FileStream stream);

[CCode (cheader_filename="stdlib.h")]
public long strtol(string s, out weak string endptr = null, int _base = 0);
