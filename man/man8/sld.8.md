SLD(8) - System Manager's Manual

# NAME

**sld** - Starlink dish monitor daemon

# SYNOPSIS

**sld**
\[**-F**]
\[**-n**]
\[**-c**&nbsp;*file*]
\[**-d**&nbsp;*db*]
\[**-l**&nbsp;*host:port*]

# DESCRIPTION

**sld**
records samples from a Starlink dish and a few local health signals,
and serves them on its HTTP listener.
It is an unofficial monitor.
It is not a SpaceX program and it does not speak for the dish operator.
The
OpenBSD
package name is
*slmon*.

The dish protocol is the public Device Handle service.
The default dish address is
`192.168.100.1`
port 9200.
A host with no route to that address must set
*dish\_host*
before live samples will appear.

**sld**
forks into the background, calls
setsid(2),
and logs to
syslog(3)
with tag
**sld**
and facility
**daemon**.
Standard input, output, and error are then
*/dev/null*.
**-F**
stays in the foreground and writes those lines to standard error.
**-n**
reads the configuration and exits.
It does not open the database and it does not listen.

The database must already exist.
**sld**
does not prompt and does not create it.
If it is missing or has no admin password,
**sld**
writes these lines to standard error and to the log, then exits
non-zero, before it forks:

	sld: /var/sl/sl.db is not initialized
	sld: doas -u _sl slctl init

rc(8)
discards that standard error.
The log lines are the record after boot.
Create the database with
slctl(8)
**init**
as
**\_sl**,
then
**rcctl enable sld**
and
**rcctl start sld**.
**passwd**
replaces the admin user and password later.

**-F**
runs until
`SIGTERM`
or
`SIGINT`.
`SIGHUP`
does not stop
**sld**.
It re-reads the configuration file.
A file that does not parse is logged and the running configuration
is left as it was.

listen, dish, watchdog, weather

> Each
> *listen*
> line is bound again and the HTTP process is restarted.
> A line that fails is logged.
> The addresses that bound replace the previous set.
> If none bind, the previous sockets stay.
> *dish\_host*
> and
> *dish\_interval\_s*
> restart the dish process.
> Ping, spike, and disconnect keys restart the watchdog.
> *latitude*
> and
> *longitude*
> start or stop the weather process.
> The HTTP process is restarted on every successful reload so the page
> revision matches the configuration it shows.

database

> *db*,
> *db\_path*,
> and the
> *pg\_\*&zwnj;*
> keys are read.
> When one of them differs from the open database, the log says those
> values wait for
> **rcctl restart sld**,
> and the open database stays.
> The other keys in the same file still apply.

The options are as follows:

**-c** *file*

> Configuration file.
> **rcctl**
> passes
> **-c** */etc/sl.conf*.

**-d** *db*

> SQLite database file.
> Overrides
> *db\_path*
> for this process.
> The directory of this file also holds
> *http.port*.

**-F**

> Foreground.
> Regress uses this.
> Standard error stays open.

**-l** *host:port*

> Listen address for this process.
> Replaces every
> *listen*
> line.
> Port 0 asks the kernel for a free port.
> A port from 1 to 1023 is rejected.

**-n**

> Check the configuration and exit.

# PROCESSES

**sld**
follows the shape of an
OpenBSD
imsg\_init(3)
daemon.
The parent forks the children and restarts a child that exits.
If the database child exits, the parent kills the others and exits
non-zero.
A child that dies within two seconds of starting is restarted after a
one-second pause.

Process titles are
`sld: parent`,
`sld: dish`,
`sld: db`,
`sld: http`,
`sld: watchdog`,
and, when coordinates are configured,
`sld: weather`.
rcctl(8)
**check**
and
**stop**
look up
`sld: parent`.
Each child is pledged to the promises it needs.
The parent keeps a wider pledge so a restarted child can still narrow
itself, including
unveil(2).
**sld**
does not run as root and does not chroot.
The rc script sets the user to
**\_sl**.

parent

> Supervises children.
> It does not open the database after startup.

dish

> Speaks plaintext gRPC with the built-in Perl client and never forks.
> Setting
> *dish\_client*
> to
> `xs`
> loads
> `Dish.so`
> when that module was built with
> `WITH_DISH_XS=yes`.
> The default build does not link
> `libgrpc++`.
> Every
> *dish\_interval\_s*
> seconds (default 30) it calls
> **get\_status**()
> and
> **get\_history**().
> The history ring is one sample per second.
> The obstruction map is fetched every five minutes.
> Each RPC deadline is five seconds.
> The channel is plaintext on port 9200.
> If that port does not answer, the child logs that once and tries again
> on the next interval.

db

> The only process that writes the database.
> Other processes send it messages and read rows back the same way.
> A reload sends it the retention keys,
> *rollup\_interval\_s*,
> and
> *log\_level*
> without restarting it.

http

> Serves HTTP.
> The parent binds each listen socket.
> This process inherits the ones that bound.
> Pledge is
> **inet**
> only, so this process does not re-read the configuration file.

watchdog

> Runs
> ping(8)
> **-n** **-c** **1** **-w** **2**
> against
> *ping\_targets*.

weather

> Started only when both
> *latitude*
> and
> *longitude*
> are set.

# HTTP

The listener is one request per connection, with
`Connection: close`
and a five-second read timeout.
The default file has one line,
`127.0.0.1:8080`.
Further
*listen*
lines are further sockets.
The page states uptime, the longest outage, the mean time between
outages, and the local hour of each outage, for the selected window.
A ping sample is not an outage.

**GET /**

> With no session, redirects to
> */login*.
> With a session, returns one page of the stored samples.
> *range*
> is
> `24h`
> (the default),
> `7d`,
> `30d`,
> `365d`,
> or
> `ever`.
> Throughput states bytes down, bytes up, and their sum for that window,
> from the byte columns on the rows the window reads.
> A null byte is left out of the sum.
> `365d`
> and
> `ever`
> include an hourly row whose UTC day has no daily row.

**GET /export.csv**

> Requires the session cookie.
> *range*
> uses the same values as
> */*.
> The body is CSV of the rows that window already reads,
> including an hourly row whose UTC day has no daily row.
> A missing session redirects to
> */login*.
> The file name is
> *slmon-*
> followed by the window.
> There is no request that deletes rows.

**GET /login**, **POST /login**, **POST /logout**

> The browser login.
> Success sets the cookie and redirects to
> */*.

**GET /health**

> Open JSON with
> *ok*
> and
> *rev*.
> *rev*
> is fixed when the HTTP process starts.
> A configuration reload restarts that process.

**POST /api/login**

> JSON body with
> *user*
> and
> *password*.
> Success sets the cookie
> *slmon\_session*
> for 12 hours,
> `HttpOnly`,
> `SameSite=Lax`.
> Five failures from one address in five minutes are rejected.

**GET /api/latest/**&zwnj;*table*

> and
> **GET /api/raw/**&zwnj;*table*
> Require the session cookie.

*/manifest.webmanifest*,
*/sw.js*,
and the icons need no session.
A browser on
`127.0.0.1`
or
`localhost`
can install the dashboard.
The installed window opens at
*/*.

# FILES

*/etc/sl.conf*

> Configuration.
> Mode 0640, owner
> **root:\_sl**.
> See
> sl.conf(5).

*/var/sl/sl.db*

> Default SQLite database.
> Mode 0600, owner
> **\_sl**.
> The directory is mode 0700.
> SQLite WAL and shared-memory files live beside it.
> Temporary tables stay in memory, because the database child unveils
> only this directory.

*/var/sl/http.port*

> The bound HTTP ports, one per line, in the order the addresses bound.

*/etc/rc.d/sld*

> rc script.
> `daemon_user`
> is
> **\_sl**.
> **sld**
> forks itself, so
> `rc_bg`
> is unset.
> *rc.subr*
> replaces the process pattern with the daemon path.
> The script sets it back to
> `sld: parent`
> after reading
> *rc.subr*.
> **check**
> sets that pattern again, because
> **stop**
> and
> **reload**
> reload the pattern recorded at start.

# EXIT STATUS

**-n**
exits 0 when the file parses, and non-zero when it does not.
A start before
slctl(8)
**init**
exits non-zero before forking.
The daemon's parent exits 0 after the background process has called
setsid(2).
The background process exits non-zero if the database child dies.

# SEE ALSO

pledge(2),
unveil(2),
sl.conf(5),
rc(8),
rcctl(8),
slctl(8)

OpenBSD 8.0 - October 22, 2026 - SLD(8)
