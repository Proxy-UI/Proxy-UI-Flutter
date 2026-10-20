#include <stddef.h>
#include <stdint.h>

typedef struct PacketTunnelRuntime PacketTunnelRuntime;
PacketTunnelRuntime *proxy_packet_tunnel_create(const char *json, const char *cache_dir, char **error);
int32_t proxy_packet_tunnel_write(const PacketTunnelRuntime *handle, const uint8_t *bytes, size_t len);
int32_t proxy_packet_tunnel_read(const PacketTunnelRuntime *handle, uint8_t *bytes, size_t capacity);
void proxy_packet_tunnel_cancel(const PacketTunnelRuntime *handle);
char *proxy_packet_tunnel_last_error(const PacketTunnelRuntime *handle);
void proxy_packet_tunnel_destroy(PacketTunnelRuntime *handle);
void proxy_free_string(char *value);

void proxy_init_logging(void);
void proxy_set_log_level(int32_t level);
void proxy_set_log_callback(void (*callback)(int32_t level, const char *message));
