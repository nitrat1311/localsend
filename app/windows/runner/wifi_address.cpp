#include "wifi_address.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>

#include <stdexcept>
#include <vector>

flutter::EncodableList GetWifiIpv4Addresses(bool include_prefix) {
  ULONG size = 16384;
  std::vector<unsigned char> buffer(size);
  ULONG status = ERROR_BUFFER_OVERFLOW;
  for (int attempt = 0; attempt < 3; ++attempt) {
    buffer.resize(size);
    status = GetAdaptersAddresses(
        AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                     GAA_FLAG_SKIP_DNS_SERVER,
        nullptr, reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data()), &size);
    if (status != ERROR_BUFFER_OVERFLOW) break;
  }
  if (status == ERROR_NO_DATA) return {};
  if (status != NO_ERROR) {
    throw std::runtime_error("Could not enumerate Wi-Fi adapters");
  }

  flutter::EncodableList addresses;
  for (auto* adapter = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
       adapter != nullptr; adapter = adapter->Next) {
    if (adapter->IfType != IF_TYPE_IEEE80211 ||
        adapter->OperStatus != IfOperStatusUp) continue;
    for (auto* unicast = adapter->FirstUnicastAddress; unicast != nullptr;
         unicast = unicast->Next) {
      if (unicast->DadState != IpDadStatePreferred ||
          unicast->Address.lpSockaddr == nullptr ||
          unicast->Address.lpSockaddr->sa_family != AF_INET) continue;
      const auto* addr = reinterpret_cast<const sockaddr_in*>(
          unicast->Address.lpSockaddr);
      char text[INET_ADDRSTRLEN] = {};
      if (InetNtopA(AF_INET, const_cast<IN_ADDR*>(&addr->sin_addr), text,
                    sizeof(text)) != nullptr) {
        if (include_prefix) {
          addresses.emplace_back(flutter::EncodableMap{
              {flutter::EncodableValue("address"), flutter::EncodableValue(std::string(text))},
              {flutter::EncodableValue("prefixLength"),
               flutter::EncodableValue(static_cast<int>(unicast->OnLinkPrefixLength))}});
        } else {
          addresses.emplace_back(std::string(text));
        }
      }
    }
  }
  return addresses;
}
