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
  One client at a time. A second client replaces the first (logged) so a
  stale/zombie connection can never lock the server out.
- **Data connections**: passive only. `PASV` opens an ephemeral `NWListener`
  (`on: .any`), replies `227` with the `en0` IPv4 address and the bound port;
  `EPSV` replies `229` with the port only (IPv6 friendly). Each transfer
  consumes the data connection; the next transfer needs a fresh `PASV`/`EPSV`.
  If the client sends a transfer command before the data socket is accepted,
  the server waits up to ~2.5 s for it instead of racing.
- **Threading**: all server state lives on one serial queue
  (`lara.ftpserver`). `@Published` updates are forwarded to the main queue.
  This is why there are no locks anywhere.
- **Commands**: `USER PASS SYST FEAT TYPE PWD CWD CDUP LIST NLST SIZE RETR
  STOR DELE MKD RMD PASV EPSV QUIT` plus `NOOP OPTS CLNT ALLO HELP`,
  `XPWD/XCWD/XMKD/XRMD` aliases, and `PORT/EPRT` rejected with `502`
  (active mode intentionally unsupported). Unknown verbs get `502`.
- **LIST format**: Unix `ls -l` style (`drwxr-xr-x 1 mobile mobile 4096 …`),
  symlinks shown as `l` with `-> target`. `NLST` returns bare names.
- **Logging**: every command is logged (`PASS` is masked) plus connection,
  transfer and error events. Lines go to the view (`logs`) and to
  `globallogger` with an `(ftp)` prefix, so they also land in `lara.log`.

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
- **TYPE A** is accepted but transfers are always binary (no CRLF
  translation). Fine for every common client, noted for completeness.
- **Single client / passive only** by design; multi-session support and active
  mode are future work.
- **Non-UTF-8 file names** are rendered with replacement characters (UTF-8 is
  advertised in `FEAT`).
- **PASV address** uses the preferred `en0` IPv4; on unusual setups (USB
  ethernet, VPN) the advertised address may not be the one the client used.
  `EPSV` avoids this because it never carries an address.
- The server has not been compiled/tested on device in this environment
  (no Xcode available); review on first build is recommended, especially
  the Network.framework state machine.

## Suggested smoke test

1. Run the exploit, then the sandbox escape (`sbxready` true).
2. Open FTP Server, verify the IP shown, start it (default port 2121).
3. Connect from a desktop client in passive mode: list `/`, navigate to
   `/var/mobile`, download and upload a file, create/remove a folder, delete a
   file, check the log lines for each command.
4. Try `CWD ../../../../..` from the client — it must fail with `550`.
5. Stop the server, leave the view with keep-running off, confirm it stops;
   turn keep-running on and confirm it survives leaving the view.
