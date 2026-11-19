# Perl gRPC sketch

Exploration on `plgrpc` only. The dish child still loads `SLMON::Dish` and still links `libgrpc++`. `ext/dishbridge` stays. `DishProc` does not call this module. The pledge is unchanged. No phase-3 measurements were taken.

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

`lib/SLMON/DishWire.pm` is the in-tree client. No new Perl package. `request_bytes` builds the three empty bodies and nothing else. `wire_request` is the frozen bytes the fixture checks: the client preface, an empty SETTINGS frame, uncompressed HPACK headers (`:method` POST, `:scheme` http, `:path` `/SpaceX.API.Device.Device/Handle`, `:authority`, `content-type: application/grpc`, `te: trailers`), and one DATA frame. `call($target, $op)` is the socket. It does not use that empty SETTINGS frame. It sends SETTINGS with push disabled, a 1 MiB stream window, and a 64 KiB max frame, then a connection WINDOW_UPDATE of 1 MiB, the same headers plus `grpc-timeout: 5S`, and one DATA frame. The deadline is 5 seconds, including the connect.

The read loop acks a peer SETTINGS, answers a PING, and ignores a WINDOW_UPDATE. A DATA frame is unpadded and appended. Each DATA frame also returns that many bytes to the connection window and to stream 1, because the default 65535 connection window is smaller than the map. HEADERS and CONTINUATION are decoded as HPACK, including Huffman and the dynamic table. `:status` must be 200. A present content-type must be `application/grpc`. The trailers (the HEADERS block that ends the stream) must carry `grpc-status: 0`. `decode_reply` then returns `op`, `doc`, `unknown`, and `retyped` for that one uncompressed grpc message.

A negative int32 is a 10-byte varint, sign-extended, so bit 63 is set. The decoder keeps those 64 bits. An 11th byte, or a tenth byte other than 0 or 1, is rejected. `utc_offset_s` is one of those varints and is still not a key.

One `get_history` does not pop or clear the dish ring. The collector dedupes by sample counter, so the read does not steal samples from `sld`. One `dish_get_obstruction_map` does not reset the grid. There is no clear, reboot, or stow request in the generated `Request`, and this client does not send one.

`regress/plgrpc.pl` does not open the dish. It decodes fixtures, including one timestamp that is not exact in IEEE binary64, a negative `utc_offset_s`, and the RFC 7541 Huffman examples. A loopback peer sends a map larger than 65535 bytes and checks that the client raised both windows and acked SETTINGS before the body. `make regress` does not run the live check. `make -C regress run-plgrpc-live` does, once per op.

## Live comparison

Target `192.168.100.1:9200` from `etc/sl.conf`. Shape only. No device id, no serial, no sample dump.

An earlier status reply was rejected before history or map were sent: the decoder then refused a 10-byte varint. That is the negative-int32 case above. On the run after that fix, the Perl `call` and `SLMON::Dish::call` each ran once for status, history, and map.

Status: the same keys the fixture stores. `legacy_state` is null on both sides. Leaves on the Perl hash: 17 numbers, 25 bools, 4 strings, 2 nulls (the legacy state and one other leaf). The other side matches those types. `unknown` 28, `retyped` 0.

History: `current` is a number on both sides. The four packed arrays are each 900 long on both sides. `unknown` 3, `retyped` 0.

Map: both sides are 123 by 123, and `snr` has 15129 floats, which is 123×123. `unknown` 3, `retyped` 0.

The later cut, after measurements, would point `DishProc` at this module and then drop `prot_exec` and the C++ unveil list. That cut is not this branch.
