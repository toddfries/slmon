# Status

Approved 2026-10-18. Steps 1 and 2 are in the tree, and the current page already refreshes on the dish interval. The page is Overview, Quality, Throughput, Dish, and History, for `24h`, `7d`, `30d`, `365d`, and `ever`. Do not start step 4 until that is the behavior you see. Man pages and the README describe the tool, not this list.

# slmon — phases 2 through 5

Phase 1 is shipped and collecting. Commit `87a4e17` added the first dashboard: latest sample, downlink, uplink, latency, loss, obstruction, the latest obstruction grid, and recent events, for `1h`, `6h`, `24h`, and `7d`. This plan does not rebuild that page from scratch and does not retell phase 1.

Man pages and the README describe the tool as it is when a change lands. They do not carry this phase list.

Still in force: no Docker, dish stays `192.168.100.1:9200`, the http child does not open the database, one admin, read RPCs only. UI stays inline HTML, SVG, and script from Perl. No static files and no CDN. The shared handbook is `si/agent-core/`.

## Decisions that bind every phase

These apply to the whole plan. A later phase does not invent a second window set, a second refresh mechanism, a second way to deliver an event, a hardcoded retention period, a single listen socket, or a reason to copy another project.

**Original work.** Code, pages, and wording are written in this tree. Do not copy another project's source, markup, or text. Other projects are documentation, opened only to troubleshoot something this plan is already doing. They are not a list of features to add, and they are not named here.

**Windows.** Any view, export, score, or comparison that covers a span of time uses `24h`, `7d`, `30d`, `365d`, and `ever`. `ever` is the whole collection, from the earliest stored sample or event through now. The URL value is `ever`. The label is "Ever". The page has one window control, and it uses this set.

Each window reads the finest tier that still covers it. `24h` prefers minutely rows. `7d` and `30d` prefer hourly rows. `365d` and `ever` prefer daily rows and use hourly rows where the day has not been rolled yet. Obstruction and jitter have to be on those rows, or the long windows are blank.

**Refresh.** Graphs redraw in place on `dish_interval_s` (default 30, minimum 2). The page asks `GET /health` every 2 seconds and reloads when `rev` changes. `rev` is the running page plus the configuration that affects it, taken at process start. A file change on disk is served after that process is restarted. Refresh rereads the database. It does not change `dish_interval_s` or the five-minute map poll. Later panels join that same interval and revision check. They do not grow a second timer under 2 seconds, and they do not grow a `panel_refresh_*` key. The series, the map, the sky, the calendar, the health score, the SLA block, the weather card, and the event list all use this rule.

**Hooks.** A new output is a plugin. Modules live under `lib/SLMON/Notify/`. Config `notify` is a comma list, default empty. The first hook is `event`. Example send paths are `dbus`, `email`, and `discord`. A later hook or send path is a new module plus a name on that list. Phases 3, 4, and 5 raise events. They do not grow a private sender. The queue payload is the event (timestamp, type, duration, text). Plugins do not get a database handle. The contract is the manual, written in the same change as the first modules, so another person can add a mechanism without reading those modules as the spec.

**Listen.** `listen` may appear more than once. Each value is an address and port this host should serve. The default file still has one line, `127.0.0.1:8080`. The parser accepts that together with an IPv6 loopback line and with further local addresses the operator writes. A line that fails to bind is logged with the address and the error. The lines that bound keep serving. The http child is the one that serves them.

**Retention knobs.** Every retention interval in this plan is a config key. The numbers below are the defaults. An operator changes the period in the config file. A code change is not required. Keys that already exist stay: `raw_retention_days` (90), `minutely_retention_days` (730), `hourly_rollup_days` (365).

**Debug.** `log_level` is `info` or `debug`. Default `info` stays the short operator line. `debug` adds the inputs of the decision: the window, the counts, the address, the reply shape, the attempt number, the cut timestamps. The session secret, the password, and `pg_password` are not logged. A failure that cannot be explained from those lines is a bug in the log. Each phase's new behavior includes its debug lines in the same change.

**Reply shape.** Every gRPC call (`get_status`, `get_history`, the obstruction map, and any later call) records when the reply grows a field, drops a field, or changes the type of a field this code stores. The first time is one info line: the call name and the field name. Debug adds the observed type and the request that was sent (call name, target, deadline). It does not dump the map. That record is how a later change stores data the dish is already sending. Unknown fields are not written into the database just because they appeared.

## Already true, so later phases must not pretend otherwise

- `history_samples` older than 90 days are averaged into `metrics_hourly` and deleted. `metrics` snapshots use that same cut. Hourly rows older than 365 days are averaged into `metrics_daily` and deleted. Minutely rows older than 730 days are deleted.
- Hourly compression stores average drop, average latency, min and max latency, average and max obstruction, jitter, and average throughput. Obstruction comes from `metrics`. Jitter is the spread of the 1 Hz latencies (max minus min). A conflicting row keeps throughput already stored and fills a null obstruction or jitter. `history_samples` still has no obstruction column. The dashboard reads the rollup for obstruction when that tier has a fraction, and reads `metrics` when it does not. `24h` reads minutely rows. `7d` and `30d` read hourly rows. `365d` and `ever` read daily rows and keep an hourly row when that UTC day has no daily row. Jitter on every window is the jitter stored on those rows. Raw metrics are kept 90 days, so the obstruction fallback does not cover a full year.
- `events`, `weather`, `speedtests`, and `alert_queue` have no delete path. `obstruction_map` is one row. `alert_queue` and `speedtests` have no writer yet.
- The dish child is the only `libgrpc++` / `libprotobuf` process. A Perl gRPC client does not exist.
- The listener is one config value, `127.0.0.1:8080`. A repeated `listen` line is not accepted yet. Login is bcrypt, the session cookie is HMAC-SHA256 for 12 hours, and login failures are rate limited. There is no delete API.
- The dashboard can be installed from `127.0.0.1` or `localhost`. The manifest, icons, and worker are responses from the http process. The worker does not cache. The Install button appears when the browser offers the prompt. A later phase does not add a second worker or a cache of the page.

## Phase 2 — see the record and act on it

Build in this order. Each step is usable before the next one starts. Windows, refresh, hooks, listen lines, retention knobs, debug lines, and reply-shape notes are the rules above.

1. **Honest rollup columns.** Done. Minute, hour, and day rows store real obstruction (avg and max) from `metrics`, and jitter from `history_samples` (the spread of the 1 Hz latencies in that bucket). The obstruction and jitter charts read that tier when it exists. The raw `metrics` scan remains where that tier does not exist yet.

2. **Sections, one page, one window.** Done. Overview is the latest sample. Quality is packet loss, latency, jitter, and obstruction. Throughput is downlink and uplink. Dish is identity, azimuth, elevation, SNR, alerts, and the grid. History is events. One control: `24h` (default), `7d`, `30d`, `365d`, `ever`. No tabs. `24h` reads minutely rows. `7d` and `30d` read hourly rows. `365d` and `ever` read daily rows and keep hourly rows for a UTC day that has no daily row. `ever` has no lower bound and the chart starts at the earliest drawn point. An unknown value, including `1h` and `6h`, is `24h`. Volume, peaks, and obstruction duration are not this step. They are under Still to draw.

3. **Refresh on the panels that exist.** Done for the current page: the series, the map, and the event list redraw in place on `dish_interval_s`, and the page reloads when `GET /health` reports a new `rev`. Sky, calendar, health, SLA, and weather join that same interval and revision check in the step that adds them.

4. **Sky and calendar.** Done. `SLMON::Dash::map_svg` draws a ring on the stored grid when azimuth and elevation are known. North is up, azimuth 0 is north, elevation 90 is the center, and elevation 0 is the horizon. `SLMON::Dash::calendar_svg` is one SVG of outages in the selected window. `ping_ok` is not an outage. Both sit on the existing page refresh.

5. **Health score.** One number, 0–100, for the selected window, with the factor breakdown: drop 30, latency 25, obstruction 20, uptime 15, alerts 10. Show the factors, not only the total.

6. **Weather, when configured.** If latitude and longitude are set, draw warning bands on the latency chart for the selected window, and a storm-versus-normal card from `weather.warning`. No coordinates are invented.

7. **SLA math, same windows.** For whichever of the five windows is selected: uptime, longest outage, mean time between outages, and which hour of the day the outages fell in.

8. **CSV.** An authenticated download of the finest tier that still exists for the selected window. No purge button in this phase. Aging policy is phase 4.

9. **First hook: notify.** A `sld: notify` child drains `alert_queue` over imsg. It does not open the database. It starts only when `notify` is non-empty. The same change adds the contract to `man/man8/sld.8` and a short pointer in the README. The manual is the writeup another person implements from. It states, in this tree's own words:

    - The file is `lib/SLMON/Notify/<Name>.pm`, package `SLMON::Notify::<Name>`.
    - `check($cfg)` runs at startup, before pledge, and dies with a `sld:` line when a required `notify_<name>_*` key is missing or malformed.
    - `promises()` returns the pledge nouns this module needs. An empty list adds none.
    - `send($cfg, $event)` delivers one event. `$event` has `ts`, `type`, `duration_s`, and `text`. True means sent. False or an exception means that module failed. The module is not given a database handle.
    - The notify child, not the module, counts attempts. `notify_max_attempts` defaults to 8. One module's failure does not consume the others. A module past the cap is given up for that row.
    - `slctl notify test` enqueues one synthetic event.
    - Keys are `notify_<name>_<field>`. The parser accepts that shape only for names listed in `notify`. Any other unknown key is still an error.

    The manual's examples are the three modules below. They illustrate the contract. They are not the contract.

    - `discord` POSTs the webhook in `notify_discord_url` over HTTPS, the same `IO::Socket::SSL` the weather child already uses.
    - `email` submits through `/usr/sbin/sendmail -t`. `notify_email_to` and `notify_email_from` are required when it is enabled.
    - `dbus` writes the event to the bus socket in `notify_dbus_path`. A missing bus is a failed attempt. The other plugins still send.

    The notify child's pledge is the union of the enabled plugins. Payload text is the event. Debug logs the event type, the module name, the attempt number, and the failure text. It does not log the webhook URL's secret path or the message body beyond `text`.

10. **Speed test, off by default.** A config key arms it. Nothing runs when the key is absent. Results go to `speedtests`. A finished run raises an event, which the notify hook delivers when a plugin is enabled.

11. **`slctl top` and `GET /metrics`.** `slctl top` is a terminal view of the latest sample and the open events. `/metrics` is Prometheus text for the latest sample. It requires the session cookie. A config key may open it without a cookie on the listen lines; the default is closed. Neither one adds a window set.

12. **More than one listen line.** The parent binds every `listen` value and the http child serves each socket that bound. IPv4 loopback and IPv6 loopback are both accepted in one file. Further local addresses are further lines. The man page shows the repeated key. Debug logs each bind with the address and the result.

13. **Reply shape on the dish child we have.** The C++ client records new, missing, and retyped fields on `get_status`, `get_history`, and the obstruction map, as the reply-shape rule says. This does not wait for the Perl client.

## Still to draw

These sit on the sections from step 2. They are not a step of their own and they are not next. Steps 4 through 13 stay in the order above. Sky stays step 4.

- **Volume, on Throughput.** Bytes down, bytes up, and the two added, for the selected window, from `down_bytes` and `up_bytes` already stored on minute, hour, and day rows.
- **Peaks, on Throughput and Quality.** Peak download, peak upload, and the lowest latency in the selected window. Minute rows already store `max_downlink_bps`, `max_uplink_bps`, and `min_ping_latency_ms`. Hour and day rows do not store a peak rate. The same change adds those columns, so a long window does not invent a peak from an average.
- **Obstruction behavior, on Dish.** Currently obstructed, average prolonged-obstruction duration, and average interval, from the latest status row (`currently_obstructed`, `obstruction_duration`, `obstruction_interval` on `metrics`). Numbers beside the fraction. Not a second series, and not rolled up.

## Phase 3 — optimization

Make the running collector cheaper. Measure first, then change the hot path. The poll stays at 30 seconds.

Measure and record, on this host, before rewriting:

- RSS and CPU of the dish child across one poll, and the poll's wall time against the 5 second deadline.
- Queries and bytes the http child pulls for a `24h` page, a `365d` page, and an `ever` page.
- Database file and WAL size after a day of collection and after one retain.

Known waste to remove once those numbers exist:

- Any raw-`metrics` scan still used for obstruction or jitter. Phase 2 fills the rollup columns; this phase deletes the extra query.
- A retain or a large rollup that leaves the WAL to grow until the next checkpoint. Checkpoint after the rollup and after retain.
- Startup rollup work that re-reads more than the open window.

**Major subsystem: Perl gRPC, last in this phase.** Replace `ext/dishbridge` with an in-tree Perl client that speaks plaintext gRPC to port 9200 and does not link `libgrpc++`, `libprotobuf`, abseil, re2, or c-ares. The dish child's imsg messages stay the same, so the db child does not change. Regress keeps the fake-dish runs and gains a fixture: a captured reply the C++ client already accepts, decoded by the Perl client to the same hash. The reply-shape record stays. A field the fixture newly contains is a logged name and type, not a silent drop. If a field does not match the dish, other projects may be read as documentation for that mismatch. Their source stays out of this tree. After that cut, the dish pledge drops `prot_exec` and the filesystem unveil that existed for the C++ library. The poll must still finish inside the 5 second deadline.

Do not start the Perl client until the measurements above are written down. A smaller dependency tree is the point; a slower poll is not.

## Phase 4 — leave it running

Security, crash behavior, and growth limits. The database must get coarser as it gets older, and every table a writer touches must have a ceiling. After aging, `24h`, `7d`, `30d`, `365d`, and `ever` still compute, including the SLA math.

### Controlled aging

Finer rows are deleted only inside a transaction, and only after the coarser row exists and its `sample_count` covers that window. A partial coarser row is updated when the finer data covers more samples. `ON CONFLICT DO NOTHING` must not be the reason raw samples disappear.

A coarser row keeps average, maximum, and `sample_count` for drop, latency, throughput, obstruction, and jitter. An average alone hides the outage the SLA math is about. Maximum latency, obstruction (avg and max), and jitter are already stored. This phase still requires the transaction and `sample_count` rule above. `ON CONFLICT DO NOTHING` is no longer how a null obstruction survives a retain, but a partial coarser row can still keep an older throughput value while the raw samples are deleted.

Ceilings that do not exist yet. The number in parentheses is the default of that config key. `outage_retention_days` of 0 means keep the outage row.

| Table | What survives | What is removed |
| --- | --- | --- |
| `events` | One row per confirmed outage (start, duration, type) for `outage_retention_days` (0, keep), so `365d` and `ever` still have uptime, longest outage, mean time between outages, and hour of day. `ping_ok` rows for `ping_ok_retention_days` (90). | `ping_ok` older than its knob. Outage rows older than a non-zero `outage_retention_days`. |
| `weather` | `weather_retention_days` (90) of samples, then one day row: min and max wind, precipitation, and whether a warning fired. | Samples older than that knob. |
| `speedtests` | `speedtest_retention_days` (90). | Rows older than that knob. |
| `alert_queue` | Given-up rows for `alert_given_up_days` (30), for the operator to see. | Delivered rows, and given-up rows past that knob. `notify_max_attempts` stays the attempt cap. |
| `obstruction_map` | The latest grid, plus at most one grid per day for `map_trail_days` (90) if the sky view needs a trail. | Any 5-minute history beyond that cap. |

A retain refuses to run when the clock has jumped more than `retain_clock_jump_s` (86400) since the last retain. A forward jump would otherwise delete the raw window in one pass. The refusal is an info line, and the debug line includes both timestamps and each cut the retain would have used. The refusal does not update the last-retain timestamp.

### Hardening

- A child whose pledge or unveil fails exits. It does not keep running with the pledge dropped. The parent restarts it. The notify child's promises are only those of the plugins actually enabled. A plugin that cannot reach its destination counts as a failed attempt. It does not drop the pledge.
- Schema changes are explicit steps, not "create if not exists" hoping a new column appears on an old file.
- Config file mode `0600` when `sld` writes it. `pg_password` is not logged. `slctl once` stays available to the operator and is not written into the daemon log.
- Login and logout forms carry a token tied to the session secret, so a page on another origin cannot post them.
- Nothing is added to the default listen line. Extra addresses exist only where the operator wrote them. This phase does not add TLS or a second user.
- Disk full, a locked database, and a dish that stays down are already non-fatal to the parent. Add regress coverage that the parent is still up after each of those, and that a full disk does not leave a half-applied retain.

Regress for aging: a synthetic clock two years ahead yields a bounded row count per table, daily maxima match the injected spikes, a one-day clock jump does not delete the raw window, and `ever` SLA numbers still match the injected outages.

## Phase 5 — baselines

Read the aged record. Phase 4 keeps averages and maxima so this phase can compare without the original samples.

For the selected window, compare drop, latency, throughput, and obstruction to the same hour of day in the hourly and daily history (`ever` and `365d` use day-of-year when the hour row is gone). Show median and a high percentile of that history, and how far the current bucket sits from them. When a metric stays outside that band for a configured duration, write an event. The phase 2 hook delivers it when `notify` lists a plugin. Debug logs the window, the bucket, the median, the high percentile, and the current value.

No model training, no second dish, no write RPC to the dish, no account system, no second notification path. An OpenBSD port and the existing `rc.d` script are release work at the end of phase 4, not this phase.

## Out of scope

Copied source, pages, or wording. Docker, multi-dish, 2FA, rebooting or stowing the dish, any RPC other than `get_status`, `get_history`, and the obstruction map, and a listen address the operator did not write.
