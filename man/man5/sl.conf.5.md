SL.CONF(5) - File Formats Manual

# NAME

**sl.conf** - Starlink dish monitor configuration

# DESCRIPTION

**sl.conf**
is the configuration file for
sld(8)
and
slctl(8).
The installed path is
*/etc/sl.conf*.
Lines are
`key = value`.
Blank lines and lines whose first non-whitespace character is
'`#`'
are ignored.
Unknown keys are rejected.

sld(8)
reads the file as user
**\_sl**.
The file mode is 0640, owner
**root:\_sl**,
so a password stored in
*pg\_password*
is not world-readable.
`SIGHUP`
and
**rcctl reload sld**
read the file again.
See
sld(8)
for which keys apply immediately.

Keys and their defaults:

*db*

> `sqlite`
> or
> `pg`.

*db\_path*

> */var/sl/sl.db*.
> The SQLite file.
> Ignored when
> *db*
> is
> `pg`.
> **-d**
> overrides it for one process.

*listen*

> `127.0.0.1:8080`.
> Must be
> `host:port`.
> One line.
> The port is 0 or at least 1024.

*dish\_host*

> `192.168.100.1`.
> A suffix
> `:port`
> replaces the default port 9200.

*dish\_interval\_s*

> `30`.
> Minimum 2.

*log\_level*

> `info`
> or
> `debug`.
> `debug`
> records rollup bucket counts and which table a chart read.
> The session secret, the password, and
> *pg\_password*
> are not logged.

*raw\_retention\_days*

> `90`.

*hourly\_rollup\_days*

> `365`.

*minutely\_retention\_days*

> `730`.

*rollup\_interval\_s*

> `60`.
> Minimum 1.

*ping\_targets*

> `1.1.1.1,8.8.8.8`.
> Comma-separated hosts.

*ping\_interval\_s*

> `10`.

*disconnect\_failures*

> `3`.

*spike\_ms*

> `200`.

*spike\_min\_s*

> `30`.

*latitude*, *longitude*

> Decimal degrees.
> Set both or neither.
> Setting both starts the weather process.

*pg\_host*, *pg\_port*, *pg\_db*, *pg\_user*, *pg\_password*

> PostgreSQL connection.
> *pg\_host*
> is the directory of the local socket when it begins with a slash.
> *db* = `pg`
> requires
> *pg\_db*.

# FILES

*/etc/sl.conf*

> The file
> sld(8)
> is started with.

*/usr/local/share/examples/slmon/sl.conf*

> Sample installed with the package.

# SEE ALSO

slctl(8),
sld(8)

OpenBSD 8.0 - October 22, 2026 - SL.CONF(5)
