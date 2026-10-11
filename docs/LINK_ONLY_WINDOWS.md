# LocalSend 1.16.1 Wi-Fi Link-Only test edition

This portable Windows x64 edition disables automatic and manual multicast,
subnet and favorite-device discovery. It preserves Share via link, QR codes,
PINs, approval of download requests, and optional HTTPS. The native Windows
adapter query uses active IEEE 802.11 interfaces, without relying on adapter
names, language, or default routes. The server binds to the first usable Wi-Fi
IPv4 address, never a wildcard or Ethernet address. Only web sharing routes are
installed; ordinary device-to-device sending and reception are unavailable.

No network routes, adapter settings, drivers, or firewall rules are changed by
the application. Lack of a Wi-Fi address prevents sharing. If the bound address
disappears, the five-second address check closes the server and active transfers.
Click Retry to create a new link after reconnecting. Other Wi-Fi addresses on a
computer with multiple Wi-Fi adapters are not advertised.

## Run the ZIP

1. Extract the whole ZIP to a writable folder. Keep the executable, DLLs, data
   directory and settings.json together. Close the original LocalSend first.
2. Run localsend_app.exe. The application title says LocalSend Link-Only.
   settings.json keeps this edition's preferences separate from the installed app.
3. Connect the PC and receiving phone/Mac to the same Wi-Fi. Open Send, select
   files, then click Share via link. Open the displayed URL in the other device's
   browser or scan its QR code. Approve the request on the PC.
4. Check that the downloaded bytes match the originals. Repeat with a PIN and
   HTTPS (the existing self-signed certificate warning is expected with HTTPS).
5. Disconnect Wi-Fi. The sharing server should stop within five seconds. A retry
   must report that no Wi-Fi IPv4 address is available; it must not use Ethernet.
   Reconnect Wi-Fi and click Retry to create a working link again.

## Verify network isolation on your computer

Keep Ethernet connected during the test. Before and after opening Send and
downloading files, inspect `Get-NetAdapter` and the Windows System event log for
new link-down events. This build removes discovery as a suspected trigger; it
does not establish the cause of the previous Ethernet interruption.

With Wireshark/Npcap, capture on both Wi-Fi and Ethernet before launching the app.
Use `udp.port == 53317 || ip.dst == 224.0.0.167` to check for LocalSend discovery;
there should be none from this edition. The default sharing port is TCP 53317.
Check both captures for TCP connection attempts to many subnet addresses; there
should be no subnet or favorite scanning. During a download, TCP sharing traffic
should appear only on Wi-Fi. Open the Ethernet IP with the sharing port from an
Ethernet peer: this edition should not answer. `Get-NetTCPConnection -LocalPort
53317 -State Listen` should show the Wi-Fi IPv4 address, never 0.0.0.0 or the
Ethernet IP. `Get-NetUDPEndpoint -LocalPort 53317` should show no endpoint owned
by this process. Close other LocalSend instances to avoid confusing their traffic.

## Build and review

The source is based on the upstream v1.16.1 tag (216eb5e2).
Normal builds keep existing behavior. The test edition is enabled by:

    flutter build windows --release --dart-define=LOCALSEND_LINK_ONLY=true

Use Flutter 3.24.4 and Visual Studio's Desktop development with C++ workload.
The Windows Wi-Fi link-only test build workflow analyzes and tests both modes,
tests the common library, compiles the Windows executable, and uploads the ZIP.
The ZIP is an unsigned test build.
