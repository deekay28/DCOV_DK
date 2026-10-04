# DCOV offline mode (no server, no network)

Available from app version **1.2.0**. Everything below works in airplane mode.

## First-time setup on a phone (administrator)

1. Open DCOV → person icon (top right) → **SIGN IN ON THIS DEVICE (NO SERVER)**.
2. The first time, this screen is **SET UP THIS DEVICE**: choose an administrator
   username and a password (8+ characters) → **CREATE ADMINISTRATOR**.
3. Person icon → **USERS ON THIS DEVICE** → **ADD USER** for each inspector
   (username, temporary password, role). They choose their own password at
   their first sign-in.

## Load your component catalogue from a file

1. Copy the worksheet to the phone (USB, email attachment saved to Downloads,
   Drive download…). Excel **.xlsx**, **.csv** or **.json**. Old **.xls**: open
   in Excel and *Save As* .xlsx first.
2. Signed in as administrator or database manager: person icon → **IMPORT
   CATALOGUE FROM FILE** (also in Settings) → **CHOOSE FILE**.
3. Read the preview:
   - *Columns used* — how your headers were understood. Unrecognised columns are
     kept in the remarks.
   - *Rejected rows* — rows with no name, or no part/chip number, or a bad
     confidence value.
   - **Origin changes (red)** — a component whose Chinese / non-Chinese status
     differs from the current catalogue. Check each against its source document
     and tick the box; the import is blocked until you do.
4. Choose **MERGE** (add + update, keep the rest) or **REPLACE** (catalogue
   becomes exactly the file) → **APPLY IMPORT**.
5. Made a mistake? **UNDO LAST IMPORT** restores the previous catalogue.

The imported catalogue stays on the phone across restarts. Settings shows
"Catalogue source: Imported on this device (file name)".

Recognised header names include: Component Name / Name of Item / Nomenclature,
Part No / Model, Chip No / Sub Component / Marking, Mfr / Make / OEM,
COO / Country of Origin, Chinese (Yes/No), Subsystem, Criticality, Bar Code,
QR Code, Remarks, Verified By, Evidence / Verification Source, Confidence.

## Verifying

Unchanged: type, scan a barcode, or photograph the marking (on-device OCR).
Results show **LOCAL ONLY — NOT RECORDED CENTRALLY** and the signed-in
device user.

## Limits of this version (coming in 1.3.0 / 1.4.0)

- Inspections, analytics and PDF/Excel reports still need the server
  (1.3.0 moves them onto the phone).
- No export of findings to a file yet, and no merge of several phones'
  results (1.4.0).
- Device accounts protect against someone picking up an unattended phone.
  They are not a replacement for server accounts and do not protect against
  someone with full (root) control of the phone.
- If the only administrator's password is lost, the device accounts can be
  cleared only by clearing the app's data, which also deletes local scans.
- When the phone later signs in to a server, the server's catalogue replaces
  the device import (the app tells you).
