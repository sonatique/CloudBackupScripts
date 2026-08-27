# CloudBackupScript

Daily incremental one-way backup of an **ownCloud** or **Nextcloud** account to a local
folder on Windows. No extra software: PowerShell 5.1 + the server's built-in WebDAV.

Remote → local only. The script never uploads, never modifies anything on the server.

## Files

| File | Purpose |
|---|---|
| `Backup-Cloud.ps1` | The backup itself |
| `Set-Password.ps1` | Stores the app password in `config.json`, DPAPI-encrypted |
| `Install-Schedule.ps1` | Registers/removes the daily scheduled task |
| `config.example.json` | Template configuration |
| `state-<config>.json` | Per-file ETag/fileid/hash index (created on first run — don't edit) |
| `logs\backup-<config>-YYYYMMDD.log` | One log per day |

State, lock and log filenames are derived from the config file's name (`cloud1.json` →
`state-cloud1.json`), so several accounts can share this folder without colliding — see
**Backing up several accounts** below.

## Setup

1. **Create an app password** on the server — Nextcloud: *Settings → Security → Devices &
   sessions → Create new app password*; ownCloud: *Settings → Security → App passwords*.
   An app password can be revoked on its own and works with two-factor auth.

2. **Configure and store the credential:**

```bash
powershell -ExecutionPolicy Bypass -File .\Set-Password.ps1
```

   This copies `config.example.json` to `config.json` (if needed), prompts for the app
   password, encrypts it with DPAPI, and locks the file down to your account.
   Then edit `config.json` — at minimum `ServerUrl`, `Username`, `LocalRoot`.

   Backslashes in JSON must be doubled (`"D:\\Backups\\Nextcloud"`), or just use forward
   slashes (`"D:/Backups/Nextcloud"`).

   **If `LocalRoot` is on a network share, use the UNC path** (`"\\\\server\\share\\owncloud"`),
   not a mapped drive letter like `Y:\owncloud`. Drive mappings belong to the logon session
   that created them, so a scheduled task may not see `Y:` even though it works when you run
   the script by hand. The script refuses to start with an explanation if the drive is missing.

3. **Try it without writing anything:**

```bash
powershell -ExecutionPolicy Bypass -File .\Backup-Cloud.ps1 -DryRun
```

4. **Run the first (full) backup:**

```bash
powershell -ExecutionPolicy Bypass -File .\Backup-Cloud.ps1
```

5. **Schedule it daily:**

```bash
powershell -ExecutionPolicy Bypass -File .\Install-Schedule.ps1 -At 02:30
```

## Backing up several accounts

Copy `config.example.json` to one file per account (`cloud1.json`, `cloud2.json`, …), each
with its own `ServerUrl`, `Username` and a **distinct** `LocalRoot`, and pass `-ConfigPath` to
every command:

```bash
powershell -ExecutionPolicy Bypass -File .\Set-Password.ps1 -ConfigPath .\cloud1.json
```

```bash
powershell -ExecutionPolicy Bypass -File .\Backup-Cloud.ps1 -ConfigPath .\cloud1.json -DryRun
```

```bash
powershell -ExecutionPolicy Bypass -File .\Install-Schedule.ps1 -TaskName CloudBackup-1 -ConfigPath .\cloud1.json -At 02:00
```

Give each task a distinct `-TaskName` and stagger `-At` by 20–30 minutes so several full
walks don't compete for bandwidth. State, locks and logs separate automatically by config
name; nothing else needs to change.

## Should the account be read-only?

The script itself cannot write to the server — every request it sends is `PROPFIND` or `GET`,
never `PUT`/`DELETE`/`MOVE`/`MKCOL`; see **Adversarial review** below. So an ordinary account
with an **app password** (revocable on its own, works with 2FA) is enough for the script's own
behaviour to be safe.

What it does *not* protect against is that credential being used by something else — neither
Nextcloud nor ownCloud lets an app password be scoped read-only. If you want a guarantee that
holds even if the backup machine itself is compromised, create a dedicated account on the
server, share the folders to it **read-only**, and back up that account instead — at the cost
of having to add new top-level folders to that share yourself, since nothing does it for you.

## Layout of the backup folder

A plain mirror — same names, same folders, same modification times. Nothing needs this
script to be read back:

```
LocalRoot\
  Documents\Work\report.docx          the live mirror
  Photos\2025\IMG_0421.jpg
  _versions\20260821-023000\...       previous content of files changed in that run
  _trash\20260824-023000\...          files deleted remotely (only if DeleteRemoved)
```

`_versions` and `_trash` hold dated snapshots that preserve the original hierarchy, so
restoring means copying a folder back. Set `VersionsPath` / `TrashPath` to move them
outside `LocalRoot` — worth doing if your cloud actually contains folders by those names.

## Configuration

| Key | Default | Meaning |
|---|---|---|
| `ServerUrl` | — | e.g. `https://cloud.example.com` (no trailing `/remote.php/...`) |
| `Username` | — | The account whose files are backed up |
| `PasswordEncrypted` | — | Written by `Set-Password.ps1`. `Password` (plaintext) also works but is discouraged |
| `RemoteRoot` | `/` | Back up only this remote subfolder, e.g. `"Documents"` |
| `LocalRoot` | — | Destination folder |
| `Exclude` | `[]` | Wildcard patterns matched against the relative path *and* the file/folder name. A matching folder is not descended into |
| `DetectMoves` | `true` | Rename a moved file locally instead of downloading it again |
| `KeepVersions` | `true` | Before overwriting a changed file, keep its previous content under `_versions\<run>\` |
| `VersionRetentionDays` | `90` | Purge `_versions` snapshots older than this. `0` = keep forever |
| `DeleteRemoved` | `false` | When a tracked file disappears remotely: `false` keeps the local copy, `true` moves it to `_trash\<run>\` |
| `TrashLocalOrphans` | `false` | Also sweep local files that have **no** counterpart on the server into `_trash\<run>\` — see **Orphan sweep** below |
| `MaxOrphanPercent` | `25` | Safety limit: refuse the sweep if more than this share of local files look orphaned. `0` disables the check |
| `TrashRetentionDays` | `30` | Purge `_trash` snapshots older than this. `0` = keep forever |
| `MaxFileSizeMB` | `0` | Skip files bigger than this. `0` = no limit |
| `TimeoutSeconds` | `300` | Per-request timeout |
| `Retries` | `3` | Attempts per request, exponential backoff. 401/403/404 are never retried |
| `LogRetentionDays` | `60` | Delete logs older than this |
| `StatePath`, `LogDirectory` | next to the script, per config | Override if you want them elsewhere |
| `TrashPath`, `VersionsPath` | inside `LocalRoot` | Override to keep them out of the mirror. Refused if set equal to `LocalRoot` itself |
| `AllowInsecureHttp` | `false` | Required to allow a plain `http://` server (credentials in clear text) |

## How "incremental" works

Each run walks the remote tree with `PROPFIND` (depth 1, recursive) and reads every file's
**ETag** — the server's content fingerprint, which changes whenever the file changes. A file
is downloaded only when its ETag differs from `state.json`, or when the local copy is missing
or has the wrong size. Everything else is skipped without transferring a byte, so a daily run
over an unchanged account costs only the directory listings.

- Downloads go to `<file>.part` and are renamed into place only after the byte count matches,
  so an interrupted run never leaves a truncated file that looks complete.
- The local modification time is set from the server's, so timestamps survive.
- If `state.json` is lost or corrupt, the next run falls back to comparing size + modification
  time and re-downloads only what genuinely differs. A missing state can never cause a
  deletion, since deletion requires a *previous* state entry.
- The state file is written to a temp file and renamed over the old one, so a crash mid-write
  leaves either the old state or the new one, never a half-written one.
- A failed file is dropped from the state, so the next run retries it.
- A lock file prevents two runs from overlapping; a second run exits immediately.
- Redirects are never followed: an HTTP redirect would resend the credential to wherever the
  server points, possibly a different host. The run aborts with an error naming the redirect
  target instead, so a redirecting `ServerUrl` gets fixed rather than silently trusted.

## Move detection

A move is otherwise indistinguishable from *delete here, create there* — which would mean
re-downloading the content and leaving a stale duplicate behind. So the walk is now split
into three phases: enumerate the whole tree, work out what moved, then transfer. A file that
vanished from one path and appeared at another is renamed locally; nothing is downloaded.

Matching is tried in this order:

1. **`oc:fileid`** — ownCloud/Nextcloud's stable per-file identifier, which survives a move.
   This is what the official desktop client uses, and it is authoritative.
2. **ETag + size** — for plain WebDAV servers whose ETags survive a rename.
3. **Name + size + modification time** — heuristic fallback for everything else.

A file that was moved *and* edited in the same day is matched by fileid, renamed locally, and
then only its new content is fetched — so the version history stays attached to the file
rather than restarting at the new path.

Note that Nextcloud regenerates a file's ETag on a move, so after a rename the script
deliberately falls back to size + modification time to decide whether the content also
changed. Set `DetectMoves: false` to disable all of this and treat every move as a
delete + create.

## Versions

With `KeepVersions` on, a file that is about to be overwritten is first moved to
`_versions\<run timestamp>\<original path>`. So a bad edit synced from the cloud is
recoverable: find the run's folder and copy the file back.

The old copy is retired only *after* the replacement has been downloaded and its size
verified, so a failed download can never lose the existing local copy.

This costs disk: a file edited daily keeps one copy per changed day until
`VersionRetentionDays` expires. Two consequences worth knowing:

- Versions are kept for *changed* files, not for deleted ones — deletions go to `_trash`.
- If `state.json` is lost *and* the local timestamps have been mangled, the run re-downloads
  everything and versions out the whole tree, briefly doubling disk usage. It self-corrects
  once retention expires.

## Orphan sweep

By default the script only manages files it knows about: a file sitting in `LocalRoot` that
has no counterpart on the server is left alone forever. Set `TrashLocalOrphans: true` to make
`LocalRoot` a true mirror — those files are moved to `_trash\<run timestamp>\`, the same
destination, dated folder and `TrashRetentionDays` retention used for files deleted remotely.

This is the one feature that touches files the script never downloaded, so it refuses to run
unless it is confident:

- **Incomplete listing aborts the sweep.** If any remote folder failed to list this run, a
  local file with no counterpart is indistinguishable from one whose folder was never read.
  The sweep is skipped entirely with a warning — a transient server error can never empty
  your mirror.
- **An empty server aborts the sweep.** If the account reports no files at all, the whole
  local tree is not treated as orphaned.
- **`MaxOrphanPercent` (default 25%).** If more than a quarter of local files look orphaned,
  the sweep is refused and logged as an error. A wrong `RemoteRoot` makes nearly everything
  look orphaned; this turns that mistake into a message instead of a mass move.
- **Excluded files and folders are never swept.** The local walk applies the same `Exclude`
  patterns as the remote one, and does not descend into an excluded folder — so files you
  deliberately keep out of the backup are also kept out of the sweep.
- **`_trash` and `_versions` are never swept**, so trashed files are not re-trashed.
- Path comparison is case-insensitive, matching Windows, so a case difference between server
  and disk never makes a good file look orphaned.
- `-DryRun` reports `would move orphan to trash: ...` and moves nothing.

Run it with `-DryRun` first the very first time you enable it, and read the count.

## Integrity: hashing and `-Verify`

Every file this script downloads has its SHA-256 recorded in `state.json`. Running with
`-Verify` rehashes every local file that would otherwise be skipped as unchanged and compares
it against that recorded hash — catching local corruption (bit-rot, a bad disk, a faulty copy)
that size and modification time alone cannot see, since neither changes when bytes silently
flip. A mismatch forces a re-download; the corrupt copy is versioned out like any other
overwrite. `-Verify` reads the whole local tree, so it costs real time and disk I/O — run it
weekly or monthly, not on the daily schedule.

**This only protects files the script itself has downloaded.** A hash proves a file has not
changed *since the hash was recorded* — it cannot retroactively validate content the script
never fetched. Two places this matters:

- **Enrollment** — the first run over a file that already exists locally, matched by size and
  modification time because there is no prior state entry. If the server publishes an
  `oc:checksums` property for that file (Nextcloud computes SHA1/MD5 at upload time, but only
  for files uploaded through a client that provided one — not guaranteed for every file), the
  local content is cross-checked against it *before* being trusted, and a mismatch forces a
  download instead. This also seeds the SHA-256 baseline for future `-Verify` runs. Without a
  server checksum, the file is trusted by size + mtime alone, exactly as before hashing existed,
  and is reported by `-Verify` as unverifiable rather than silently passed.
- **Pre-seeded data that was already corrupted before the first run** — if you point `LocalRoot`
  at an existing copy and some of those files are already wrong, and no server checksum is
  available to catch it at enrollment, `-Verify` cannot detect it either: there is no baseline
  to compare against, because the corruption predates any hash this script ever computed. The
  only way to close that gap is to force a fresh download — delete the file (or the suspect
  subtree) and rerun.

### Closing the gap on a pre-existing library

If you pointed `LocalRoot` at files that were already on disk, and your server publishes no
checksums, those files are enrolled with no baseline and `-Verify` can only report them as
unverifiable — permanently, since the checksum cross-check only runs at enrollment.

Run once with `-BaselineLocal` to adopt what is on disk as the reference:

```bash
powershell -ExecutionPolicy Bypass -File .\Backup-Cloud.ps1 -ConfigPath .\cloud1.json -BaselineLocal
```

Be clear about what this buys: it does **not** confirm those files are correct — anything
already damaged is enshrined as "correct". What it does is make every *future* `-Verify` run
meaningful, so damage from that point on is detected. It costs one full read of the files that
lack a baseline, and only needs doing once.

For files you need actually validated rather than merely baselined, the only option is to
force a fresh download (delete the local copy, or the whole subtree, and re-run).

Note that Nextcloud has no `occ` command to compute checksums for existing files — the
`oc:checksums` property is populated by the desktop client at upload time, so files that
arrived via the web UI, the skeleton, or `files:scan` never have one.

The end-of-run log line reports enrollment and verification outcomes when any occurred:

```
integrity: 3 enrolled+checksum-confirmed, 401 enrolled with no server checksum to check, 1 corruption caught (re-downloaded), 0 had no baseline to verify against
```

## Command line

```bash
powershell -ExecutionPolicy Bypass -File .\Backup-Cloud.ps1 -DryRun -Verbose
```

| Switch | Effect |
|---|---|
| `-DryRun` | Report what would change; write nothing |
| `-Full` | Ignore `state.json` and re-verify every file against the local copy (size + mtime, not content) |
| `-Verify` | Rehash every unchanged local file and compare against its recorded SHA-256; re-download on mismatch. Expensive — see **Integrity** above |
| `-BaselineLocal` | Adopt the current local content as the SHA-256 baseline for files that have none, so future `-Verify` runs can check them. Does **not** validate that content — run once, see **Integrity** |
| `-Quiet` | Console shows only warnings and errors (used by the scheduled task) |
| `-Verbose` | Include DEBUG lines (excluded files, kept files, versions, state details) |
| `-ConfigPath` | Use a different config — handy for backing up several accounts |

The log file always contains the DEBUG lines regardless of `-Verbose` / `-Quiet`; those
switches only affect what is echoed to the console.

Exit codes: `0` success, `1` finished with per-file failures, `2` aborted (auth, network,
configuration). On abort the state file is left untouched.

## Scheduled task notes

`Install-Schedule.ps1` registers the task with **Interactive** logon type, so no Windows
password has to be stored. The consequence is that it runs only while you are logged on;
`StartWhenAvailable` makes it catch up on a missed daily run as soon as you log in.

If you need it to run while logged off, open Task Scheduler, edit `CloudBackup` → General →
*Run whether user is logged on or not*, and supply your Windows password. Note that DPAPI
decryption of `PasswordEncrypted` still requires the task to run as the same user account
that ran `Set-Password.ps1`.

```bash
powershell -Command "Start-ScheduledTask -TaskName CloudBackup"
```

```bash
powershell -Command "Get-ScheduledTaskInfo -TaskName CloudBackup"
```

Remove it with:

```bash
powershell -ExecutionPolicy Bypass -File .\Install-Schedule.ps1 -Uninstall
```

## Adversarial review

Every network call goes through one function, which only ever sends `PROPFIND` (listing) or
`GET` (reading content) — no `PUT`/`DELETE`/`MOVE`/`MKCOL`/`PROPPATCH`/`POST` appears anywhere
in the script, so it is structurally incapable of writing to the server. `Set-Password.ps1` and
`Install-Schedule.ps1` make no network calls at all.

A deliberate pass over the diff, run before this feature shipped, also found and fixed:

- Href unescaping happened after the remote-path prefix check, which could let a hostile or
  compromised server smuggle `..` segments past it. Dot segments are now rejected outright, and
  the prefix match is exact (`.../files/sylvain` no longer matches `.../files/sylvain2`).
- A subdirectory whose listing failed mid-run dropped all of its previously known files from
  the new state — with `DeleteRemoved: true`, one transient server error could have trashed an
  entire folder's local copies. Old entries under an unlistable directory are now carried
  forward instead.
- Redirects were followed by default, which would resend the `Authorization` header to wherever
  the server pointed. Now refused (see above).

## Limitations

- Files whose names contain characters Windows forbids (`: * ? " < > |`) are skipped with a
  warning — Nextcloud permits them, NTFS does not.
- Paths longer than 240 characters use the `\\?\` prefix; on Windows 10/11 also enable
  `LongPathsEnabled` if you hit errors on very deep trees.
- The whole remote file list is held in memory during a run (a few tens of MB at 100k files) —
  the price of detecting moves before transferring anything.
- Local corruption already present before this script's first download of a file is not
  detectable unless the server publishes a checksum for it — see **Integrity** above.
- Server-side versions, trash bin, shares, calendars and contacts are not backed up — this
  covers the files tree only.
- Backing up a *shared* folder works as long as it appears in the user's file tree.

## Tested

Against a mock WebDAV server reproducing Nextcloud's behaviour (including ETag regeneration on
move and `oc:checksums`): first full run, no-op rerun, changed file, remote deletion,
exclusions, folders with spaces, `RemoteRoot` subfolder, `-DryRun`, `-Full`, corrupt state,
deleted state, deleted state with `DeleteRemoved: true` (no mass deletion), pure move, move +
edit, move on a server with no `oc:fileid`, versioning of an in-place edit, enrollment confirmed
against a server checksum, enrollment corruption caught via server checksum, enrollment
corruption *not* caught with no server checksum available (the documented limitation, verified
to behave exactly as documented), `-Verify` catching and fixing corruption in a script-downloaded
file, and `-Verify` correctly reporting (not silently passing) a file with no baseline hash.

Also smoke-tested end to end against a real Nextcloud instance: auth, a 28-file/22 MB initial
backup, a 0-download idempotent rerun, and `-Verify` catching and fixing a locally-corrupted
file against the live server.
