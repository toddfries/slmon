#include "dishbridge.h"

#include <grpcpp/grpcpp.h>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <sstream>
#include <string>

#include "spacex_device.grpc.pb.h"
#include "spacex_device.pb.h"

namespace {

std::shared_ptr<grpc::Channel> g_channel;
std::unique_ptr<spacex::api::device::Device::Stub> g_stub;
std::string g_target;

void
reset_channel()
{
	g_stub.reset();
	g_channel.reset();
	g_target.clear();
}

int
ensure_channel(const std::string &target, std::string &err)
{
	if (g_stub && g_target == target)
		return 0;
	reset_channel();
	g_channel = grpc::CreateChannel(target, grpc::InsecureChannelCredentials());
	if (!g_channel) {
		err = "CreateChannel failed";
		return -1;
	}
	g_stub = spacex::api::device::Device::NewStub(g_channel);
	g_target = target;
	return 0;
}

void
jesc(std::ostream &o, const std::string &s)
{
	static const char *hex = "0123456789abcdef";
	o << '"';
	for (unsigned char c : s) {
		if (c == '"' || c == '\\')
			o << '\\' << static_cast<char>(c);
		else if (c < 0x20) {
			o << "\\u00" << hex[c >> 4] << hex[c & 0xf];
		} else
			o << static_cast<char>(c);
	}
	o << '"';
}

void
jfloat(std::ostream &o, float v)
{
	if (!std::isfinite(v)) {
		o << "null";
		return;
	}
	std::ostringstream n;
	n.setf(std::ios::fmtflags(0), std::ios::floatfield);
	n.precision(8);
	n << v;
	o << n.str();
}

void
jbool(std::ostream &o, bool v)
{
	o << (v ? "true" : "false");
}

int
legacy_state(const google::protobuf::Message &msg)
{
	const google::protobuf::UnknownFieldSet &ufs =
	    msg.GetReflection()->GetUnknownFields(msg);
	for (int i = 0; i < ufs.field_count(); i++) {
		const google::protobuf::UnknownField &f = ufs.field(i);
		if (f.number() == 1006 &&
		    f.type() == google::protobuf::UnknownField::TYPE_VARINT)
			return static_cast<int>(f.varint());
	}
	return -1;
}

std::string
status_json(const spacex::api::device::DishGetStatusResponse &st)
{
	const auto &info = st.device_info();
	const auto &dev = st.device_state();
	const auto &al = st.alerts();
	const auto &ob = st.obstruction_stats();
	const auto &gps = st.gps_stats();
	const auto &out = st.outage();
	int legacy = legacy_state(st);
	std::ostringstream o;
	o << "{\"legacy_state\":";
	if (legacy < 0)
		o << "null";
	else
		o << legacy;
	o << ",\"status\":{";
	o << "\"device_info\":{";
	o << "\"id\":"; jesc(o, info.id());
	o << ",\"hardware_version\":"; jesc(o, info.hardware_version());
	o << ",\"software_version\":"; jesc(o, info.software_version());
	o << ",\"country_code\":"; jesc(o, info.country_code());
	o << ",\"bootcount\":" << info.bootcount();
	o << "},\"device_state\":{\"uptime_s\":" << dev.uptime_s() << "}";
	o << ",\"alerts\":{";
	o << "\"motors_stuck\":"; jbool(o, al.motors_stuck());
	o << ",\"thermal_shutdown\":"; jbool(o, al.thermal_shutdown());
	o << ",\"thermal_throttle\":"; jbool(o, al.thermal_throttle());
	o << ",\"unexpected_location\":"; jbool(o, al.unexpected_location());
	o << ",\"mast_not_near_vertical\":"; jbool(o, al.mast_not_near_vertical());
	o << ",\"slow_ethernet_speeds\":"; jbool(o, al.slow_ethernet_speeds());
	o << ",\"install_pending\":"; jbool(o, al.install_pending());
	o << ",\"is_heating\":"; jbool(o, al.is_heating());
	o << ",\"power_supply_thermal_throttle\":"; jbool(o, al.power_supply_thermal_throttle());
	o << ",\"is_power_save_idle\":"; jbool(o, al.is_power_save_idle());
	o << ",\"dbf_telem_stale\":"; jbool(o, al.dbf_telem_stale());
	o << ",\"low_motor_current\":"; jbool(o, al.low_motor_current());
	o << ",\"lower_signal_than_predicted\":"; jbool(o, al.lower_signal_than_predicted());
	o << ",\"slow_ethernet_speeds_100\":"; jbool(o, al.slow_ethernet_speeds_100());
	o << ",\"obstruction_map_reset\":"; jbool(o, al.obstruction_map_reset());
	o << ",\"dish_water_detected\":"; jbool(o, al.dish_water_detected());
	o << ",\"router_water_detected\":"; jbool(o, al.router_water_detected());
	o << ",\"upsu_router_port_slow\":"; jbool(o, al.upsu_router_port_slow());
	o << ",\"no_ethernet_link\":"; jbool(o, al.no_ethernet_link());
	o << "}";
	o << ",\"obstruction_stats\":{";
	o << "\"fraction_obstructed\":"; jfloat(o, ob.fraction_obstructed());
	o << ",\"valid_s\":"; jfloat(o, ob.valid_s());
	o << ",\"currently_obstructed\":"; jbool(o, ob.currently_obstructed());
	o << ",\"avg_prolonged_obstruction_duration_s\":";
	jfloat(o, ob.avg_prolonged_obstruction_duration_s());
	o << ",\"avg_prolonged_obstruction_interval_s\":";
	jfloat(o, ob.avg_prolonged_obstruction_interval_s());
	o << "}";
	o << ",\"gps_stats\":{";
	o << "\"gps_valid\":"; jbool(o, gps.gps_valid());
	o << ",\"gps_sats\":" << gps.gps_sats();
	o << ",\"inhibit_gps\":"; jbool(o, gps.inhibit_gps());
	o << "}";
	o << ",\"seconds_to_first_nonempty_slot\":";
	jfloat(o, st.seconds_to_first_nonempty_slot());
	o << ",\"pop_ping_drop_rate\":"; jfloat(o, st.pop_ping_drop_rate());
	o << ",\"downlink_throughput_bps\":"; jfloat(o, st.downlink_throughput_bps());
	o << ",\"uplink_throughput_bps\":"; jfloat(o, st.uplink_throughput_bps());
	o << ",\"pop_ping_latency_ms\":"; jfloat(o, st.pop_ping_latency_ms());
	o << ",\"stow_requested\":"; jbool(o, st.stow_requested());
	o << ",\"boresight_azimuth_deg\":"; jfloat(o, st.boresight_azimuth_deg());
	o << ",\"boresight_elevation_deg\":"; jfloat(o, st.boresight_elevation_deg());
	o << ",\"is_snr_above_noise_floor\":"; jbool(o, st.is_snr_above_noise_floor());
	o << ",\"signal_quality\":"; jfloat(o, st.signal_quality());
	o << ",\"outage\":{\"cause\":" << out.cause();
	o << ",\"start_timestamp_ns\":" << out.start_timestamp_ns();
	o << ",\"duration_ns\":" << out.duration_ns();
	o << ",\"did_switch\":"; jbool(o, out.did_switch());
	o << "}}}";
	return o.str();
}

void
jfloats(std::ostream &o, const google::protobuf::RepeatedField<float> &v)
{
	o << '[';
	for (int i = 0; i < v.size(); i++) {
		if (i)
			o << ',';
		jfloat(o, v.Get(i));
	}
	o << ']';
}

std::string
history_json(const spacex::api::device::DishGetHistoryResponse &h)
{
	std::ostringstream o;
	o << "{\"current\":" << h.current();
	o << ",\"pop_ping_drop_rate\":";
	jfloats(o, h.pop_ping_drop_rate());
	o << ",\"pop_ping_latency_ms\":";
	jfloats(o, h.pop_ping_latency_ms());
	o << ",\"downlink_throughput_bps\":";
	jfloats(o, h.downlink_throughput_bps());
	o << ",\"uplink_throughput_bps\":";
	jfloats(o, h.uplink_throughput_bps());
	o << ",\"outages\":[";
	for (int i = 0; i < h.outages_size(); i++) {
		const auto &out = h.outages(i);
		if (i)
			o << ',';
		o << "{\"cause\":" << out.cause();
		o << ",\"start_timestamp_ns\":" << out.start_timestamp_ns();
		o << ",\"duration_ns\":" << out.duration_ns();
		o << ",\"did_switch\":"; jbool(o, out.did_switch());
		o << '}';
	}
	o << "]}";
	return o.str();
}

std::string
map_json(const spacex::api::device::DishGetObstructionMapResponse &m)
{
	std::ostringstream o;
	o << "{\"num_rows\":" << m.num_rows();
	o << ",\"num_cols\":" << m.num_cols();
	o << ",\"snr\":";
	jfloats(o, m.snr());
	o << '}';
	return o.str();
}

int
rpc(const char *op, spacex::api::device::Response &resp, std::string &err)
{
	grpc::ClientContext ctx;
	ctx.set_deadline(std::chrono::system_clock::now() + std::chrono::seconds(5));
	spacex::api::device::Request req;
	if (std::strcmp(op, "status") == 0)
		req.mutable_get_status();
	else if (std::strcmp(op, "history") == 0)
		req.mutable_get_history();
	else if (std::strcmp(op, "map") == 0)
		req.mutable_dish_get_obstruction_map();
	else {
		err = std::string("unknown dish op ") + op;
		return -1;
	}
	grpc::Status st = g_stub->Handle(&ctx, req, &resp);
	if (!st.ok()) {
		err = std::string(op) + " rpc: " + st.error_message();
		reset_channel();
		return -1;
	}
	return 0;
}

}  // namespace

extern "C" int
slmon_dish_call(const char *target, const char *op, char **out, char **err)
{
	std::string e;
	*out = NULL;
	*err = NULL;
	if (target == NULL || op == NULL) {
		*err = strdup("missing target or op");
		return -1;
	}
	if (ensure_channel(target, e) != 0) {
		*err = strdup(e.c_str());
		return -1;
	}
	spacex::api::device::Response resp;
	if (rpc(op, resp, e) != 0) {
		*err = strdup(e.c_str());
		return -1;
	}
	std::string body;
	if (std::strcmp(op, "status") == 0) {
		if (!resp.has_dish_get_status()) {
			*err = strdup("status rpc returned no dish_get_status");
			return -1;
		}
		body = status_json(resp.dish_get_status());
	} else if (std::strcmp(op, "history") == 0) {
		if (!resp.has_dish_get_history()) {
			*err = strdup("history rpc returned no dish_get_history");
			return -1;
		}
		body = history_json(resp.dish_get_history());
	} else if (std::strcmp(op, "map") == 0) {
		if (!resp.has_dish_get_obstruction_map()) {
			*err = strdup("map rpc returned no dish_get_obstruction_map");
			return -1;
		}
		body = map_json(resp.dish_get_obstruction_map());
	} else {
		*err = strdup("unknown dish op");
		return -1;
	}
	*out = strdup(body.c_str());
	if (*out == NULL) {
		*err = strdup("strdup failed");
		return -1;
	}
	return 0;
}
