#import "GeneratedPluginRegistrant.h"
#import "RCObjCCatch.h"
#include <TargetConditionals.h>
#include <stdint.h>

#if !TARGET_OS_SIMULATOR
typedef void (*rc_bridge_cb_t)(uintptr_t user_data, const char *json);
void card_bridge_command(
    const char *kind,
    const char *payload,
    rc_bridge_cb_t cb,
    void *user_data);
const char *card_bridge_version(void);
void card_bridge_free_string(char *ptr);

static inline uintptr_t rc_card_bridge_command_addr(void) {
  return (uintptr_t)&card_bridge_command;
}
static inline uintptr_t rc_card_bridge_free_string_addr(void) {
  return (uintptr_t)&card_bridge_free_string;
}
static inline uintptr_t rc_card_bridge_version_addr(void) {
  return (uintptr_t)&card_bridge_version;
}
#else
static inline uintptr_t rc_card_bridge_command_addr(void) { return 0; }
static inline uintptr_t rc_card_bridge_free_string_addr(void) { return 0; }
static inline uintptr_t rc_card_bridge_version_addr(void) { return 0; }
#endif
