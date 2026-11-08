#ifndef RECORDING_CARD_BRIDGE_H
#define RECORDING_CARD_BRIDGE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Callback transfers ownership of json. Keep callback alive for process lifetime;
 * free json exactly once via card_bridge_free_string (including expired tickets).
 * Intermediate envelope: {"event":...}; exactly one final {"ok":...} per request.
 * Unsolicited events use ticket 0. */
typedef void (*card_bridge_callback)(uintptr_t ticket, char *json);
const char *card_bridge_version(void); /* borrowed static string: NEVER free */
void card_bridge_free_string(char *json);
void card_bridge_set_event_callback(card_bridge_callback callback); /* NULL unregisters */
void card_bridge_request(const char *json_request, card_bridge_callback callback, uintptr_t ticket);
#ifdef __cplusplus
}
#endif
#endif
