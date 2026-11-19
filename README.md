# slmon

Unofficial Starlink monitor. It is not affiliated with SpaceX. It records
dish history, status, obstruction samples, and watchdog pings, and serves
a dashboard of those samples.

The dish in this setup is bridged to an OpenBSD firewall. The default
`dish_host` is `192.168.100.1` port 9200. Override it in the config file
when the dish is somewhere else.

If that port does not answer, `slctl once` says so and returns. `sld` keeps
running and logs the same fact once, until the dish answers.

The manuals are [sld(8)](man/man8/sld.8.md) (`man/man8/sld.8`), [slctl(8)](man/man8/slctl.8.md) (`man/man8/slctl.8`), and [sl.conf(5)](man/man5/sl.conf.5.md) (`man/man5/sl.conf.5`).

## Run

The database is `/var/sl/sl.db`. The directory is created for the `_sl` user
before the first start. `sld` does not create it and does not prompt.

```
doas -u _sl slctl init
rcctl enable sld
rcctl start sld
doas -u _sl slctl status
slctl once
```

`doas -u _sl slctl passwd` replaces the admin user and password on a
database that init already created, and replaces the session key.
It writes those settings and does not roll up stored samples.
Restart with `rcctl restart sld` so an existing login stops working.
`slctl init` as root prints `slctl: doas -u _sl slctl init` and exits.
`slctl passwd` as root prints `slctl: doas -u _sl slctl passwd` and exits.
`sld` before that init prints:

```
sld: /var/sl/sl.db is not initialized
sld: doas -u _sl slctl init
```

`sld` forks into the background. `sld -F` stays in the foreground. `sld -n`
checks the configuration and exits. `rcctl reload sld` sends `SIGHUP`, which
re-reads `/etc/sl.conf`. A changed database path waits for `rcctl restart sld`.

From a checkout the same commands are `perl bin/sld` and `perl bin/slctl`.
`-d` selects a SQLite file other than `/var/sl/sl.db`. `-l` overrides `listen`
for that process. `-c` selects the configuration file.

The sample file is `etc/sl.conf`. The listener defaults to loopback. Open `http://127.0.0.1:8080/` for the dashboard. The login form
is `http://127.0.0.1:8080/login`. A successful login sets the
`slmon_session` cookie and returns to `/`. The window is 24 hours, 7 days,
30 days, 365 days, or the whole collection (`/?range=24h`). `GET /health` is open.
A browser on `127.0.0.1` or `localhost` can install the dashboard. The Install
button appears when that browser offers it. The manifest, icons, and worker
are served by the listener and need no session. The worker does not store pages.
`POST /api/login` is the same check for a client that wants JSON back.
Everything under `/api/` except that login needs the cookie.

## Processes

The parent is `sld: parent`. It forks `dish`, `db`, `http`, and `watchdog`,
plus `weather` when latitude and longitude are set. Children talk to the db
process over libc `imsg`. The db process is the only one that writes the
database. If it dies, the parent exits and leaves restart to rc.

The dish process polls every 30 seconds: one `get_history` and one
`get_status`. The history ring is 1 Hz. The obstruction map is every 5
minutes. Only that process loads `libgrpc++`, and only after fork.

The watchdog pings `1.1.1.1` and `8.8.8.8` with OpenBSD `ping -c 1 -w 2`.
Three failures confirm a disconnect. A latency spike is a best RTT over
200 ms for at least 30 seconds.

## PostgreSQL

SQLite is the default (`p5-DBI`, `p5-DBD-SQLite`, WAL). Temporary tables
stay in memory. For PostgreSQL:

```
db = pg
pg_db = slmon
pg_user = slmon
pg_host = /var/run/postgresql
```

`pg_host` is the local socket directory when it is a path. `p5-DBD-Pg` is
required. The same queries run on either driver.

## Build and regress

`libgrpc` and `protobuf` come from OpenBSD ports. The dish extension links
the system libraries.

```
make
make regress
```

Regress uses `bsd.regress.mk`. It covers the auth, history, rollup,
retention, and watchdog functions, both database drivers, and an end-to-end
run with a pty password prompt and a fake dish. A daemon target checks an
uninitialized database, `sld -n`, a background start, and `SIGHUP`. The
PostgreSQL targets `initdb` a private cluster and remove it. The live-dish
target runs `slctl once` only when `192.168.100.1:9200` answers.

## Dashboard

`/` is one page. Overview is the latest downlink, uplink, latency, loss,
obstruction, and uptime. Quality charts packet loss, latency, jitter, and
obstruction. Throughput charts downlink and uplink, and states the bytes
down, the bytes up, and their sum for the selected window. A stored null
is left out of that sum. Dish shows identity,
azimuth, elevation, SNR, alerts, and the obstruction grid. The grid
marks the boresight: north is up, azimuth 0 is north, elevation 90 is
the center, and elevation 0 is the horizon. History opens with an
outage calendar for the selected window, then lists recent events.
`ping_ok` is not an outage. The window is 24 hours (the default), 7 days, 30 days,
365 days, or the whole collection (`/?range=24h`, `7d`, `30d`, `365d`,
`ever`). An unknown value is 24 hours. 24 hours uses the per-minute rollup.
7 and 30 days use the hourly rollup. 365 days and the whole collection use
the daily rollup, plus an hourly row for any UTC day that has no daily row.
The whole collection has no start time. Its charts begin at the earliest
sample. A signed-in browser can download the rows that window reads at
`/export.csv?range=24h` (the same range values as the page). The link is
on the page. A missing session is sent to the login form. Obstruction is the average stored on those rows, or status polls
when the rollup has no obstruction yet. Those polls are kept 90 days.
Jitter is the spread of the 1 Hz latencies in the bucket (highest minus
lowest), stored on the same rows.
The obstruction grid is the newest map from the dish: gray is unmeasured,
blue is clear, red is blocked. The page also lists the configuration it
is using (dish address, sample interval, chart interval, map interval,
listen address, database, retention). It does not show the password or
`pg_password`. Charts redraw in place on `dish_interval_s` (default 30
seconds, minimum 2). The page asks `GET /health` every 2 seconds and
reloads when `rev` changes. That revision is taken when the HTTP process
starts, so a newer file is served after that process is restarted. JSON
for the same tables remains at `/api/latest/TABLE` and `/api/raw/TABLE`.
