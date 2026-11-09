# Cake Wallet PC 6.5.3 — Monero diagnostics and stability

## Original blocker

Run 42539165849 failed during dependency resolution, before the final desktop
builds: unused `solana`/`borsh_annotation` Git dependencies pointed to an
inaccessible espresso-cash repository. The narrow fix follows upstream commit
`15d591f1bccdd3f61823570aece3379234e218bf` (#3814). The real `cw_solana` backend,
which uses `on_chain`, is retained. No replacement signing library was introduced.
The repair is commit `373e326c74d74ad4e7b90fda135a72fde6fffe58`.

## Problems corrected and diagnostic behavior

- The previous proxy reachability check could mark the remote Monero node alive
  merely because a local SOCKS port accepted TCP. The new observation performs
  get_info through the configured proxy, keeping node DNS resolution at the proxy.
- Explicit node testing shows RPC response latency in ms, median of up to three
  exchanges, sample spread, reported height, readiness and distinct failures.
  It is not ICMP ping, throughput, independent consensus or proof of node honesty.
- HTTP 401/403/429/5xx, DNS, TLS, refused TCP, redirects, invalid metadata and
  timeout are distinct. HTTP 403 and TCP refusal do not prove an IP ban.
  No external-IP lookup, IP rotation, certificate bypass or automatic node switch
  was added. Retry-After is respected by the visible test; selection is manual.
- Request/response size, lifetime and concurrency are bounded. Requests use
  explicit Content-Length: live-node verification exposed that monerod rejected
  the default chunked requests, despite the generic HTTP fixtures accepting them.
  A regression now requires fixed-length requests. Compressed/unexpected and
  oversized responses are not silently accepted.
- Cancellation of a TLS upgrade inside SOCKS needed additional handling: closing
  the pre-upgrade Dart Socket alone left an unfinished TLS transport alive.
  A verified loopback socket pair retains an owned transport endpoint until TLS
  completes. It accepts one exact local peer and never binds off-loopback.
  Tests verify that normal, rejected, stalled SOCKS and stalled TLS connections
  close. No wallet synchronization isolate is killed or modified by a probe.
- Node tests are limited to three concurrent workers. Repeated clicks, changed
  wallet/network/node credentials, page disposal and late responses cannot
  overwrite the current measurement. Logs do not stringify node passwords.
- Monero scan speed uses actual scanned-height deltas and a monotonic clock.
  History is bounded, reset for node/wallet changes, rollback and long resume
  gaps, and displays zero/no-progress instead of retaining an obsolete positive
  rate. Blocks/s is not Mbps. No restore height or verification step is skipped.
- Repeated unavailable native height observations invalidate a stale synced
  state. The existing native-synchronized plus zero-blocks completion gate is
  retained; a metadata ping never marks a wallet synced.
- Monero prepared submissions share one attempt and retain success. No automatic
  resubmission was introduced. UR and regular submission cannot race the same
  prepared object. Native commit's boolean result is now checked, the isolate
  captures only a pointer address, and the existing write/close queue also gates
  native commits. Delayed saves/refreshes do not assume another wallet's identity.
- Trezor failure handling previously read an UnsignedTransaction error using a
  PendingTransaction pointer. The error is now read from the Wallet API that
  actually failed. This fixes the pointer type mismatch; no physical device was
  tested, and no fee, recipient, amount or signing algorithm was changed.

## Evidence actually executed locally

`CAKE_PC_XMR_STABILITY_TESTS.json` records 66 health/metrics/submission checks,
35 proxy/TLS/authentication checks and the 27 existing stability checks. These
use synthetic loopback services and disposable state, with zero payments.
Dart analysis passed for the dependency-isolated diagnostic modules and tests.
Real Flutter adapter/widget tests were added to both desktop build scripts;
those are not claimed passed until the corresponding CI run succeeds.

A separate explicit read-only observation queried the seven TLS clearnet nodes
already listed by the project, from the user's Ubuntu NAS VM. At the recorded
instant, MoneroDevs #1 reported 134 ms, Seth 142 ms, MoneroDevs #3 215 ms and
Cake 516 ms median RPC latency. Feather refused TCP, MoneroDevs #2 timed out,
and StormyCloud failed TLS validation. No node was removed, no certificate
validation was disabled, and no permanent ranking or user-IP ban was inferred
from this one observation. These measurements are not desktop/ISP benchmarks.

Primary protocol reference: https://docs.getmonero.org/rpc-library/monerod-rpc/
Native API pin: `MrCyjaneK/monero_c@33671871de3d51696b66ffb3bd94f744e26974f6`.

## Release conditions

The full Windows/Linux compilation, native XMR creation/reopening/storage,
keyring/onboarding and installer tests remain mandatory. The AppImage must
also pass the configured Ubuntu, Arch and Fedora runtime matrix. New mainnet
payments, hardware wallets, all proxies and permanent server availability are
not established by these checks. A green packaging job alone is not proof of
all wallet behavior. No new binary is declared available by this source report.
