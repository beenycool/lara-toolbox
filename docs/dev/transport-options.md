# Transport options: FTP vs SSH/SFTP vs HTTP

Status: assessment + recommendation. The FTP hardening it recommends is
implemented in `lara/funcs/ftpserver.swift` (see `ftp-integration.md`); SSH is
deliberately **not** implemented.

## What the transport has to do

The FTP server is the main way a desktop reaches the device: memory dumps,
forensic file extraction and recon all ride on it. From real use, the
transport must:

1. never deliver a short file without saying so;
2. let a client restart a transfer from an arbitrary byte offset;
3. survive a second, stale or retrying client without killing a transfer;
4. report mtimes and sizes without parsing `LIST`;
5. live with the fact that iOS can suspend the app (nothing survives that).

## Option (a): harden FTP — recommended, and done

Small, additive changes on the transport everyone already speaks:

- `REST <offset>` + offset-aware `RETR`/`STOR` (seek/lseek, no truncation),
  `554` when the offset is past EOF;
- `MDTM` (UTC `yyyymmddhhmmss`) and honest `FEAT` (`SIZE MDTM REST STREAM
  UTF8 PASV EPSV`);
- a second connection that may only log in and can take over only when the
  active session is idle — never during a transfer; the third connection is
  refused with `421`; watchdog timeouts for logins, idle sessions and stalled
  transfers;
- no silent truncation: file read errors, short reads and data-connection
  failures end the transfer with `426` plus a byte count, and the data socket
  is half-closed and released after a grace period instead of being cancelled
  immediately after the last send;
- `ABOR`, byte counts in `226`, `TYPE A` refused instead of pretending.

Cost: one file, no dependencies, no protocol changes for clients. This is the
cheapest possible fix for the failure that actually cost data.

Remaining FTP limitations that are not worth fixing: one data session at a
time, passive only, no `MLSD`/`APPE`/`STAT`, and non-UTF-8 file names (a raw
`readdir`-bytes refactor of the whole control protocol).

## Option (b): SSH/SFTP — do not build now

SSH would give `reget`/offset reads, multiplexing, `exec`, and keepalives
from standard clients. The honest assessment:

- The project has no third-party dependencies and links no crypto today.
  CryptoKit (in the SDK) does cover the primitives: X25519 KEX, Ed25519
  signatures, AES-GCM, ChaCha20-Poly1305, SHA-256, HMAC. The crypto is not
  the problem.
- The problem is the protocol. Even a "minimal" SSH needs: version exchange,
  KEXINIT negotiation, `curve25519-sha256` KEX + host-key signature +
  exchange hash, key derivation, the binary packet protocol with sequence
  numbers and AEAD/MAC (length-encryption rules included), `ext-info`/
  `strict-kex` interop with current OpenSSH, USERAUTH (password and/or
  publickey), the connection layer (channel windows, EOF/close, keepalive
  requests), and then SFTP v3 on top (INIT/REALPATH/STAT/OPENDIR/READDIR/
  OPEN/READ/CLOSE/WRITE/REMOVE/MKDIR/RMDIR plus client quirks). That is
  2,500–4,000 lines of security-critical Swift, weeks of work, and a class of
  bug (MAC/length handling, state machine, auth) where "mostly correct"
  means "insecure". It cannot be validated by a quick device test either:
  installs are manual, and a broken transport is worse than no transport.
- Benefit over hardened FTP for *this* workflow: resume already exists after
  `REST`; `exec` is nice but the app is adding an HTTP control API for that;
  background suspension affects SSH identically; the entitlement situation is
  the same (a high-port listener works today, as FTP proves).
- A "minimal SFTP subset over a trivial protocol" is not an option: it would
  need custom clients, and HTTP `Range` gives the same capability with
  standard tools for a fraction of the effort.

Estimate: 3–6 weeks for someone fluent in SSH internals, plus interop testing
against OpenSSH/lftp/FileZilla, plus a security review. Revisit only if
interactive shells or remote execution over the transport become a hard
requirement.

## Option (c): HTTP with `Range` — best medium-term answer for extraction

`Range: bytes=a-b` → `206 Partial Content` with `Content-Range`, `HEAD` for
size and mtime, `curl -C -` resume, parallel downloads with ordinary
connection pooling (the single-client problem disappears), and error
reporting that clients already verify (`Content-Length`, `206` vs `200`).

Cost: a static-file handler is 150–300 lines on `Network.framework`; the
project is already adding an HTTP server for the control API, so the parser
and listener can be shared. Requirements for the file route: basic auth,
`Range`/`If-Range`, correct `Content-Length`/`Content-Range`, percent-decoded
paths validated exactly like `resolve()` (no `..` above `/`), and a directory
listing. No third-party dependency, and it is testable from a shell with
`curl -r`, `curl -C -` and `wget -c`.

## Recommendation

1. **Keep FTP and ship the hardening** (implemented on branch
   `transport-hardening`). It fixes the data-loss failure with a small,
   reviewable diff and breaks nothing that already uses FTP.
2. **Make HTTP-with-`Range` the preferred read/extraction transport** once
   the control-API HTTP server lands: one route, standard clients, resumable
   by construction. FTP stays for writes and for tools that only speak FTP.
3. **Do not build SSH.** It is the only option that would add `exec` and
   multiplexing, but the cost, risk and validation burden are out of
   proportion to the benefit, and the two capabilities that motivated it
   (resume, arbitrary offsets) are already delivered by `REST` and by HTTP
   `Range`.
4. **Deprioritise**: full multi-session FTP (the second-connection handshake
   covers the real failure), active mode, ASCII mode, `MLSD`, non-UTF-8 names.

## If SSH is ever built: the plan

1. Transport layer behind a small protocol (`SSHTransport`): version
   exchange, binary packets, AEAD, strict-kex; unit-test packet round-trips
   and known-answer KDF tests.
2. Algorithms: `curve25519-sha256`, host key `ssh-ed25519`,
   `aes256-gcm@openssh.com` and/or `chacha20-poly1305@openssh.com`, password
   auth first (publickey later). No CBC, no SHA-1.
3. Connection layer: one channel, window updates, `keepalive@openssh.com`,
   graceful close.
4. SFTP v3 subset: REALPATH/STAT/OPENDIR/READDIR/OPEN/READ/WRITE/CLOSE/
   REMOVE/RENAME/MKDIR/RMDIR, mapping to the same `resolve()` +
   `FileManager`/POSIX calls the FTP server uses.
5. Interop matrix: OpenSSH ≥ 9 (sftp, scp -O), lftp, FileZilla, python
   paramiko. Fuzz the packet parser before shipping.
6. Keep it off the default path: a separate listener and a UI toggle, never
   replacing FTP until it has soaked.
