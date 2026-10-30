#include "SMCBridge.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stddef.h>
#include <string.h>

// AppleSMC user-client wire layout. Protocol references are recorded in NOTICE.md.
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } Version;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } Limits;
typedef struct { uint32_t size, type; uint8_t attributes; } KeyInfo;
typedef struct {
    uint32_t key; Version version; Limits limits; KeyInfo info;
    uint8_t result, status, command; uint32_t index; uint8_t bytes[32];
} Message;
_Static_assert(sizeof(Message) == 80, "SMC ABI size");
_Static_assert(offsetof(Message, bytes) == 48, "SMC ABI payload offset");

static uint32_t key_number(const char *key) {
    return ((uint32_t)(uint8_t)key[0] << 24) | ((uint32_t)(uint8_t)key[1] << 16) |
           ((uint32_t)(uint8_t)key[2] << 8) | (uint8_t)key[3];
}
static int exchange(uint32_t connection, Message *request, Message *response) {
    size_t length = sizeof(*response);
    kern_return_t result = IOConnectCallStructMethod(connection, 2, request, sizeof(*request), response, &length);
    if (result != KERN_SUCCESS) return (int)result;
    if (length != sizeof(*response) || response->result) return -1;
    return 0;
}
int bs_smc_open(uint32_t *connection) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return -2;
    int result = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    return result;
}
void bs_smc_close(uint32_t connection) { if (connection) IOServiceClose(connection); }
static int info(uint32_t connection, const char *key, KeyInfo *output) {
    if (!key || strlen(key) != 4) return -3;
    Message request = {0}, response = {0};
    request.key = key_number(key); request.command = 9;
    int result = exchange(connection, &request, &response);
    if (result) return result;
    if (response.info.size == 0 || response.info.size > 32) return -4;
    *output = response.info;
    return 0;
}
int bs_smc_read(uint32_t connection, const char *key, uint8_t *bytes, uint32_t *length) {
    KeyInfo metadata = {0}; int result = info(connection, key, &metadata);
    if (result) return result;
    if (!bytes || !length || *length < metadata.size) return -5;
    Message request = {0}, response = {0};
    request.key = key_number(key); request.info = metadata; request.command = 5;
    result = exchange(connection, &request, &response);
    if (result) return result;
    *length = metadata.size; memcpy(bytes, response.bytes, metadata.size); return 0;
}
int bs_smc_write(uint32_t connection, const char *key, const uint8_t *bytes, uint32_t length) {
    // Charge gates and the legacy adapter gate used only for explicit calibration.
    if (!key || (strcmp(key, "CH0B") && strcmp(key, "CH0C") && strcmp(key, "CH0I"))) return -6;
    if (!bytes || length != 1) return -5;
    if (strcmp(key, "CH0I") == 0) {
        if (bytes[0] != 0 && bytes[0] != 1) return -7;
    } else if (bytes[0] != 0 && bytes[0] != 2) return -7;
    KeyInfo metadata = {0}; int result = info(connection, key, &metadata);
    if (result) return result;
    if (!bytes || length != metadata.size || length > 32) return -5;
    Message request = {0}, response = {0};
    request.key = key_number(key); request.info = metadata; request.command = 6;
    memcpy(request.bytes, bytes, length);
    return exchange(connection, &request, &response);
}

static io_connect_t power_root;
static IONotificationPortRef power_port;
static io_object_t power_notifier;
static bs_power_callback power_callback;
static void *power_context;
static void power_event(void *ref, io_service_t service, natural_t type, void *argument) {
    (void)ref; (void)service;
    if (type == kIOMessageSystemWillSleep) {
        if (power_callback) power_callback(1, power_context);
        IOAllowPowerChange(power_root, (long)argument);
    } else if (type == kIOMessageCanSystemSleep) {
        IOAllowPowerChange(power_root, (long)argument);
    } else if (type == kIOMessageSystemHasPoweredOn && power_callback) {
        power_callback(0, power_context);
    }
}
int bs_power_start(bs_power_callback callback, void *context) {
    power_callback = callback; power_context = context;
    power_root = IORegisterForSystemPower(NULL, &power_port, power_event, &power_notifier);
    if (!power_root) return -1;
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(power_port), kCFRunLoopCommonModes);
    return 0;
}
void bs_power_stop(void) {
    if (!power_root) return;
    CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(power_port), kCFRunLoopCommonModes);
    IODeregisterForSystemPower(&power_notifier); IOServiceClose(power_root);
    IONotificationPortDestroy(power_port); power_root = 0;
}
