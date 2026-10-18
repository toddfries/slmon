# Status

Parked 2026-10-18. Drafted, then set aside. Not approved and not in progress. Pull this file back when later phases should start. Until then, do not implement it.

The running tool is described in `si/slmon-cribnotes.md`. Man pages and the README describe the tool as it is. They do not carry this phase list.

# slmon — phases 2 through 5

Phase 1 is shipped and collecting. Commit `87a4e17` added the first dashboard: latest sample, downlink, uplink, latency, loss, obstruction, the latest obstruction grid, and recent events, for `1h`, `6h`, `24h`, and `7d`. This plan does not rebuild that page and does not retell phase 1.

Still in force: no Docker, no copy of BenGhosti source or its HTML/CSS/JS, dish stays `192.168.100.1:9200`, the http child does not open the database, one admin, read RPCs only. UI stays inline HTML and SVG from Perl.

## Already true, so later phases must not pretend otherwise

- `history_samples` older than 90 days are averaged into `metrics_hourly` and deleted. `metrics` snapshots use that same cut. Hourly rows older than 365 days are averaged into `metrics_daily` and deleted. Minutely rows older than 730 days are deleted.
- That hourly compression stores average drop, average latency, max latency, and average throughput. It stores NULL for obstruction. `roll_minutes` also writes NULL for both obstruction columns, because `history_samples` has no obstruction fraction. The dashboard therefore reads raw `metrics` for the obstruction chart on every range.
- `events`, `weather`, `speedtests`, and `alert_queue` have no delete path. `obstruction_map` is one row. `alert_queue` and `speedtests` have no writer yet.
- The dish child is the only `libgrpc++` / `libprotobuf` process. A Perl gRPC client does not exist.
- The listener is `127.0.0.1:8080`. Login is bcrypt, the session cookie is HMAC-SHA256 for 12 hours, and login failures are rate limited. There is no delete API.

## Phase 2 — see the record and act on it

The dashboard ideas from the first plan, minus the page that already shipped. Build in this order. Each step is usable before the next one starts.

1. **Honest rollup columns.** Minute, hour, and day rows gain real obstruction (avg and max) from `metrics`, and jitter from `history_samples` (the spread of the 1 Hz latencies in that bucket). The obstruction chart then reads the rollup for `6h`, `24h`, and `7d`. The `1h` chart keeps reading status polls. Jitter is a new chart on the recent ranges, and a labeled approximation where only minute or hour rows remain.

2. **Sections, still one page.** Overview (what is there now), Quality (loss, latency, jitter), Throughput, Dish (identity, azimuth, elevation, SNR, alerts, grid), History (events). The time window stays one control for the whole page (`1h`, `6h`, `24h`, `7d`). No tab framework.

3. **Refresh per chart.** Each chart is its own authenticated document, embedded in an iframe: the SVG plus a refresh meta tag. One chart reloads without reloading the page and without a script. `chart_refresh_s` (default 60) applies to every chart. `chart_refresh_<chart>_s` overrides it for `downlink`, `uplink`, `latency`, `loss`, `jitter`, `obstruction`, and `map`. Sky and calendar use the same keys when those sections exist. Values are seconds, from 15 to 3600. A chart URL may pass `refresh=` inside those bounds; otherwise the config wins. Refresh rereads the database. It does not change `dish_interval_s` or the five-minute map poll.

4. **Sky and calendar.** A sky view places the boresight on the stored obstruction grid. An outage calendar is one SVG drawn from `events`. Both use the same per-chart refresh as the series.

5. **Health score.** One number, 0–100, with the factor breakdown: drop 30, latency 25, obstruction 20, uptime 15, alerts 10. Show the factors, not only the total.

6. **Weather, when configured.** If latitude and longitude are set, draw warning bands on the latency chart and a storm-versus-normal card from `weather.warning`. No coordinates are invented.

7. **SLA from events.** Five windows: `24h`, `7d`, `30d`, `365d`, and `ever`. `ever` means the whole collection, from the earliest stored event through now (from the earliest sample if no event exists). The URL value is `ever`. The label is "Ever". Each window shows uptime, longest outage, mean time between outages, and which hour of the day the outages fell in.

8. **CSV.** An authenticated download of the finest tier that still exists for the requested range. No purge button in this phase. Aging policy is phase 4.

9. **Notification plugins.** A new `slmon: notify` child drains `alert_queue`. It does not open the database; results go back over imsg. Plugins are Perl modules in `lib/SLMON/Notify/`. Config `notify` is a comma list, default empty, which leaves the child unstarted. The example modules are `dbus`, `email`, and `discord`. A later send path is a new module plus a name on that list. The queue payload is the event (timestamp, type, duration, text). Plugins do not get a database handle.

    Each module implements `check` (reject a bad config at start), `send` (one event, success or failure), and `promises` (the pledge nouns it needs). Keys are `notify_<name>_<field>`. The parser accepts that shape only for names listed in `notify`. Any other unknown key is still an error. `slmon notify test` enqueues one synthetic event.

    - `discord` POSTs the webhook in `notify_discord_url` over HTTPS, the same `IO::Socket::SSL` the weather child already uses.
    - `email` submits through `/usr/sbin/sendmail -t`. `notify_email_to` and `notify_email_from` are required when it is enabled.
    - `dbus` writes the event to the bus socket in `notify_dbus_path`. A missing bus is a failed attempt. It is not a failure of the daemon, and the other plugins still send.

    Stop after a fixed attempt count and mark the row given-up. One plugin's failure does not consume the other plugins' attempts. The notify child's pledge is the union of the enabled plugins. Payload text is the event, not a copy of an upstream template.

10. **Speed test, off by default.** A config key arms it. Nothing runs when the key is absent. Results go to `speedtests`.

11. **`slmon top` and `GET /metrics`.** `slmon top` is a terminal view of the latest sample and the open events. `/metrics` is Prometheus text. It requires the session cookie. A config key may open it on localhost; the default is closed.

## Phase 3 — optimization

Make the running collector cheaper. Measure first, then change the hot path. The poll stays at 30 seconds.

Measure and record, on this host, before rewriting:

- RSS and CPU of the dish child across one poll, and the poll's wall time against the 5 second deadline.
- Queries and bytes the http child pulls for a `6h` and a `7d` page.
- Database file and WAL size after a day of collection and after one retain.

Known waste to remove once those numbers exist:

- The extra raw-`metrics` scan the obstruction chart uses. Phase 2 fills the rollup column; this phase deletes the second query.
- A retain or a large rollup that leaves the WAL to grow until the next checkpoint. Checkpoint after the rollup and after retain.
- Startup rollup work that re-reads more than the open window.

**Major subsystem: Perl gRPC, last in this phase.** Replace `ext/dishbridge` with an in-tree Perl client that speaks plaintext gRPC to port 9200 and does not link `libgrpc++`, `libprotobuf`, abseil, re2, or c-ares. The dish child's imsg messages stay the same, so the db child does not change. Regress keeps the fake-dish runs and gains a fixture: a captured reply the C++ client already accepts, decoded by the Perl client to the same hash. After that cut, the dish pledge drops `prot_exec` and the filesystem unveil that existed for the C++ library. The poll must still finish inside the 5 second deadline.

Do not start the Perl client until the measurements above are written down. A smaller dependency tree is the point; a slower poll is not.

## Phase 4 — leave it running

Security, crash behavior, and growth limits. The database must get coarser as it gets older, and every table a writer touches must have a ceiling.

### Controlled aging

Finer rows are deleted only inside a transaction, and only after the coarser row exists and its `sample_count` covers that window. A partial coarser row is updated when the finer data covers more samples. `ON CONFLICT DO NOTHING` must not be the reason raw samples disappear.

A coarser row keeps average, maximum, and `sample_count` for drop, latency, throughput, obstruction, and jitter. An average alone hides the outage the SLA table is about. Maximum latency is already kept; obstruction and jitter are not.

Ceilings that do not exist yet:

| Table | What survives | What is removed |
| --- | --- | --- |
| `events` | One row per confirmed outage (start, duration, type), with no time cap, so `365d` and `ever` still have uptime, longest outage, mean time between outages, and hour of day. `ping_ok` rows for 90 days. | `ping_ok` older than 90 days. |
| `weather` | 90 days of samples, then one day row: min and max wind, precipitation, and whether a warning fired. | Samples older than 90 days. |
| `speedtests` | Same windows as `metrics`. | Rows past the raw window. |
| `alert_queue` | Given-up rows for 30 days, for the operator to see. | Delivered rows, and given-up rows past 30 days. Attempt count stays capped from phase 2. |
| `obstruction_map` | The latest grid, plus at most one grid per day for 90 days if phase 2's sky view needs a trail. | Any 5-minute history beyond that cap. |

A retain refuses to run when the clock has jumped more than a day since the last retain. A forward jump would otherwise delete the raw window in one pass. The refusal is a log line, not a silent skip of the timestamp update.

### Hardening

- A child whose pledge or unveil fails exits. It does not keep running with the pledge dropped. The parent restarts it. The notify child's promises are only those of the plugins actually enabled. A plugin that cannot reach its destination counts as a failed attempt. It does not drop the pledge.
- Schema changes are explicit steps, not "create if not exists" hoping a new column appears on an old file.
- Config file mode `0600` when `slmon` writes it. `pg_password` is not logged. `slmon once` stays available to the operator and is not written into the daemon log.
- Login and logout forms carry a token tied to the session secret, so a page on another port cannot post them.
- The listener stays on localhost. This phase does not add TLS or a second user.
- Disk full, a locked database, and a dish that stays down are already non-fatal to the parent. Add regress coverage that the parent is still up after each of those, and that a full disk does not leave a half-applied retain.

Regress for aging: a synthetic clock two years ahead yields a bounded row count per table, daily maxima match the injected spikes, and a one-day clock jump does not delete the raw window.

## Phase 5 — baselines

Read the aged record. Phase 4 keeps averages and maxima so this phase can compare without the original samples.

For the last 24 hours, compare drop, latency, throughput, and obstruction to the same hour of day in the daily and hourly history. Show median and a high percentile of that history, and how far the current hour sits from them. When a metric stays outside that band for a configured duration, write an event. The phase 2 notify plugins deliver that event when `notify` lists any of them.

No model training, no second dish, no write RPC to the dish, no account system. An OpenBSD port and the existing `rc.d` script are release work at the end of phase 4, not this phase.

## Out of scope

Copying upstream UI, Docker, multi-dish, 2FA, rebooting or stowing the dish, any RPC other than `get_status`, `get_history`, and the obstruction map, and binding the listener on a non-loopback address.
