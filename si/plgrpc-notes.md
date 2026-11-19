# Perl gRPC sketch

Exploration on `plgrpc` only. The dish child still loads `SLMON::Dish` and still links `libgrpc++`. `ext/dishbridge` stays. The live dish was not contacted. No phase-3 measurements were taken, and the pledge is unchanged.

## What the bridge sends

`SLMON::Dish::call($target, $op)` takes `status`, `history`, or `map`. The channel is insecure, the deadline is 5 seconds, and the RPC is `SpaceX.API.Device.Device/Handle`. The lowercase service name is rejected. Each call sends one `Request`. The oneof is an empty message:

| op | field | protobuf |
| --- | --- | --- |
| status | get_status = 1004 | e2 3e 00 |
| history | get_history = 1007 | fa 3e 00 |
| map | dish_get_obstruction_map = 2008 | c2 7d 00 |

On the wire those bytes sit in a grpc length prefix (a 0 compression byte, then a 4-byte big-endian length) inside an HTTP/2 DATA frame. The client preface is the HTTP/2 magic followed by an empty SETTINGS frame, then HEADERS, then that DATA frame. `protoc --encode` produced the three protobufs above. The regress freezes them; it does not shell out.

## What must stay stable

The grpc body is a `Response`. The oneof the child keeps is `dish_get_status` = 2004, `dish_get_history` = 2006, or `dish_get_obstruction_map` = 2008. `api_version` (field 3) is not in the JSON.

`SLMON::Dish::call` returns a JSON string. `DishProc` runs `SLMON::json_decode`. That hash is what `StatusMap`, `History`, and `pack_map` read. The imsg types (`IMSG_STATUS`, `IMSG_DISH_INFO`, `IMSG_EVENT`, `IMSG_HISTORY`, `IMSG_OBSTRUCTION`) do not change, so the db child does not change.

Bools are JSON true and false. A missing number is 0, and a missing string is empty, because the C++ getters still print the proto3 default. `legacy_state` is the exception. It is unknown field 1006, a varint, on `DishGetStatusResponse`. It is null when the reply does not carry it. Do not treat that null as 0. The crib notes it has come back as a unix timestamp.

Status hash: `legacy_state`, and `status` with `device_info` (`id`, `hardware_version`, `software_version`, `country_code`, `bootcount`), `device_state` (`uptime_s`), the nineteen `alerts` bools, `obstruction_stats` (`fraction_obstructed`, `valid_s`, `currently_obstructed`, `avg_prolonged_obstruction_duration_s`, `avg_prolonged_obstruction_interval_s`), `gps_stats` (`gps_valid`, `gps_sats`, `inhibit_gps`), then `seconds_to_first_nonempty_slot`, `pop_ping_drop_rate`, `downlink_throughput_bps`, `uplink_throughput_bps`, `pop_ping_latency_ms`, `stow_requested`, `boresight_azimuth_deg`, `boresight_elevation_deg`, `is_snr_above_noise_floor`, `signal_quality`, and `outage` (`cause`, `start_timestamp_ns`, `duration_ns`, `did_switch`). `utc_offset_s` is in the proto and is not a key.

History hash: `current`, the four packed float arrays, and `outages`. `History::ring_samples` still clears latency when the drop rate is at least 1. Map hash: `num_rows`, `num_cols`, `snr`. A non-finite float is JSON null.

A field this code does not name is not stored. A stored field on the wrong wire type is not stored. Both are reported (message, number, wire type, and the name when we have one). A dropped field, compared with an earlier reply, is not detected here.

## Approach

`lib/SLMON/DishWire.pm` is the in-tree client. No new Perl package. `request_bytes` builds the three requests. `wire_request` builds the client preface, empty SETTINGS, uncompressed HPACK headers (`:method` POST, `:scheme` http, `:path` `/SpaceX.API.Device.Device/Handle`, `:authority`, `content-type: application/grpc`, `te: trailers`), and one DATA frame. `unwrap_http2` concatenates DATA payloads, including a message split across frames, and skips other frames. `decode_reply` takes one uncompressed grpc message and returns `op`, `doc`, `unknown`, and `retyped`.

Not in this sketch: a socket, the SETTINGS ack, flow-control updates, Huffman-coded HPACK, and grpc-status trailers. A varint that does not fit a signed 64-bit integer is rejected. The later cut, after measurements, would point `DishProc` at this module and then drop `prot_exec` and the C++ unveil list. That cut is not this branch.

`regress/plgrpc.pl` decodes fixtures built from the field numbers above, including one timestamp that is not exact in IEEE binary64, and checks the hash `StatusMap` and `History` already consume.
