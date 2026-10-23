#include <stddef.h>
#include <stdint.h>

typedef struct PacketTunnelRuntime PacketTunnelRuntime;
PacketTunnelRuntime *proxy_packet_tunnel_create(const char *json, const char *cache_dir, char **error);
int32_t proxy_packet_tunnel_write(const PacketTunnelRuntime *handle, const uint8_t *bytes, size_t len);
int32_t proxy_packet_tunnel_read(const PacketTunnelRuntime *handle, uint8_t *bytes, size_t capacity);
int32_t proxy_packet_tunnel_switch_upstream(const PacketTunnelRuntime *handle, const char *host, uint16_t port);
void proxy_packet_tunnel_cancel(const PacketTunnelRuntime *handle);
char *proxy_packet_tunnel_last_error(const PacketTunnelRuntime *handle);
char *proxy_packet_tunnel_routing_stats(const PacketTunnelRuntime *handle);
void proxy_packet_tunnel_destroy(PacketTunnelRuntime *handle);
void proxy_free_string(char *value);

typedef struct {
  int32_t success;
  char *country_code;
  char *egress_ip;
  uint64_t latency_ms;
  char *error;
} NodeProbeResult;
typedef void (*NodeProbeCallback)(uint64_t batch, uint32_t index, NodeProbeResult *result);
int32_t proxy_probe_nodes_v1(const char *const *hosts, const uint16_t *ports, uint32_t count,
                            uint32_t concurrency, uint32_t timeout_ms, int32_t protocol,
                            NodeProbeCallback callback, uint64_t batch);
void proxy_release_node_probe_result(NodeProbeResult *result);

void proxy_init_logging(void);
void proxy_set_log_level(int32_t level);
void proxy_set_log_callback(void (*callback)(int32_t level, const char *message));
