#pragma once
#include <stdint.h>
int bs_smc_open(uint32_t *connection);
void bs_smc_close(uint32_t connection);
int bs_smc_read(uint32_t connection, const char *key, uint8_t *bytes, uint32_t *length);
int bs_smc_write(uint32_t connection, const char *key, const uint8_t *bytes, uint32_t length);
typedef void (*bs_power_callback)(int sleeping, void *context);
int bs_power_start(bs_power_callback callback, void *context);
void bs_power_stop(void);
