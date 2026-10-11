# LocalSend Wi-Fi Sender for Windows (based on 1.16.1)

This portable edition sends files from Windows to the LocalSend receiver on an
iPhone. Windows makes outgoing TCP connections only. Keep Windows Defender
Firewall and antivirus enabled. No administrator rights, incoming firewall rule,
installation, routing change, or adapter change is required on the PC.

## Start here

1. Extract the entire ZIP into a folder you can write to, such as your Desktop.
   Close the older LocalSend build and run `localsend_app.exe` normally.
2. Install/open the official LocalSend app on your iPhone:
   https://apps.apple.com/app/localsend/id1661733229
3. Allow LocalSend's **Local Network** permission on the iPhone. If previously
   denied, enable it in iOS Settings > Privacy & Security > Local Network.
   Keep LocalSend in the foreground and the iPhone screen awake while receiving.
4. Connect both devices to the same Wi-Fi. Leave the PC's wired connection alone.
5. Find the iPhone's address in iOS Settings > Wi-Fi > the information button
   beside your connected network > **IP Address** (for example 192.168.1.25).
6. On the PC, select files or a folder, click **Send to iPhone**, enter that IP
   address, and click **Send to iPhone** again. Accept the offer in the iPhone app.
7. Use LocalSend's received-file history or the iPhone Files app to open the files.
   Their destination depends on the iPhone's LocalSend save settings.

The receiver is the iPhone app, not a Safari/Chrome tab. This edition replaces
PC-hosted browser links with direct upload. It does not receive files on the PC.

## Optional settings

- The default receiver port is TCP 53317. If changed in the iPhone app, enter that
  value under **PIN, port and encryption** on the PC.
- HTTPS encryption is enabled by default. Match the iPhone app's Encryption
  setting. HTTP is available only if explicitly selected; there is no automatic
  downgrade. LocalSend uses self-signed TLS certificates. The entered receiver's
  certificate is pinned for the duration of each transfer.
- Enter a receive PIN only if configured on the iPhone. PINs are not saved.
- The PC remembers the receiver's address, port and encryption preference in
  the portable settings file. A new router may assign a different iPhone address.
- Cancellation closes the PC connection and attempts to cancel the offer/session
  on the phone. If Wi-Fi was lost, dismiss a pending offer on the iPhone manually.
- A transfer is reported as successful only after the receiver confirms the uploads. Files
  not selected by the receiver are reported separately.

## Network behavior

- No PC HTTP/HTTPS server, loopback instance listener, multicast announcement,
  device discovery, subnet scan, favorite scan, or registration request.
- Windows enumerates active IEEE 802.11 adapters and their actual IPv4 prefixes.
  The iPhone must be on an active Wi-Fi subnet. There is no Ethernet fallback.
- Each TCP socket binds to that Wi-Fi IPv4 address; no hostname lookup or proxy
  is used. The selected Wi-Fi address is rechecked before requests and new sockets.
  A changed or missing connection stops the transfer.
- Only the explicitly entered receiver is contacted. Redirects are refused.
- An organization that explicitly blocks outgoing connections can still prevent
  transfers. This app does not change or override administrative policies.
- Guest Wi-Fi/client isolation can block communication between the two devices.
  Use a Wi-Fi network that permits devices to communicate locally.

## Test on your PC

Keep Windows Firewall on for all profiles. Run the executable as a normal user
with Ethernet and Wi-Fi connected. Send a small file, several files, a folder,
and a larger file to the iPhone; check their contents. Verify the cable network
stays connected. Try denying the offer, an incorrect PIN, canceling, and losing
Wi-Fi: no traffic should fall back to the wired adapter. The Windows build and
protocol tests run in GitHub Actions; the real iPhone/router combination must be
tested on your devices.

## Build

Flutter 3.24.4:

```
cd app
flutter pub get
flutter build windows --release --dart-define=LOCALSEND_OUTGOING_ONLY=true
```

Normal builds and the earlier LOCALSEND_LINK_ONLY edition retain their behavior.
