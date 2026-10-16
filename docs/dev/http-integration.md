# HTTP Control API — integration notes

Status: implemented.

The HTTP control API drives the Memory Lab (per-process memory dump and quick
strings scan) over Wi-Fi, so nobody has to tap the phone. It is built on
`Network.framework` (`NWListener` / `NWConnection`) exactly like
`ftpserver.swift`: singleton `ObservableObject`, one serial queue, no locks,
`@Published` forwarded to the main queue.

**Read-only by design.** `/regions`, `/dump` and `/strings` only *read* another
process's memory through the kernel r/w primitive. There is no write endpoint
and `mem_write_user` is never called.

## Files

| File | Purpose |
| --- | --- |
| `lara/funcs/httpserver.swift` | The server (`httpserver` singleton, `ObservableObject`), request parsing, job manager. |
| `lara/views/fm/HTTPView.swift` | SwiftUI screen: start/stop, address/port, token, jobs, endpoint list, log. |
| `lara/lara.swift` | Auto-start at launch, when `mgr.dsready` flips, and when the app returns to the foreground. |
| `lara/views/tweaks/TweaksView.swift` | "HTTP Control" link in the System section, next to FTP Server. |

No `.xcodeproj` changes are needed: the project uses a
`PBXFileSystemSynchronizedRootGroup` rooted at `lara/`.

## Endpoints

Every endpoint except the index (`/`) requires the token:

```
Authorization: Bearer <token>
X-Auth: <token>
```

| Method | Path | Params | Action |
| --- | --- | --- | --- |
| `GET` | `/` , `/index` | — | Endpoint list (no token needed). |
| `GET` | `/status` | — | `mem_is_ready()`, `dsready`, `sbxready`, app bundle/version, server port/uptime/request count, current job. Always `200`; `"ok"` is `true` only when kernel r/w is ready. |
| `GET` | `/procs` | — | `mem_procs()`. `503` until ready. |
| `GET` | `/regions` | `pid`, `preset` (0/1/2), `large` (0/1) | `mem_regions(...)`. `503` until ready, `404` with `error` when the walk fails. |
| `POST` | `/dump` | `pid`, `preset`, `large`, `cap` | Async job id; runs `mem_dump_process` on the job queue. `202` + job. |
| `POST` | `/strings` | `pid`, `keyword`, `large`, `cap` | Async job id; runs `mem_quick_strings`. `202` + job. |
| `GET` | `/jobs` | — | Recent jobs (state, progress, result summary). |
| `GET` | `/jobs/<id>` | `tail` (log lines, default all) | One job: state, progress, log ring buffer, result dictionary. |
| `DELETE` | `/jobs/<id>` | — | Cancel a queued/running job (sets the engine's cancel flag). `409` when already finished. |
| `GET` | `/dirs` (alias `/dumps`) | — | Folders in `Documents/lara_dumps`: name, path, size, files, mtime, `in_progress` (`.tmp`), `kind`. |
| `POST` | `/exploit`, `/sandbox` | — | **Opt-in** (`httpremoteinit`): same actions as the Run Exploit / Initialize System buttons. `403` when disabled, `409` when the exploit is already ready, `202` otherwise. Poll `/status` for the result. |

Params may be sent in the query string, as `application/x-www-form-urlencoded`
or as a JSON body. `cap` accepts bytes or a suffix (`64mb`, `512m`, `1g`) and is
clamped to the engine's 512 MB overall cap; `cap=0`/absent selects the default.

Status codes: `400` bad params, `401` missing/bad token, `404` unknown
path/job/process, `405` wrong method, `409` conflict, `411` chunked bodies,
`413` payload too large, `429` too many jobs, `431` header too large, `503`
kernel r/w not ready.

## Jobs, progress and cancel

* Dumps and strings scans run on a dedicated serial queue
  (`lara.httpserver.jobs`). Max 8 queued+running, 24 jobs retained (the oldest
  is cancelled when the list overflows).
* Job state, progress, log ring buffer (500 lines) and results live on the
  server queue; the C engine's `progress`/`logger` blocks hop back onto it.
* `cancelFlag` is a manually allocated `ObjCBool` owned by the job: flipped by
  the server queue on `DELETE /jobs/<id>`, polled by the engine, freed when the
  job finalises. A partial dump is kept and reported (`cancelled: true`).
* The server queue never runs a dump, so `/status` stays responsive during a
  512 MB dump.

## Security model

* **Auth**: `httptoken` preference. On first use it is seeded from the FTP
  password (one secret for both servers), otherwise a 24-character random
  token is generated and persisted. The server refuses to start with an empty
  token; comparisons are length-independent.
* **Wi-Fi only**: `requiredInterfaceType = .wifi`, like the FTP server, so the
  API is not reachable over cellular/VPN interfaces.
* **Plain HTTP**: the token and the dumped memory travel unencrypted over the
  LAN. Treat the network as trusted, or use the FTP server for transport.
* **Bounded requests**: 16 KB headers, 256 KB bodies, 16 concurrent
  connections, 20 s per request. Oversized/malformed requests get an error and
  the connection is closed; the listener survives.
* **Remote init off by default**: `POST /exploit` and `/sandbox` are refused
  unless the `httpremoteinit` toggle is on in the HTTP Control screen.
* **FTP co-start off by default**: `httpstartftp` calls the unchanged
  `ftpserver.start(...)` with the credentials stored in the FTP screen, so a
  launch can bring up both listeners without visiting either screen.
* **Logging**: every request is logged to the view and to `globallogger` with
  an `(http)` prefix, so it lands in `lara.log`. Job log lines are forwarded
  with the same `(mem)` prefix the Memory Lab UI uses.

## Verification smoke test

```sh
TOKEN=<token>
PHONE=<device ip>

curl -H "Authorization: Bearer $TOKEN" http://$PHONE:8383/status
curl -H "Authorization: Bearer $TOKEN" http://$PHONE:8383/procs
curl -H "Authorization: Bearer $TOKEN" "http://$PHONE:8383/regions?pid=1337&preset=0"
curl -X POST -H "Authorization: Bearer $TOKEN" \
     "http://$PHONE:8383/strings?pid=1337&keyword=password&cap=64mb"
curl -H "Authorization: Bearer $TOKEN" http://$PHONE:8383/jobs/<id>?tail=20
curl -X DELETE -H "Authorization: Bearer $TOKEN" http://$PHONE:8383/jobs/<id>
curl -H "Authorization: Bearer $TOKEN" http://$PHONE:8383/dirs
```

## Known limitations

* The app must be running and in the foreground (or kept alive) for the
  listener to answer; iOS suspends backgrounded apps, exactly like the FTP
  server.
* Plainly stated for the seed token: the HTTP token starts as the FTP password.
  Regenerate it in the HTTP screen for a separate secret.
* `/regions` and `/procs` run on the server queue (short kernel walks, same
  class of work as the FTP server's file I/O); a pathological vm_map walk would
  delay other requests, not the dump jobs.
* The API is read-only: it cannot write memory, cannot install, and cannot
  change any device setting.
