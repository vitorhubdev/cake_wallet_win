# Cake Wallet PC — Windows and Linux

Community desktop fork of Cake Wallet 6.5.3, focused on Monero and Ethereum.
This is not an official Cake Labs distribution. There are no Android, iOS or
macOS binaries in this fork's PC releases.

## Downloads and installation

Windows x64: use `CakeWalletPC-Windows-x64-6.5.3-<build>-Setup.exe`. The ZIP is
portable application packaging: extract the complete directory and keep the
DLLs and `data` folder alongside `CakeWallet.exe`. User data is not stored beside
the executable. The installer is unsigned; no commercial signing certificate
is included in the repository.

Linux x64: the `.deb` provides the application, launcher, desktop entry and icon.
Install with `sudo apt install ./CakeWalletPC-Linux-x64-6.5.3-<build>.deb`.
The `.tar.gz` contains the same complete application bundle: extract it and run
`./cake-wallet-pc`. The launcher supplies its own library directory; it does not
require Flatpak or FUSE. A desktop Secret Service (for example GNOME Keyring),
GTK3 and the dependencies listed by the DEB are needed. The configured build baseline is
Ubuntu 24.04 x86-64, with glibc >= 2.39 and libstdc++ >= 13.2. Compatible
Ubuntu 24.04 derivatives must provide the same runtime dependencies. Ubuntu
22.04, ARM, musl/Alpine and 32-bit builds are not supported by these binaries.
The portable archive has the same runtime requirements as the DEB; it does
not bundle or replace the system C library.

The previous Linux pipeline mixed a native library built on Ubuntu 24.04 with
an Ubuntu 22.04 application runner. The pinned Monero library requires
GLIBC_2.38 and GLIBCXX_3.4.32, which the older runner cannot satisfy. Native and
application builds now use the same Ubuntu 24.04 baseline. CI verifies the
native manifest, ELF architecture, host runtime, dependency resolution and
actual library loading before compiling the application. The existing XMR
identity, password, storage and desktop lifecycle gates remain mandatory.

Flatpak is technically possible. It is not included in this release because
sandbox permissions, USB hardware-wallet access and persistent keyring behavior
need a separate validation effort; a Flatpak file would not automatically be
more reliable. Snap is not included. The new AppImage package is described separately below.

Verify the exact files against `SHA256SUMS.txt`. Checksums detect accidental
changes, not publisher authenticity. Build metadata records the full source
commit, dependency pins, Flutter version and native-library provenance.

## Existing wallets and data protection

The Windows visible product name changed from Cake Wallet Windows to Cake
Wallet PC, but its installer AppId, storage namespace and compatibility constants
remain unchanged. Updates preserve the existing `CakeWalletWindows` data
location and Windows credential names; do not manually rename this directory.

Linux uses its own `$XDG_CONFIG_HOME/cake_wallet_pc` (or
`$HOME/.config/cake_wallet_pc`) directory and the
`io.github.vitorhubdev.CakeWalletPC` keyring identity. It neither migrates nor
deletes the official Cake Wallet directory or keyring. Keep a verified backup
before importing an existing wallet through the application's supported restore
flow. Do not transplant another distribution's encrypted application directory.

Both launchers lock the selected profile to prevent simultaneous instances
writing to the same wallet data. Uninstallation removes application files, not
wallet data or keyring entries. The CI preservation sentinel is a narrow check,
not proof that every historical encrypted-wallet version migrates correctly.

Windows paths with accented parents use a verified NTFS 8.3 alias for the same
folder without moving keys. Volumes without an available ASCII alias and
non-ASCII wallet filenames are rejected without modifying wallet files. Linux
uses native Unicode paths.

## Changes in this PC version

The pinned upstream tag is `v6.5.3`, commit
`d803aecf9de21461c7459c974ce5e3f2d92b70ed`. Of the 45 commits after v6.5.2,
18 were already ancestors of the previous PC release. This integration adds
only the remaining history, preserving desktop-specific safety changes.
The source candidate is not a tested release until the matching complete CI
succeeds. The detailed review and full commit inventory are in
`docs/audits/CAKE_PC_V653_REVIEW.md`.

- Monero writes are awaited and serialized before backup; failed writes do not
  poison subsequent queue operations. The storage regression now uses the same
  Windows path adapter as production, while retaining its accented-path test.
- Monero synchronization keeps the existing stale-result guards, bounded
  periodic saves and zero-remaining-block/native-confirmation completion gate.
  No validation blocks are skipped, no restore height is raised for speed, and
  no automatic random node switching is enabled. No mainnet speedup is claimed.
- Ethereum transaction IDs hash exactly the signed bytes, including the typed
  envelope already present. Concurrent clicks share one pending broadcast, and
  an already successful pending object is not broadcast again. Failures require
  explicit retry; transactions are never retried automatically.
- EVM history writes snapshot network and data together and serialize disk I/O.
  Late reads and node responses cannot relabel a previous network's history or
  balance as the new network. Nodes must answer with the requested `eth_chainId`.
  Replacing a connection disposes its old HTTP transport.
- Shared desktop navigation, welcome layout and the persistent connection panel
  cover Windows and Linux. The XMR/EVM panel displays a hostname and port only;
  RPC usernames, passwords, path tokens and query keys are not shown.

## Scope and external services

This desktop profile includes the previously supported Bitcoin/EVM/Monero and
other Dart-supported networks. It does not package Wownero, Zcash, Zano, Decred
or a Tor binary. Never interpret an absent backend as a supported wallet.
Production Cake API keys, commercial swap/on-ramp credentials and Etherscan
keys are not included. RPC balance and transaction submission and the external
indexer's historical transaction/token discovery are distinct capabilities;
without the required provider key, indexed EVM history/discovery may be limited.
This limitation is not fixed by pretending an empty API response is a full scan.

CI gates cover real XMR offline testnet creation/storage/reopening, wrong-password
rejection, native DLL/SO loading, real desktop onboarding and keyring operations,
EVM hash/broadcast/session/history regressions, profile locking, packaging and
installation/removal. The tests use disposable unfunded wallets and synthetic
RPC responses. They do not establish mainnet payments, all hardware wallets,
all commercial integrations, long-running live-node behavior, or absence of all
bugs. Test results are authoritative only after the corresponding run succeeds.

## Proteções adicionais de transações EVM

O QR de recebimento acompanha a rede selecionada. Envios com vários destinatários são recusados, em vez de somar os valores para um único endereço. Tokens são resolvidos por contrato e rede, não apenas pelo símbolo; diferenças de casas decimais são rejeitadas. A preparação da assinatura é invalidada quando a carteira muda de rede, conexão ou é fechada. Memos de transferências nativas usam UTF-8 e entram na estimativa de gas; memos arbitrários em transferências ERC20 são recusados para preservar o calldata ABI. Esses cenários são testes obrigatórios do CI, sem fundos reais.

## Desktop Monero error preservation

Windows and Linux both preserve the original XMR opening error and existing files. A low initial height does not trigger automatic cache deletion. Ordinary opening or credential errors do not trigger seed extraction or selection of unrelated wallets. The existing mocked loading-service regression now runs on both desktop platforms; native wallet identity/storage and onboarding checks remain separate mandatory gates. These changes do not certify all rename or manual recovery flows.

## AppImage: Ubuntu, Arch Linux and Fedora

`CakeWalletPC-Linux-x64-6.5.3-<build>.AppImage` is built from the same verified
Linux application bundle as the DEB. It does not use the official release's old
Linux binaries or rename them to 6.5.3. Mark the AppImage executable, then run it.
When FUSE is unavailable, its runtime supports `--appimage-extract-and-run`.

The baseline remains x86-64 glibc >= 2.39 and libstdc++ >= 13.2. GTK3, a working
Secret Service/keyring, graphics libraries and the desktop session are host
prerequisites. Selected ABI-sensitive dependencies such as jsoncpp and SQLite
are bundled with checksums and copyright notices. glibc, libstdc++ and graphics
drivers are not copied into the AppImage. This is not a fully self-contained
replacement for the operating system. Ubuntu 22.04, Alpine/musl and ARM are not
supported by this build.

The mandatory runtime matrix is Ubuntu 24.04, Ubuntu 26.04, Fedora 44, Fedora 45
and a recorded Arch Linux snapshot. Base container images are digest-pinned;
package repositories are updated during image creation and each run records its
runtime. Arch is rolling, so one passing snapshot is not a permanent guarantee.

Runtime tests run as an unprivileged user with no network and no real-wallet
mounts. They verify source identity, private-library checksums, ELF dependencies,
a real disposable Secret Service write/read/delete, a visible X11 window,
Unicode profile paths and rejection of a second instance. CI extracts the
AppImage rather than granting a FUSE device. Desktop FUSE mounting, Wayland,
real GPU drivers, hardware wallets and mainnet payments require separate tests.
These are configured gates, not a claim that an unfinished CI run has passed.

DEB installation/uninstallation remains tested on Ubuntu. Arch and Fedora use
the AppImage; do not install the DEB with distribution-conversion workarounds.
The AppImage preserves the existing profile and keyring namespace, never
redirects HOME, and never migrates or deletes an existing wallet automatically.

## v6.5.3 integration safeguards

IPv6 preference occurs while establishing a socket, before HTTP bytes are sent.
An accepted POST is never replayed because its response failed or timed out.
Direct HTTPS preserves hostname/certificate validation; an explicit pre-existing
Monero certificate-bypass option is not enabled by default. Tor requests keep
their original transport and never acquire a direct fallback.

The optimized seed helper retains the old derivation semantics. Do not add new
Unicode normalization to an existing wallet: it can change its identity. The
52 upstream compatibility vectors are a mandatory regression gate. The updated
BitBox package is pinned at `3d1c607f14c6d5bace2971ec4c10b5201053cc56` and checked
against the actual resolved Pub lockfile, not only a requested dependency.
