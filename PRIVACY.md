# Vesta — Privacy Policy

_Last updated: 23 November 2026_

Vesta is a native iOS client for a **self-hosted hestia home server**. It is not a
cloud service and has no backend of its own.

## What Vesta collects

**Nothing.** Vesta does not collect, transmit, or sell any personal data, and it
contains no analytics, advertising, or third-party tracking SDKs.

## What Vesta stores on your device

All of the following is kept **only on your device** and is never sent to the
developer or to any third party:

- **The server address** you enter, so the app can reconnect (stored in the app's
  local settings).
- **A sign-in token** for your server, kept securely in the iOS Keychain.
- **Your preferences** (language and temperature unit).

## Where your data goes

Vesta communicates **only** with the hestia server whose address you provide. Your
home data (devices, rooms, temperatures, etc.) lives on that server, which you or
the person who set it up control. Vesta sends commands to, and reads status from,
that server and nowhere else.

## Receipts (optional)

If your hestia server has its budget module and receipts turned on, an account
with receipt access can add a paper receipt from Vesta:

- **Device pairing.** On supported servers, Vesta sends your sign-in token, a
  generated device name, and the previous device token if available to your
  hestia server to exchange for a scoped device token. Vesta keeps the device
  token, the account and ledger identifiers, its permissions, and any pending
  rotation or revocation records in the device-only iOS Keychain.
- **Camera and photos.** Vesta asks for camera access only to scan a receipt (or
  you can pick a photo you already have). The image is used **only on your
  device** to read the text, and is then discarded — it is not saved by Vesta
  and is **never uploaded**, to your server or anywhere else.
- **Text recognition happens on your iPhone** (Apple's Vision framework). No
  cloud OCR service is used.
- **Card numbers are removed before sending.** Payment-card numbers and
  terminal card data are replaced with `[REDACTED]` on the device.
- **What is sent, and to whom.** Only the receipt text you reviewed (shop, date,
  items, prices, totals, payment method) is sent — **only to your own hestia
  server** — and, if you choose, linked to a transaction your server already
  has. This is household spending data; it is stored and retained by your server
  under its own policy, not by Vesta.

## Removing your data

Signing out clears the sign-in token and ends receipt access for that session.
Device credential records may remain in the Keychain for rotation recovery or
revocation. You can manage paired devices in your hestia server’s device list.
Deleting the app removes its local settings.

## Contact

Questions about this policy: **mateusz@klatt.ie**
