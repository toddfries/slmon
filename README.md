# slmon

Unofficial Starlink monitor. It is not affiliated with SpaceX. It records
dish history, status, obstruction samples, and watchdog pings, and serves
a dashboard of those samples.

The dish in this setup is bridged to an OpenBSD firewall. The default
`dish_host` is `192.168.100.1` port 9200. Override it in the config file
when the dish is somewhere else.

If that port does not answer, `slmon once` says so and returns. `slmon start`
keeps running and logs the same fact once, until the dish answers.

The manual is `man/man8/slmon.8` (`mandoc man/man8/slmon.8`).

## Run

```
perl bin/slmon init
perl bin/slmon start
perl bin/slmon status
perl bin/slmon once
```

`start` and `init` ask for an admin user (default `admin`) and a password the
first time the database is empty. The password is stored as OpenBSD `crypt(3)`
bcrypt. The session signing key is read from `/dev/urandom` and is not
rotated on the next start. A non-interactive start with no password set exits
and tells you to run `slmon init` or `slmon start` from a terminal.

`start` stays in the foreground. `rc.d/slmon` is an example that daemonizes
it; edit the path before installing it.

```
listen = 127.0.0.1:8080
dish_host = 192.168.100.1
dish_interval_s = 30
db = sqlite
```

`-d` or `SLMON_DB` picks the SQLite file. From a checkout the default is
`./var/slmon.db`. Otherwise it is `~/.local/share/slmon/slmon.db`.

`-l` overrides `listen`. The HTTP listener is loopback only unless you set
otherwise. Open `http://127.0.0.1:8080/` for the dashboard. The login form
is `http://127.0.0.1:8080/login`. A successful login sets the
`slmon_session` cookie and returns to `/`. The window is 24 hours, 7 days,
30 days, 365 days, or the whole collection (`/?range=24h`). `GET /health` is open.
`POST /api/login` is the same check for a client that wants JSON back.
Everything under `/api/` except that login needs the cookie.

## Processes

The parent is `slmon: parent`. It forks `dish`, `db`, `http`, and `watchdog`,
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

SQLite is the default (`p5-DBI`, `p5-DBD-SQLite`, WAL). For PostgreSQL:

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
run with a pty password prompt and a fake dish. The PostgreSQL targets
`initdb` a private cluster and remove it. The live-dish target runs
`slmon once` only when `192.168.100.1:9200` answers.

## Dashboard

`/` is one page. Overview is the latest downlink, uplink, latency, loss,
obstruction, and uptime. Quality charts packet loss, latency, jitter, and
obstruction. Throughput charts downlink and uplink. Dish shows identity,
azimuth, elevation, SNR, alerts, and the obstruction grid. History lists
recent events. The window is 24 hours (the default), 7 days, 30 days,
365 days, or the whole collection (`/?range=24h`, `7d`, `30d`, `365d`,
`ever`). An unknown value is 24 hours. 24 hours uses the per-minute rollup.
7 and 30 days use the hourly rollup. 365 days and the whole collection use
the daily rollup, plus an hourly row for any UTC day that has no daily row.
The whole collection has no start time. Its charts begin at the earliest
sample. Obstruction is the average stored on those rows, or status polls
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
