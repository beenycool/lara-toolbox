# FTP Server — integration notes

Status: implemented (was the README "Coming Soon" item).

The FTP server gives full-disk read/write access over Wi-Fi directly from the
phone. It is built only on `Network.framework` (`NWListener` / `NWConnection`)
plus `FileManager`/POSIX — no third-party dependencies.

## Files

| File | Purpose |
| --- | --- |
| `lara/funcs/ftpserver.swift` | The server itself (`ftpserver` singleton, `ObservableObject`) and the `getifaddrs` address helpers (`ftpipv4address()`, `ftpipv6address()`). |
| `lara/views/fm/FTPView.swift` | SwiftUI screen: start/stop, address/port, credentials, log, keep-running toggle. |
| `docs/dev/ftp-integration.md` | This document. |

No `.xcodeproj` changes are needed: the project uses a
`PBXFileSystemSynchronizedRootGroup` rooted at `lara/`, so new files inside
`lara/funcs/` and `lara/views/fm/` are picked up automatically by Xcode.

## Integration

Recommended entry point: the **System** section of `TweaksView.swift`, next to
the other full-disk tools (the whole `List` is already gated on
`mgr.dsready`, so only the sandbox-escape gate has to be added):

```swift
NavigationLink("FTP Server", destination: FTPView())
    .disabled(!mgr.sbxready)
```

Alternative (file-manager family): present it as a sheet from
`SantanderView`/`santanderdirview`, e.g. a toolbar button with
`@State private var showftp = false` and `.sheet(isPresented: $showftp) { FTPView() }`.
`FTPView` embeds its own `NavigationStack`, so it works both as a pushed
destination and as a sheet.

## Architecture

- **Control connection**: `NWListener` on the user port (default `2121`).
  One *active* session plus one *second* connection that only gets the login
  handshake. The second client can take over only after it has authenticated
  **and** the active session is neither transferring nor recently active
  (`takeoveridle`, 30 s). A third connection is refused with `421`. This
  means a stale client retrying in a loop with old credentials can never
  evict a working session, and no client can ever interrupt a transfer.
- **Watchdog**: a 15 s timer on the same queue reaps unauthenticated
  connections after 60 s, authenticated sessions after 10 min of no commands,
  and aborts a transfer that makes no progress for 120 s with `426` (so a
  stalled peer can no longer hold the server). `FTPView` has a "Disconnect
  Client" button for an immediate kick.
- **Data connections**: passive only. `PASV` opens an ephemeral `NWListener`
  (`on: .any`), replies `227` with the `en0` IPv4 address and the bound port;
  `EPSV` replies `229` with the port only (IPv6 friendly). Each transfer
  consumes the data connection; the next transfer needs a fresh `PASV`/`EPSV`.
  If the client sends a transfer command before the data socket is accepted,
  the server waits up to ~2.5 s. A transfer that is superseded by another
  command on the same connection is answered `451` instead of hijacking the
  newer data socket.
- **Threading**: all server state lives on one serial queue
  (`lara.ftpserver`). `@Published` updates are forwarded to the main queue.
  This is why there are no locks anywhere.
- **Resumable transfers**: `REST <offset>` stores an offset that the next
  `RETR` (seek) or `STOR` (lseek, no `O_TRUNC`) applies; the offset is
  consumed by that transfer. `RETR` with an offset past EOF is refused with
  `554`. A transfer is only reported `226` when the whole requested range was
  sent; short reads, local I/O errors and a shrunken file are reported as
  `426` with a byte count so the client knows to resume. The data connection
  is half-closed (`.finalMessage`) and only released after a 0.5 s grace
  period, so queued bytes are never discarded by an immediate `cancel()`.
  `ABOR` cancels a transfer in progress (`426` + `226`).
- **Commands**: `USER PASS SYST FEAT TYPE PWD CWD CDUP LIST NLST SIZE MDTM
  REST RETR STOR DELE MKD RMD ABOR PASV EPSV QUIT` plus `NOOP OPTS CLNT ALLO
  HELP`, `XPWD/XCWD/XMKD/XRMD` aliases, and `PORT/EPRT` rejected with `502`
  (active mode intentionally unsupported). Unknown verbs get `502`.
  `FEAT` advertises `SIZE MDTM REST STREAM UTF8 PASV EPSV`.
- **LIST format**: Unix `ls -l` style (`drwxr-xr-x 1 mobile mobile 4096 …`),
  symlinks shown as `l` with `-> target`. `NLST` returns bare names.
- **Logging**: every command is logged (`PASS` is masked) plus connection,
  transfer and error events. Lines go to the view (`logs`) and to
  `globallogger` with an `(ftp)` prefix, so they also land in `lara.log`.
  Transfer completions include the byte count (`226 Transfer complete (N
  bytes).`), which makes silent truncation visible in the log.

## Security model

- **Auth**: one username + one generated random password (12 chars, ambiguous
  characters removed). `USER`/`PASS` are required; the login check refuses to
  start with an empty password unless anonymous login is enabled. Anonymous
  mode accepts `anonymous`/`ftp` with any password.
- **Path traversal**: every path argument is resolved against the session
  `cwd`, normalized component-by-component, and any `..` that would climb above
  `/` is rejected (`550`). All returned paths are absolute and rooted at `/`.
  Embedded NUL bytes are rejected as well.
- **Full disk**: the file system root is `/`, so access is only meaningful
  after the sandbox escape. The UI gates the start toggle on `mgr.sbxready`
  and labels this explicitly; the server itself does not enforce it, since it
  is a plain component.
- **Deletion/writes** call `santanderfs.clearImmutableIfPossible(atPath:)`
  first, matching the file manager's behaviour on iOS 16.
- **Auto-stop**: `FTPView.onDisappear` stops the server unless
  "Keep running in background" is enabled. Because `ftpserver.shared` is a
  singleton, the server survives the view when that toggle is on.

## Known limitations / uncertainties

- **`com.apple.security.network.server`**: the entitlements in `Config/lara.entitlements`
  currently only declare `com.apple.security.network.client`. Binding a local
  listener normally works for iOS apps on high ports, and the app also has
  `no-sandbox`/`platform-application`, but if a build reports `EPERM`/bind
  failures the fix is adding the `network.server` entitlement. Left untouched
  on purpose (no entitlement files were modified).
- **Background execution**: `Info.plist` only declares the `audio` background
  mode. "Keep running in background" keeps the server object alive and running
  while the app process stays scheduled (the existing keepalive audio trick
  helps); iOS may still suspend the app, and no FTP traffic can flow while
  suspended.
- **TYPE A is rejected** with `504` (binary only). Transfers have always been
  binary; the old code accepted `TYPE A` and then sent raw bytes anyway, which
  silently corrupted anything a client expected to be CRLF-translated. Every
  common client (curl, FileZilla, lftp, `ftplib.retrbinary`) uses `TYPE I`.
- **Non-UTF-8 file names** are rendered with replacement characters (UTF-8 is
  advertised in `FEAT`). This is unchanged: `FileManager` hands the server
  Swift strings, so a name that is not valid UTF-8 cannot be round-tripped.
  Fixing it needs raw `readdir` bytes end-to-end plus a raw-bytes control
  protocol, which is out of scope here.
- **One data session**: PASV/EPSV listeners and the in-flight transfer are
  per-server, not per-connection, so only the active session can transfer.
  The second connection exists to authenticate and take over, not to run a
  parallel session. A full multi-session refactor (per-session data state) is
  future work.
- **No active mode** (`PORT`/`EPRT` rejected with `502`) and no `APPE`, `MLSD`
  or `STAT`.
- **PASV address** uses the preferred `en0` IPv4; on unusual setups (USB
  ethernet, VPN) the advertised address may not be the one the client used.
  `EPSV` avoids this because it never carries an address.
- **Absolute paths**: every path is rooted at `/`, so `CWD /var/db` works
  directly once the sandbox escape is applied — there is no percent-encoding
  layer on the server. `%2F` in a URL is decoded by *curl*, not by the
  server; sending `CWD /%2Fvar` reaches the literal path `/%2Fvar` and fails
  with `550`. `..` above `/` is rejected.
- The server has not been compiled/tested on device in this environment
  (no Xcode available); review on first build is recommended, especially
  the Network.framework state machine.

## Suggested smoke test

1. Run the exploit, then the sandbox escape (`sbxready` true).
2. Open FTP Server, verify the IP shown, start it (default port 2121).
3. Connect from a desktop client in passive mode: list `/`, navigate to
   `/var/mobile`, download and upload a file, create/remove a folder, delete a
   file, check the log lines for each command.
4. `curl -r 1024-2047 ftp://…/path` (or `curl -C -` on a partial download)
   must return exactly bytes 1024–2047, and the log must show
   `150 … (restarting at 1024)` and `226 Transfer complete (1024 bytes)`.
5. `curl -I` equivalent: `MDTM` on a file returns `213 yyyymmddhhmmss` in UTC.
6. Connect a second client while a download is running: it must be able to
   log in but be refused with `421` (and the log must say the active session
   is busy). Connect a second client with wrong credentials: the active
   session must stay connected and the `530` must appear in the log.
7. `CWD ../../../../..` from the client — it must fail with `550`.
8. Stop the server, leave the view with keep-running off, confirm it stops;
   turn keep-running on and confirm it survives leaving the view.
