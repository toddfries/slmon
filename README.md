# slmon

Unofficial Starlink monitor. It is not affiliated with SpaceX. Phase 1 stores
dish history, status, and a few local health signals. Dashboards, graphs,
alerts, and a Perl-native gRPC client are later phases and are not built.

The dish in this setup is bridged to an OpenBSD firewall. It is not the
router, so the stock address `192.168.100.1` does not apply and slmon does
not fall back to it. The default `dish_host` is `100.69.0.1` port 9200.
Override it in the config file when the dish is somewhere else.

This host currently has no working route to `100.69.0.1` (the default route
is the LAN gateway, and a poll of TCP port 9200 does not answer). `slmon once`
says so and returns. `slmon start` keeps running and logs the same fact once,
until the dish answers. Point a route at the dish, or set `dish_host`, before
expecting live samples.

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
dish_host = 100.69.0.1
dish_interval_s = 30
db = sqlite
```

`-d` or `SLMON_DB` picks the SQLite file. From a checkout the default is
`./var/slmon.db`. Otherwise it is `~/.local/share/slmon/slmon.db`.

`-l` overrides `listen`. The HTTP listener is loopback only unless you set
otherwise. `GET /health` is open. Everything under `/api/` needs the
`slmon_session` cookie from `POST /api/login`.

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
`slmon once` only when `100.69.0.1:9200` answers.

## Not in this tree

Phase 2 would add the dashboard, graphs, CSV, sky view, health score, SLA,
and alert delivery. Phase 3 would replace the linked gRPC client with Perl.
Neither is implemented.
