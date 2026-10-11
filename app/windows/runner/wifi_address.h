#ifndef RUNNER_WIFI_ADDRESS_H_
#define RUNNER_WIFI_ADDRESS_H_

#include <flutter/encodable_value.h>

// Reads active IEEE 802.11 adapters without changing any network configuration.
flutter::EncodableList GetWifiIpv4Addresses();

#endif  // RUNNER_WIFI_ADDRESS_H_
