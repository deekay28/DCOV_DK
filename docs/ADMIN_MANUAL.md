# DCOV — Administrator Manual

For whoever runs the server, manages users, maintains the component
database, and answers for the audit trail. If you're using the app to
inspect components, see `USER_MANUAL.md` instead.

**Honest scope note up front:** there is no administration screen in the
Flutter app yet — user management, database import, backups, and the audit
log are all reached through the API directly. That's Swagger UI at
`<server>/api/docs` for anything you want to click through, or `curl`/the
scripts in `scripts/` for anything you want to script or automate. Every
example below is copy-pasteable against a running instance.

---

## 1. Getting a server running

Covered in full in `DEPLOY.md` (Docker Compose / no-Docker quickstart) and
`TERMUX.md` (running on an Android phone). Short version:

```bash
./scripts/quickstart_local.sh          # fastest first look, SQLite, no Docker
./scripts/smoke_test.sh <url> admin '<password>'   # verify it end to end
```

The quickstart prints a generated admin username/password once — write it
down, it's not retrievable afterward (only its bcrypt/pbkdf2 hash is stored).

---

## 2. Roles and permissions

Four roles: **Administrator**, **Database Manager**, **Inspector**,
**Viewer**. Access is deny-by-default — a permission not explicitly granted
to a role is refused, not merely hidden. This table is generated directly
from `backend/app/core/security.py`'s `PERMISSIONS` dict, so it can't drift
from what the code actually enforces:

| Permission | Admin | DB Manager | Inspector | Viewer |
|---|---|---|---|---|
| `component:read` (search/view the catalogue) | ✅ | ✅ | ✅ | ✅ |
| `component:write` (create/edit components) | ✅ | ✅ | | |
| `component:delete` | ✅ | | | |
| `database:import` (stage/commit imports) | ✅ | ✅ | | |
| `database:export` | ✅ | ✅ | | |
| `database:restore` | ✅ | | | |
| `scan:execute` | ✅ | ✅ | ✅ | |
| `inspection:create` | ✅ | | ✅ | |
| `inspection:sign` | ✅ | | ✅ | |
| `inspection:read` | ✅ | ✅ | ✅ | ✅ |
| `report:generate` | ✅ | ✅ | ✅ | ✅ |
| `user:manage` | ✅ | | | |
| `audit:read` | ✅ | | | |

A few deliberate design choices worth knowing:

- **Only an Administrator can delete a component, restore a backup, manage
  users, or read the audit log.** Database Manager is a working role for
  day-to-day catalogue maintenance; it is not a backup Administrator.
- **A Viewer can generate reports and read inspections but cannot scan.**
  If someone should be able to look things up and pull a PDF but never touch
  live data or record an inspection, that's the role.
- **An Administrator cannot demote their own last-admin role** — the API
  rejects it outright, specifically so the system can never be left with
  zero administrators. Have a second admin do it if a role needs to change.

### Creating users

```bash
TOKEN=$(curl -s -X POST $BASE/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"...","device_id":"admin-cli"}' \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")

curl -s -X POST $BASE/api/v1/auth/users \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"username":"jsmith","password":"TempPassw0rd!23","role":"inspector",
       "full_name":"J. Smith","unit":"2 Fd Wksp"}'
```

New users are created with `must_change_password: true` and are forced to
change it via `POST /api/v1/auth/password` on first use. Password policy
(enforced server-side, not just in the UI): 12+ characters, upper, lower,
digit, and symbol.

Deactivate rather than delete a departing user (`PATCH
/api/v1/auth/users/{id}/active?is_active=false`) — this preserves their
attribution on every historical scan and audit entry, which a hard delete
would orphan.

---

## 3. Maintaining the component database

### The import wizard — stage, review, commit, rollback

This is the one workflow worth understanding thoroughly, because it's the
highest-risk surface in the system: a bad import can silently change a
component's origin verdict. The design principle is **nothing is written
until you explicitly commit a reviewed preview.**

```bash
# 1. Stage - parses, maps columns, validates, diffs against the live
#    catalogue. Writes nothing.
curl -s -X POST $BASE/api/v1/database/import/stage \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@updated_components.xlsx" | tee preview.json

# Read preview.json. In particular:
#   rows_new / rows_updated / rows_unchanged / rows_duplicate / rows_invalid
#   warnings          <- READ THIS. Origin-verdict flips are called out here
#                        explicitly, e.g. "3 component(s) change origin
#                        verdict in this import (... NO -> YES). Review each
#                        before committing."
#   sample_updated    <- per-field before/after for the first 10 changed rows
#   validation_errors <- rows that will be skipped and why

# 2. Commit - only after you've actually read the preview.
curl -s -X POST $BASE/api/v1/database/import/commit \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"batch_id":"<from step 1>","apply_new":true,"apply_updates":true,
       "soft_delete_missing":false,"confirm":true}'
```

`soft_delete_missing: true` marks any component absent from the uploaded
file as deleted. Leave it `false` unless the file is genuinely meant to be
the complete, authoritative catalogue — otherwise a partial export/re-import
will silently "delete" everything not included in that partial file.

**Rollback** undoes a committed batch by replaying its revision snapshots in
reverse — rows the batch created are removed, rows it modified are restored
to their pre-import state:

```bash
curl -s -X POST "$BASE/api/v1/database/import/{batch_id}/rollback?reason=bad+manufacturer+column+mapping" \
  -H "Authorization: Bearer $TOKEN"
```

Supported formats: `.xlsx`/`.xlsm`, `.csv`/`.tsv`, `.json`, `.sql` (⚠️ `.sql`
imports only ever read `INSERT` statements out of the file via regex — any
other statement, including `DROP`/`DELETE`/`UPDATE`, is silently ignored
rather than executed; this is deliberate, a `.sql` upload must never be able
to run arbitrary SQL against the database).

Column mapping is automatic (handles headers like `SUB COMPONENT / CHIP NO`,
`COO`, `Mfr` out of the box — see `SYNONYMS` in
`backend/app/services/importer.py`) with a fuzzy fallback for near-misses.
Pass `mapping_json` on the stage call to override it if the automatic
mapping gets something wrong.

### Editing a single component

Every edit requires a `change_reason`, which lands in the audit trail — there
is no anonymous edit path:

```bash
curl -s -X PATCH $BASE/api/v1/components/CHIP-A1B2C3D4 \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"country_of_origin":"China","change_reason":"re-inspected, marking confirms Chinese origin, ref photo IMG_4471"}'
```

Changing `country_of_origin` automatically re-derives `is_chinese`. Full
revision history for any component: `GET
/api/v1/components/{id}/history`.

### Bulk update — deliberately limited

`POST /api/v1/components/bulk-update` accepts a list of component IDs and a
set of changes, but **refuses origin and identity fields**
(`country_of_origin`, `is_chinese`, `component_name`, `part_number`,
`chip_number`, `manufacturer`) with a 422. Those changes are consequential
enough that they must go through the single-component edit path with its own
`change_reason` each — a bulk operation that could silently reclassify fifty
components' origin in one call is exactly the failure mode this system is
built to avoid. Bulk update is for genuinely batch-safe fields: subsystem
tagging, verification source, supplier, and similar.

---

## 4. Reports

```bash
curl -s "$BASE/api/v1/reports/chinese_components?fmt=pdf" \
  -H "Authorization: Bearer $TOKEN" -o report.pdf
```

| Report key | Contents |
|---|---|
| `inspection` | Scan log for a date range or a specific inspection |
| `chinese_components` | Every Chinese-origin record, CRITICAL subsystems first |
| `unknown_origin` | Every record with no established origin — the "needs verification" queue |
| `statistics` | Catalogue and scan-activity counts |
| `monthly` | Scans/findings/distinct inspectors per calendar month |
| `audit` | The audit trail itself, plus a chain-verification result — Administrator only |

`fmt=pdf\|xlsx\|csv`. Every generated report carries a classification banner,
the generating user, the database revision it was drawn from, and a SHA-256
of its own body — printed on the PDF footer, in a trailing row on the
XLSX/CSV — so a physical printout can be tied back to the exact database
state that produced it.

---

## 5. The audit log

Every consequential action — login/logout, failed logins, password changes,
component create/update/delete, bulk updates, imports (staged, committed,
rolled back), inspection sign-off, database export/backup/restore, user
creation and role changes — is written to an **append-only, hash-chained**
log. Each entry's digest covers the previous entry's digest (HMAC-SHA256,
keyed with the server's secret), so altering or deleting a row anywhere in
the chain breaks every digest computed after it.

```bash
curl -s $BASE/api/v1/audit/verify -H "Authorization: Bearer $TOKEN"
# {"intact": true, "entries": 412, "first_broken_sequence": null,
#  "detail": "Audit chain verified"}
```

Run this periodically, and always after anything that makes you suspect the
database file itself was touched outside the application (a restored backup
from an unknown source, a raw SQL edit, etc.). `"intact": false` with a
`first_broken_sequence` means exactly what it says — treat it as a real
incident: preserve the database file as-is and escalate, don't try to "fix"
the chain by editing further.

`GET /api/v1/audit` (Administrator only) for the raw entries, filterable by
`action` and `days`.

---

## 6. Backup and restore

```bash
curl -s -X POST $BASE/api/v1/database/backup -H "Authorization: Bearer $TOKEN"
# -> {"file": "dcov-20260805-140212.sqlite", "bytes": 184320, ...}
```

Uses SQLite's online backup API, so it's safe to run with the server live
and writers active — it's a consistent snapshot, not a raw file copy of a
possibly-mid-write database. Files land in `DCOV_BACKUP_DIR` (default
`var/backups/`, or the `dcov-backups` Docker volume in the compose stack).

```bash
curl -s -X POST "$BASE/api/v1/database/restore?filename=dcov-20260805-140212.sqlite&confirm=true" \
  -H "Authorization: Bearer $TOKEN"
```

Restore takes its own safety backup of the *current* live file first
(`pre-restore-<timestamp>.sqlite`) before overwriting, and requires
`Administrator`. **Restart the service afterward** — other workers have the
old file open and won't see the restored one until they restart.

For PostgreSQL/MySQL deployments (server mode, not the SQLite/Termux path),
`/database/backup` returns a 501 pointing you at `pg_dump`/`mysqldump`
instead of trying to reinvent server-grade backup tooling.

---

## 7. Security posture — what's actually enforced, and what isn't yet

**Enforced today:**
- **TLS**, via Caddy in front of the Docker Compose stack — see
  `DEPLOY.md`'s TLS section. Automatic certificate strategy (public ACME for
  a real domain, internal CA for a LAN-only deployment), and the backend has
  no host-published port to reach any other way, so `DCOV_FORCE_HTTPS=true`
  is unconditionally correct rather than a step to remember.
- JWT access tokens (HS256, 30 min default) + refresh tokens (7 days),
  logout revokes the token's `jti` server-side.
- PIN login (`/auth/login/pin`) is now fully wired end to end, UI included:
  device binding is enforced server-side (each user has a
  `trusted_device_ids` list, populated only by a successful password or
  biometric login; PIN login checks membership before accepting an
  otherwise-correct PIN — this was a real gap I found and fixed, not a
  pre-existing feature), and the Flutter app's **Settings → Security**
  screen enrolls a PIN and the sign-in screen offers it automatically on a
  device that has one. See
  `tests/test_auth_api.py::test_pin_login_is_rejected_from_a_device_that_never_password_logged_in`
  for the server-side proof, and `frontend_flutter/lib/screens/settings_screen.dart`
  / `login_screen.dart` for the client.
- Biometric login (`/auth/login/biometric`) verifies a signature over a
  server-issued nonce against a public key enrolled on the account; the
  biometric template itself never reaches the server. **This one still has
  no on-device enrollment/prompt flow in the Flutter app** — the endpoint is
  implemented and reachable, but nothing in the app calls it yet. PIN is
  the quick-unlock mechanism that's actually usable today; biometric is the
  next piece if you want fingerprint/face instead of a PIN specifically.
- Session tokens (access + refresh) are stored via `flutter_secure_storage`
  (Keystore/Keychain/DPAPI depending on platform), not
  `shared_preferences` — a 7-day refresh token is a real credential. This
  was also a gap I found and fixed while building the PIN feature: the
  session was previously in the same plaintext JSON blob as UI settings
  like theme and server address.
- Deny-by-default RBAC (section 2), account lockout after 5 failed logins
  (15 minutes), password policy enforced server-side, uniform "invalid
  credentials" response that never reveals whether the username or the
  password was wrong.
- Hash-chained audit log (section 5).
- Input validation on every endpoint via Pydantic — control characters and
  angle brackets are rejected in free-text fields at the schema level, before
  any handler code runs.
- Security headers on every response (`X-Content-Type-Options`,
  `X-Frame-Options: DENY`, a real `Content-Security-Policy`, HSTS when
  `DCOV_FORCE_HTTPS=true`), gzip, and a fixed-window rate limiter per client
  IP (120 req/min by default).
- `.sql` import restricted to `INSERT`-only parsing (section 3).

**Not done — say so plainly rather than implying otherwise:**
- **No application-level encryption of the database file at rest**, and
  after actually researching it, that's a deliberate decision rather than
  an oversight left to fill in later — see "Encryption at rest" below for
  why, and what to do instead.
- **Biometric login UI** — the backend endpoint is real and tested; nothing
  in the Flutter app calls it yet.
- **Rate limiting is in-process** (an in-memory dict), so it resets on
  restart and doesn't coordinate across multiple backend workers/replicas.
  Fine for a single-instance field deployment; put a real rate limiter
  (e.g. at the reverse proxy) in front of a multi-replica deployment.

### Encryption at rest

The database file itself (SQLite mode) or the PostgreSQL data directory
(server mode) is not encrypted by this application. That's worth a real
explanation rather than just a bullet point, because the obvious-looking
fix doesn't actually work here.

**Why not SQLCipher.** The natural instinct is "add SQLCipher" - and
`sqlcipher3-binary` used to sit in `requirements.txt` implying exactly
that, without actually being wired to anything. Looking into it properly:
SQLAlchemy's SQLCipher support is a *synchronous* dialect
(`sqlite+pysqlcipher://`). This backend uses `aiosqlite` for the async
engine throughout - `app/core/database.py`, every route handler, the
matching index rebuild, all of it - and `aiosqlite` has no supported way to
swap out its underlying driver for SQLCipher's. Installing
`sqlcipher3-binary` alongside `aiosqlite` would not encrypt anything; the
two don't talk to each other. Rearchitecting the whole backend onto a
synchronous engine just to get SQLCipher is a large, invasive change with
its own performance and concurrency trade-offs, not a config flag - not
something to bolt on without the ability to actually test it, which is
also why it isn't attempted here rather than shipped half-verified.

**What to do instead, in order of how much it actually buys you:**

1. **Full-disk encryption at the OS level.** BitLocker (Windows),
   FileVault (macOS), LUKS (Linux), or the device encryption Android/iOS
   enable by default on any reasonably modern phone. This protects the
   database file *and* everything else on the machine - uploaded images,
   backup files, logs, the lot - for zero application changes, and is
   almost certainly already partially in place on a modern managed device.
   Confirm it's actually turned on; don't assume.
2. **For server-mode deployments (PostgreSQL, section 1 Option B):**
   encrypt the underlying storage volume the database lives on (most cloud
   block storage supports this natively - EBS encryption, Azure Disk
   Encryption, etc. - and it's usually a checkbox, not a project) rather
   than trying to encrypt inside Postgres itself.
3. **If a hard compliance requirement genuinely needs file-level database
   encryption specifically** (not just disk-level), that's a real project:
   moving the backend off `aiosqlite` onto a synchronous engine wrapped in
   `asyncio.to_thread` for the SQLite/SQLCipher case, or accepting
   PostgreSQL-only deployment and using `pgcrypto`/a TDE-capable Postgres
   distribution for server mode. Scope it as its own piece of work with its
   own test plan - don't let it get bolted onto an unrelated change the way
   `sqlcipher3-binary` almost was here.

What *is* already encrypted: the Flutter app's session tokens
(`flutter_secure_storage` - Keystore/Keychain/DPAPI), and all network
traffic to the server once TLS is configured (section on TLS above / see
`DEPLOY.md`). The gap this section is about is specifically the data file
sitting at rest on the server's disk.

---

## 8. Troubleshooting

**"Password [rule] X" on user creation.** The policy (12+ chars, upper,
lower, digit, symbol) is enforced server-side regardless of what any client
UI checks — the error message tells you exactly which rule failed.

**A component's origin verdict looks wrong after an import.** Check
`GET /api/v1/components/{id}/history` for the exact revision that changed
it, who did it, and — if it came from an import — which `batch_id`. Roll
that batch back (section 3) if it was wrong, rather than manually re-editing
the row; rollback restores the exact prior state instead of your best guess
at it.

**`/audit/verify` reports `intact: false`.** See section 5 — treat as an
incident, preserve the file, escalate. Don't attempt to repair the chain.

**Import commit returns 409.** The batch was already committed or rolled
back — batches are single-use. Re-stage the file for a fresh batch if you
need to try again.

**A user is locked out.** `PATCH /api/v1/auth/users/{id}/active?is_active=true`
clears `failed_logins` and any lockout as a side effect — or just wait out
the 15-minute lockout window.

---

## Anti-remark marking check

Remarked ("blacktopped") chips carry a fake part number or country code, so a
text lookup alone trusts exactly the field that was forged. Every scan that
includes OCR text now also runs `backend/app/services/marking.py`, which reads
the *other* lines of the marking and checks they agree:

| Finding | Severity | Effect |
|---|---|---|
| Package marked `CHN` | red | Verdict becomes RED even if the catalogue says the part is non-Chinese - the unit's own marking wins |
| China-only assembly-site code next to a non-China country code | red | RED - classic remark signature |
| China wafer-fab code | yellow | GREEN becomes YELLOW (die made in China, assembled elsewhere - policy call) |
| Non-China country code on a part recorded as Chinese | yellow | RED stays RED; flagged for manufacturer verification |
| Country code missing from an otherwise complete ST marking | yellow | GREEN becomes YELLOW |

The check only ever makes a verdict stricter. A clean marking is never
treated as proof a part is genuine.

**Maintaining the code tables.** `COUNTRY_CODES` and `SITE_CODES` at the top
of `marking.py` are the whole knowledge base. Add a site code only with a
citable source (a manufacturer PCN, datasheet, or a unit verified by the
manufacturer) and record that source in the entry - a guessed mapping becomes
a false accusation in the field. Manufacturers do not publish complete code
lists; for disputed ST parts, raise a ticket with ST (ols.st.com) or the local
ST field engineer, and add any code they confirm.

**Where it runs.** On the server for every scan, and offline on the device
(`frontend_flutter/lib/services/marking.dart`, a line-for-line port with the
same test vectors). On the Verify screen, inspectors can type the package's
other lines into "Other lines on the package"; a chip photo fills it from OCR.
Findings appear in a MARKING CONSISTENCY card under the verdict banner.

**Limits.** Typed or barcode scans usually contain only the part number, so
the check needs the other marking lines (typed or from a photo) to do anything. Photos of printed pages
lose the laser marking detail at print time - use original photos or fresh
photos of the physical chip, without direct flash.
