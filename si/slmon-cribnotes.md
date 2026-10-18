# slmon crib

2026-10-18. Tip `87a4e17` on `master`. Read this before changing the tree.

`man/man8/slmon.8` and `README.md` describe the tool as it runs. They do not describe phases or this conversation. Later-phase ideas are parked in `si/slmon-plan.md`. Do not implement that file until asked.

`si/AI-CRIBNOTES.txt` and `si/aibootstrap/` are an unrelated seed about another project. They are not slmon rules.

## What it is

Native Perl Starlink monitor. Unofficial, not affiliated with SpaceX. No Docker. BenGhosti/starlink-monitor is a behavior spec only (all-rights-reserved; do not copy source or its HTML/CSS/JS). Protocol reference is public-domain sparky8512/starlink-grpc-tools plus `SpaceX.API.Device.Device/Handle`.

One checkout, several processes, libc `imsg` between them. SQLite by default, PostgreSQL optional, same DML. OpenBSD. Perl 5.42. System `libgrpc++` and `libprotobuf` are linked on purpose, and only inside the dish child after `fork`.

## How it got here

- `ea342b6` — collector. Parent forks dish, db, http, watchdog, and weather only when lat/lon are set. Dish polls every 30s (history ring plus one status), obstruction map every 5 min. Not the upstream 2s loop. Db child is the sole writer. First start prompts for admin user (default `admin`) and a password twice; bcrypt `$2b$`; empty and under 8 rejected. Non-interactive start with no password exits with the exact line telling the operator to run `slmon init` or `slmon start` from a terminal. Session key is 32 bytes from `/dev/urandom` and is not rotated.
- `3b12f13` — man page, and the dish child stays inside pledge. Abseil's missing sysfs probe must return `ENOENT`, so `rpath` stays and that path is not unveiled.
- `e242753` — an unreachable dish logs `slmon: dish: HOST:PORT does not answer` once, then retries quietly. Deadline exceeded, failed to connect, connection refused, and connection timed out all map to that line. No Perl stack trace.
- `32f7370` — service name. The dish rejected `spacex.api.device.Device`. The name it registers is `SpaceX.API.Device.Device`, rpc `Handle`, C++ namespace `SpaceX::API::Device`. Field numbers were left at the high tags because a live reply filled them. Do not switch to fleetview tags 1/2/3. Request: `get_status=1004`, `get_history=1007`, `dish_get_obstruction_map=2008`. Response: `dish_get_status=2004`, `dish_get_history=2006`, map `2008`.
- `fec1ce0` — compiled default dish host is `192.168.100.1` port 9200. `100.69.0.1` was removed. From this host only `192.168.100.1` answers. No silent fallback. `100.69.224.251` is the firewall's Starlink-side address, not the dish. `100.50.212.133:443` is Amazon ads, not the dish.
- `83dcea9` — `use IO::Select ();` in `DishProc.pm` before unveil. `IO::Socket` timed connect does `require IO::Select` after unveil and Perl then reports the module missing even though it is base. The empty import list keeps builtin `select`.
- `59dcf50` — browser login. `GET /login` form posts `user` and `password` to `/login`. Success sets `slmon_session` and redirects to `/`. `POST /api/login` remains the JSON login.
- `87a4e17` — `GET /` with a session is the dashboard (inline SVG, no script, no CDN). That request was charts of data already stored. It was not the rest of the old output list (health score, SLA, CSV, alerts, speed tests).

A follow-on list (chart refresh, SLA windows including `ever`, notify plugins, then optimization, aging, baselines) was drafted and then set aside. It is `si/slmon-plan.md`.

## Processes

`ps` titles: `slmon: parent`, `dish`, `db`, `http`, `watchdog`, `weather`.

Parent forks and restarts children. If the db child dies, the parent exits non-zero. Dish child never forks and is the only process that loads `SLMON::Dish`. Parent `use`s `DishProc` and `Http` before fork so the children are not the first to compile them. A child that dies inside `_spawn` is warned as `slmon: NAME: …` and restarted.

`SLMON::IMSG_MAX` is 262144, not 16KB. History still goes in chunks of at most 30 samples. The obstruction map is one message; a map larger than the max is a hard error.

Commands: `start`, `init`, `status` (read-only db, no daemon), `once` (one status JSON, no db write, no pledge). Flags `-c`, `-d`, `-l`. Unknown config keys are rejected. `db=pg` without `pg_db` is rejected.

`rc.d/slmon` is an example. Edit the path before installing. `start` stays in the foreground.

## Dish

Insecure gRPC to `host:9200`, 5s deadline, after a 2s TCP probe. Channel is created in the dish child. `SLMON_DISH_CMD` replaces the real dish (regress). The double must see `SLMON_DB_FD`. `regress/fakedish.pl` writes one scripted minute and exits on its first start so the parent restarts it; later starts stay up. It also upserts `dish_info` and inserts a metrics row. A test daemon pointed at a copy of the live db will show that fake dish on the stat tiles.

Live map samples are about 123×123 little-endian floats: mostly `-1` (unmeasured) or `1` (clear), a few `0` (blocked). Do not claim a north-up orientation.

`seconds_to_first_nonempty_slot` has come back as a unix timestamp (~1.79e9), not a small duration. `legacy_state` is often null on this firmware.

## Storage

Default `./var/slmon.db` from a checkout (gitignored), else `~/.local/share/slmon/slmon.db`. WAL, `synchronous=NORMAL`, `busy_timeout=5000`, mode `0600`. Override with `-d`. PostgreSQL is `db=pg` plus `pg_*` keys. Dialect is confined to `SLMON::DB::SQLite` and `SLMON::DB::Pg`.

Time columns used by queries: `history_samples.ts`, `metrics.ts`, `metrics_minutely.ts_minute`, `metrics_hourly.ts_hour`, `metrics_daily.ts_day`, `events.ts`, `dish_info.last_seen_ts`, `obstruction_map.ts`, `weather.ts`, `speedtests.ts`, `alert_queue.created_ts`. Query ops are only `latest` and `raw`. Obstruction SNR is returned as `snr_b64` (the blob is stripped). Row chunks over imsg are about 200000 bytes.

`history_samples` is unique on `(run_id, dish_counter)`. A new run starts when bootcount changes or the tip counter moves backwards. Drop rate ≥ 1 stores NULL latency.

Rollups run in the db child. Byte columns are `sum(bps)/8`. An empty minute roll does not advance the cursor; the newest completed minute stays open. `roll_minutes` writes NULL for both obstruction columns. Hourly rollup averages that NULL, so it stays NULL. The dashboard's obstruction series is raw `metrics` for every range whose throughput series is a rollup. Do not "fix" the chart by inventing obstruction inside `history_samples`.

Retention, in `SLMON::Rollup::retain`: raw history and `metrics` older than 90 days compressed into hourly (obstruction stored NULL there) then deleted; hourly older than 365 days averaged into daily then deleted; minutely older than 730 days deleted. Config key for the raw window is `raw_retention_days`. `events`, `weather`, `speedtests`, and `alert_queue` are not aged. `obstruction_map` is a single row. `speedtests` and `alert_queue` have schema and no writer. `metrics_daily` stays empty until an hourly row is old enough. Weather stays empty until lat/lon are set. None of those are unfinished collection.

## HTTP

Listener default `127.0.0.1:8080`. One request per connection, `Connection: close`, 5s read timeout. The http child never opens the database. It asks the db child. Pledge is `inet` only, after modules load. `strftime`/`localtime` are warmed in `Http::run` before that pledge (`strftime('%H:%M', localtime($^T))`). `gmtime` is safe after pledge. HTML is inline because the pledge has no filesystem.

- `GET /health` — open JSON.
- `GET /` — no session redirects to `/login`. With a session, `SLMON::Dash::page`.
- `GET /login`, `POST /login` — form fields `user`, `password` (ids `user`, `password`). Failure is 401 HTML, username kept and escaped. `POST /api/login` and `POST /api/logout` stay JSON.
- `POST /logout` — clears the cookie, redirects to `/login`.
- `GET /api/latest/TABLE`, `GET /api/raw/TABLE?from&to&limit&order` — cookie required. Default limit 5000, max 50000. Allow-listed tables only.
- No delete request. No static files.

Cookie `slmon_session`: HMAC-SHA256, 12h, HttpOnly, SameSite=Lax, Path=/, Max-Age=43200. Password check stays in the db child. Five failures per IP per five minutes.

Dashboard ranges: `?range=1h|6h|24h|7d`, default `6h`, invalid falls back to `6h`. `1h` reads `metrics`. `6h` and `24h` read `metrics_minutely`. `7d` reads `metrics_hourly`. Obstruction for the non-`1h` ranges is a second `metrics` query (limit 20000). Downsample above 480 points. Y axis starts at 0 with a 1/2/5/10 max. Missing numbers render as ASCII `n/a`. A UTF-8-flagged em dash breaks `Content-Length` because that header uses character length. The degree sign in azimuth/elevation is raw UTF-8 bytes in the source, without `use utf8`, so the string stays bytes. Stale if the latest sample is older than 120s. Alert names come from `SLMON::StatusMap::alert_names` (`motors_stuck` is bit 1, value 2). Map: `unpack('f<*')`, class `u` unmeasured, `o` blocked (any 0 in a downsample block stays blocked), `c` clear. Omit the map section when there is no row.

Unit tests of `GET /` pass `$ctx->{dash}` because they have no imsg. A query error still renders the page, including the escaped user, with "The database did not answer."

`browse.mjs --type` splits on the first `=`. Use `input#user`, not `input[name=user]`. `--click` does not wait for navigation. HttpOnly cookies show up in the cookie jar, not `document.cookie`. Favicon 404 is harmless.

A process started before a code change keeps the old HTTP behavior until that process is restarted. Do not kill a collector you did not start. As of this writing the checkout's collector was pid 26399, started 2026-10-18 11:45, cwd this repo, database `var/slmon.db`. The pid will change.

## Pledge

- Parent pledge is wide enough, including `unveil`, that a restarted child can still narrow itself.
- Dish: `inet dns prot_exec rpath`, then unveil `/dev/urandom`, resolver files, `/etc/hosts`, `/etc/services`, `/etc/protocols`. If unveil or pledge fails, the dish child logs and keeps running unpledged. That is the current behavior.
- Db: unveil the state directory. Then `rpath wpath cpath flock recvfd`, plus `unix` for PostgreSQL.
- Http: `inet` only.
- Watchdog: `proc exec inet`, ping is OpenBSD `ping -c 1 -w 2 -n`. There is no `head -c` on this host.
- Weather: `inet dns rpath`, and it already uses `IO::Socket::SSL`.

## Regress and build

`make regress` (builds `ext/imsg` and `ext/dishbridge`, then `bsd.regress.mk`). Targets: unit, imsg, dish pledge, sqlite db, postgres db, sqlite e2e, postgres e2e, live. Postgres targets `initdb` a private cluster and remove it. Missing `initdb` or `DBD::Pg` fails those targets. Live target probes `192.168.100.1:9200` with `nc -z -w 2`, then `slmon once`, and should pass on this host rather than skip.

`regress/unit.pl` puts both `../lib` and `../blib` on `@INC`. `SLMON::Http` loads the `SLMON::Imsg` XS at compile time. `perl -c` of an HTTP module needs `-Ilib -Iblib`. Last full `make regress` after the dashboard was green, including a live status document.

`CFLAGS`/`CXXFLAGS` arrive as `-O2 -pipe`, so the Makefile uses `+= -fPIC`. Generated `ext/dishbridge/gen/` and `blib/` are gitignored. `protoc` and `/usr/local/bin/grpc_cpp_plugin`. Perl sources use tabs. Comments only for a non-obvious constraint.

`mandoc -Tlint` on the man page reports only `STYLE: RCS id missing: (OpenBSD)`. Do not invent an RCS id.

XS: on Perl 5.42 `sv_setref_pv` stores an IV; the XS checks `SvIOK` and uses `INT2PTR`. `imsg_compose` returns 1 on success.

## This host

Dish is bridged through an OpenBSD firewall. `arm0` routes `192.168.100.1` via the Starlink gateway `100.64.0.1` on `vlan6`. The monitor host's `re0` is `10.1.5.35`, gateway `10.1.5.1`. `192.168.100.1:9200` and `:9201` answer. Do not print the dish serial in replies or docs.

Do not `pkg_add` or `doas` from an agent session. `grpc` was already present for the build. Do not install a second gRPC stack.
