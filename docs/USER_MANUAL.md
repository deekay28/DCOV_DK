# DCOV — User Manual

For an inspector using the DCOV app in the field. Covers the Flutter app
(Android/iOS/Windows/macOS/Linux/web) and the offline web demo, which behave
almost identically — where they differ, it's called out.

If you're setting up the server, managing users, or importing data, this
isn't your document — see `ADMIN_MANUAL.md`.

---

## The one thing to understand before anything else

**A green result means "no Chinese-origin record matched this marking." It
does not mean the part is verified non-Chinese.**

Three things can put a Chinese part behind a green banner: the marking can be
counterfeited or re-marked, the part can simply be absent from the database
(which correctly shows grey, not green — but a *near-miss* marking can
fuzzy-match the wrong record), and the database is only as current as its
last import. Treat every result as screening support for your own judgement,
not a substitute for it. The **Limits** tab in the app says this again, along
with the specific counts for the database you're currently running against.

---

## Getting in

Open the app. You'll land on the **sign-in screen**.

- **Username / password** — sign in against a live DCOV server. Ask your
  database manager for credentials; the first login will require you to set
  a new password.
- **Change server address** — tap this if your unit runs its own server
  (a field laptop, a Termux-hosted instance on a phone, a fixed installation)
  instead of the default. Get the address from whoever administers that
  server — see `DEPLOY.md`/`TERMUX.md` for how it's hosted.
- **Continue offline** — skip sign-in entirely. The app ships with a
  203-component catalogue bundled at install time and the full matching
  engine runs locally with no network at all. This is the normal way to use
  the app in the field with no signal; sign in later, when you have
  connectivity, to sync a newer catalogue and have your scans recorded on
  the server.

The top bar always shows two status pills: **ONLINE/OFFLINE** (network
reachability) and **DB LIVE/DB BUNDLED** (whether you're matching against a
server-synced catalogue or the one that shipped with the app). Both matter
independently — you can be online with a bundled (stale) database if the
sync hasn't run yet, or offline with a live one if you synced earlier and
then lost signal.

### Quick unlock with a PIN

Typing a full password every time you open the app gets old fast. Once
you've signed in with your password, go to **Settings** (gear icon, top
bar) → **Security** → set up a 4-12 digit PIN. Next time you open the app,
you'll see a PIN field instead of the full sign-in form.

The PIN only ever works on **this specific device** — the server tracks
which devices you've actually signed into with your password, and refuses
PIN login from any device that isn't on that list, even with the correct
PIN. Setting a PIN on your phone does nothing for a laptop, and vice versa.
Signing out clears the PIN from that device; you'll need to set it up again
next time you sign in there.

---

## Settings

Gear icon, top bar — reachable whether or not you're signed in.

- **Connection** — current online/offline and catalogue-source status, and
  the server address (same field as "Change server address" on the sign-in
  screen; either place edits the same setting).
- **Security** — PIN setup/removal, as above.
- **Appearance** — dark/light theme (same toggle as the sun/moon icon next
  to it in the top bar — two ways to reach one setting).
- **Device** — this device's ID (used to identify it to the server for PIN
  trust and sync) and how many scans are still waiting to sync.
- **Session** — who you're signed in as, and sign-out (only shown when
  signed in).

---

## The five tabs

### Verify

The main screen, and the one you'll use for nearly every inspection.

1. **Type the marking**, or use one of the two capture buttons:
   - **Scan code** — opens the camera for barcode/QR. Works the moment a
     recognizable code is in frame; no button press needed once it locks on.
   - **Photograph chip** — captures or picks a photo of the component
     package. Online, this uploads to the server's OCR pipeline and reads
     candidate markings automatically. Offline, there's no on-device OCR
     model in this build — the photo is kept for your record, and you type
     the marking you can read off it yourself. Either way, the reading you
     end up with goes through the identical matching cascade as if you'd
     typed it from the start; nothing about OCR gets special treatment.
2. **Read the verdict banner:**

   | Banner | Meaning | What to do |
   |---|---|---|
   | 🔴 **RED — Chinese component detected** | A database record with Chinese origin matched this marking | Do not fit. Record the finding. If the subsystem is CRITICAL, this is an escalation — the banner will say so explicitly |
   | 🟢 **GREEN — Non-Chinese component** | A record matched with an established non-Chinese origin | Not a guarantee, see above — proceed per your unit's procedure |
   | 🟡 **YELLOW — Origin not found** | The part is in the database, but nobody has established where it's from | Needs verification. Flag it for your database manager rather than treating it as either a pass or a fail |
   | ⚪ **GREY — Component not found** | Nothing in the database matches this marking at all | Capture images, note where it was fitted, and it'll be queued automatically for review |

3. **Read the cascade trace underneath the banner.** This is deliberate —
   the app shows you *how* it reached the verdict, not just the verdict
   itself: which of the six matching layers fired (exact code, normalized
   text, a stripped lot/date code, an OCR-glyph correction, a partial-marking
   match, or a fuzzy match), and the confidence score. If a match came from a
   fuzzy or corrected layer rather than an exact one, look at the trace
   before trusting it blindly — the marking-as-read vs. marking-as-searched
   readout shows you exactly what changed.
4. If the match is ambiguous (two records genuinely conflict, or two fuzzy
   candidates are too close to call), the app will say so and list the
   candidates rather than picking one for you. This is intentional — a
   forced guess here is worse than an honest "I don't know."

### Catalogue

Search and filter the full component database — by marking, manufacturer,
subsystem, criticality, or country of origin. Useful for looking something
up before you're holding the physical part, or for browsing what's known
about a subsystem. Tapping a row runs it through Verify exactly as if you'd
typed or scanned it.

### History

Every scan you've run on this device, most recent first — marking, verdict,
which matching layer resolved it, and when. This is a local, on-device
convenience log, not the authoritative record: the server keeps its own
audited copy of every scan performed by a signed-in user (see
`ADMIN_MANUAL.md`). If you scanned while offline, those entries carry a
pending-sync marker until the app reconnects and pushes them.

### Overview

Dashboard: total components, the Chinese/non-Chinese/unknown split, how many
Chinese-origin parts also sit in a CRITICAL subsystem, and a bar chart of
Chinese-origin findings by subsystem. Reflects whichever catalogue you're
currently matching against (bundled or server-synced) — the DB LIVE/BUNDLED
pill in the header tells you which.

### Limits

The honest read on what this tool can and can't tell you — expanded version
of the warning at the top of this document, plus the acceptance-policy
matrix (which subsystems are CRITICAL, and why) and where the seed data
came from.

---

## Working offline

The app is offline-first by design, not offline-as-a-fallback:

- The bundled catalogue and the full matching engine work with the radio off.
  There is no reduced/lite mode when offline — verification quality is
  identical.
- Scans performed offline are queued on-device and pushed to the server
  automatically the next time the app has both connectivity and a live
  session. You don't need to do anything to trigger this.
- If you're relying on offline mode for an extended period, be aware the
  bundled catalogue is fixed at whatever it was when the app was installed
  or last synced — it does not update itself without a connection. Sync
  whenever you get signal, even briefly, if the mission allows it.

---

## Troubleshooting

**"Could not reach `<address>`. Check the address, or work offline for now."**
The server address is wrong, the server isn't running, or you're not on the
same network as it. Confirm the address with your administrator (particularly
note: `localhost`/`127.0.0.1` only works if the server is running on *this
same device* — see `DEPLOY.md`'s networking notes if you're unsure). You can
still tap "Continue offline" and work from the bundled catalogue.

**Camera won't open for barcode/QR scanning.**
The app needs camera permission — check your OS settings if you previously
denied it. On desktop/web, confirm no other application is holding the
camera.

**A scan result disagrees with what I expected.**
Check the cascade trace first — it will tell you exactly which layer matched
and why. If it still looks wrong, that's worth reporting: the matching logic
is deliberately identical across the app, the web demo, and the server (they're
tested against the same vector set), so a genuine disagreement between them is
a real bug, not a fluke.

**I scanned something offline and don't see it reflected on another device.**
Offline scans sync on next connection, but only to *your* session on *your*
device — check History for a pending-sync indicator, and confirm you're
signed in (not in "Continue offline" mode) once you're back online.
