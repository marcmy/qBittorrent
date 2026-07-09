# marcmy/qBittorrent fork

This fork is the application half of a coordinated qBittorrent + libtorrent project.

## Canonical pairing

- qBittorrent repository: `marcmy/qBittorrent`
- qBittorrent baseline: `custom/master`
- libtorrent repository: `marcmy/libtorrent`
- libtorrent baseline: `custom/qbittorrent-2.1`
- Required libtorrent series: 2.1

`upstream/master` is the pristine mirror of `qbittorrent/qBittorrent:master`; `custom/master` is the active qBittorrent fork branch. In libtorrent, `upstream/RC_2_1` is the pristine upstream mirror and `custom/qbittorrent-2.1` is the active engine branch. The former qBittorrent `master` and libtorrent `RC_2_1` custom lanes are retained as rollback points. Libtorrent `RC_2_0` and `master` retain their upstream roles for compatibility work and future-development comparison.

## Platform scope

Windows x64 is the active build and daily-driver target. Ubuntu and macOS do not run automatically. Future Linux work should target Arch Linux rather than using Ubuntu as this fork's intended distribution baseline.

## Security scanning policy

CodeQL scans first-party qBittorrent code with the `security-and-quality` query suite. Exact vendored snapshots are excluded in `.github/codeql/codeql-config.yml` so third-party findings do not obscure actionable fork-owned results. Those exclusions must remain narrow and should be removed when the corresponding library is replaced or updated.

Zizmor SARIF uploads omit note-severity style findings. Warning and error findings remain visible and must be fixed or explicitly justified.

The upstream Coverity workflow was removed because this personal fork does not own or use qBittorrent upstream's Coverity credentials.

## Ownership rule

Implement a change at the lowest layer that actually owns the behavior.

### qBittorrent owns

- GUI and WebUI behavior
- preferences and persistence
- categories, tags, RSS, search and presentation
- deciding when to invoke libtorrent APIs
- translating alerts and engine state into user-visible behavior
- Windows integration, packaging and application policy

### libtorrent owns

- peer, tracker, DHT, LSD and PEX behavior
- protocol correctness
- TCP, uTP, WebRTC and encryption internals
- NAT-PMP and UPnP engine behavior
- piece selection, hashing, disk I/O and cache internals
- torrent state machines, scheduling, rate limiting and resume-data semantics

### Both repositories are required when

libtorrent needs a new setting, command, status field or alert and qBittorrent must expose, persist or present it.

Use the same branch slug in both repositories for coordinated work. Cross-reference the exact counterpart branch or commit in commit messages and pull-request descriptions.

## Build provenance

A distributable custom build should make the following recoverable:

- qBittorrent repository and commit
- libtorrent repository, branch and commit
- compiler, Qt and Boost versions
- build configuration and enabled libtorrent features

Never assume that a binary reporting only `libtorrent 2.1.0.0` uniquely identifies the engine source.

## Working method

1. Reproduce and trace the behavior across the qBittorrent/libtorrent boundary.
2. Decide which repository owns the root cause.
3. Create a focused branch from `custom/master` here and, when needed, a matching branch from `custom/qbittorrent-2.1` in libtorrent.
4. Keep application work and engine work in separate commits and separate same-fork pull requests.
5. Build qBittorrent against the exact custom libtorrent commit being tested.
6. Preserve a known-good build before replacing the daily-driver installation.
