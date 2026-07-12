# App Review notes

iADB has no login or server account. It connects to an Android 11 or newer device over the review device's local Wi-Fi network.

## Test setup

1. Put the iPhone or iPad and Android device on the same Wi-Fi network.
2. On Android, enable Developer options and Wireless debugging.
3. Open **Pair device with pairing code** on Android.
4. In iADB, open **Device**, tap **Connect a Device**, then choose **Pair Manually** or select the discovered device. Enter the address, pairing port, and six-digit code shown by Android.
5. After pairing, iADB connects automatically if the discovered Bonjour service remains available. Otherwise, enter the IP address and regular Wireless debugging port from Android's main Wireless debugging screen, then tap **Connect**. Allow Local Network access when iOS asks.

After connection, Device, Files, Apps, Console, and Screens become available. Console contains Shell and Logs. Screens can save a captured Android screenshot to Photos after the reviewer grants add-only Photos access.

The pairing port and regular Wireless debugging port differ. If Android closes its pairing dialog before step 4, open the dialog again and use the new code and port.

The app uses TLS, RSA authentication, SPAKE2 pairing, and AES-GCM as required by Android's wireless ADB protocol. The `ITSAppUsesNonExemptEncryption` flag is set to `true`; complete the export-compliance questions in App Store Connect for the selected distribution regions.
