#ifndef OPENSCQ30_MACOS_NATIVE_H
#define OPENSCQ30_MACOS_NATIVE_H

#include <stddef.h>
#include <stdint.h>

typedef void (*openscq30_device_callback)(void *context, const char *name,
                                          const char *address);
typedef void (*openscq30_service_callback)(void *context,
                                           const uint8_t uuid[16],
                                           uint8_t channel);
typedef void (*openscq30_data_callback)(void *context, const uint8_t *data,
                                        size_t length);
typedef void (*openscq30_disconnect_callback)(void *context);

int32_t openscq30_macos_enumerate_devices(openscq30_device_callback callback,
                                          void *context);
int32_t openscq30_macos_enumerate_services(const char *address,
                                           openscq30_service_callback callback,
                                           void *context);

void *
openscq30_macos_open_rfcomm(const char *address, uint8_t channel,
                            openscq30_data_callback data_callback,
                            openscq30_disconnect_callback disconnect_callback,
                            void *context, int32_t *status);
int32_t openscq30_macos_rfcomm_write(void *connection, const uint8_t *data,
                                     size_t length);
void openscq30_macos_rfcomm_release(void *connection);

#endif
