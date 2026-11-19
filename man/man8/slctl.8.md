SLCTL(8) - System Manager's Manual

# NAME

**slctl** - control the Starlink dish monitor

# SYNOPSIS

**slctl**
**init**|**passwd**|**status**|**once**
\[**-c**&nbsp;*file*]
\[**-d**&nbsp;*db*]
\[**-l**&nbsp;*host:port*]

# DESCRIPTION

**slctl**
is the operator tool for
sld(8).
It does not fork a daemon.

**init**

> Create the database and store the admin user and password.
> Refuses uid 0 with the line

> > slctl: doas -u \_sl slctl init

> Run as
> **\_sl**,
> it prompts:

> > Admin user \[admin]:
> > Password:
> > Repeat password:

> An empty user name stores
> `admin`.
> The password is read with echo off, must be at least 8 characters,
> and must be entered the same way twice.
> It is stored with
> crypt(3)
> bcrypt
> (`$2b$`).
> A 32-byte session key is read from
> */dev/urandom*.
> **sld**
> does not rotate that key while it is running.
> A second
> **init**
> prints that the database is already initialized and does not change
> the password.
> The prompt needs a terminal.

**passwd**

> Replace the admin user, the password, and the session key on a
> database that
> **init**
> has already created.
> Refuses uid 0 with the line

> > slctl: doas -u \_sl slctl passwd

> The prompts and the password rules are the same as
> **init**.
> An empty user name stores
> `admin`.
> On success it prints

> > slctl: admin user reset
> > slctl: rcctl restart sld

> Existing login cookies stay valid until
> **sld**
> is restarted, because the running process still holds the previous
> session key.
> The command writes those settings and does not roll up stored samples.
> A database that is not initialized is left untouched, and the command
> prints the same
> **init**
> hint
> **sld**
> prints.

**status**

> Print whether the database is initialized, which driver is configured,
> the database path, the dish host, the HTTP port, and how many history
> samples are stored.
> This opens the database read-only.
> The database is mode 0600 and owned by
> **\_sl**,
> so this is run as
> **\_sl**
> or as root.

**once**

> Probe the dish once and print one status document as JSON.
> This does not start
> sld(8)
> and does not write the database.
> If the dish port does not answer, the refusal is printed on standard
> error and the exit status is still 0.

The options are as follows:

**-c** *file*

> Configuration file.

**-d** *db*

> SQLite file for this command.
> Overrides
> *db\_path*.

**-l** *host:port*

> Listen address recorded for this command.
> **once**
> does not serve HTTP.

# FILES

*/etc/sl.conf*

> Default configuration when
> **-c**
> is passed by the operator.
> See
> sl.conf(5).

*/var/sl/sl.db*

> Database created by
> **init**
> when
> **-d**
> is not used.

# EXIT STATUS

**init**
exits non-zero when run as root, when the prompt cannot be read,
or when the database directory is missing.
**passwd**
exits non-zero in those cases and when the database is not
initialized.
**status**
exits non-zero when the database cannot be opened.
**once**
exits 0 after printing status JSON, and also exits 0 when the dish
port does not answer.

# SEE ALSO

crypt(3),
sl.conf(5),
sld(8)

OpenBSD 8.0 - October 22, 2026 - SLCTL(8)
