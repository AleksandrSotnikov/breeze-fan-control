#ifndef SMC_BRIDGE_H
#define SMC_BRIDGE_H
#include <stdint.h>
int fw_open(uint32_t *connection);
void fw_close(uint32_t connection);
int fw_number(uint32_t connection, const char *key, double *value);
int fw_write(uint32_t connection, const char *key, double value);
int fw_key_at(uint32_t connection, uint32_t index, char key[5]);
int fw_codec_test(void);
void fw_signals_install(void);
int fw_stopping(void);
#endif
