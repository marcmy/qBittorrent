# Fork-Specific Instructions

This repository is `marcmy/qBittorrent`, the application half of a coordinated custom qBittorrent + libtorrent project.

Read [FORK.md] before changing BitTorrent behavior. The canonical pairing is `marcmy/qBittorrent:custom/master` with `marcmy/libtorrent:custom/qbittorrent-2.1`; this fork intentionally targets libtorrent 2.1.

Before implementing a feature or fix, determine whether the root behavior belongs to qBittorrent, libtorrent, or both. Implement it at the lowest correct layer rather than masking an engine problem in the application.

For coordinated work, use the same branch slug in both repositories and record the exact counterpart branch or commit. Never silently build or test against an unrelated system or upstream libtorrent package.

Internal branches and same-fork pull requests in `marcmy/qBittorrent` may be created when the repository owner explicitly requests repository changes. Do not open, comment on, or otherwise engage with upstream/community issues or pull requests on the user's behalf.

[FORK.md]: FORK.md

## Project Background

Read [README.md] first if you need a project overview. \
For BitTorrent protocol, consult [Wikipedia article] for a high-level overview and [bittorrent.org] for protocol specification.

[bittorrent.org]: https://www.bittorrent.org/beps/bep_0000.html
[README.md]: README.md
[Wikipedia article]: https://en.wikipedia.org/wiki/BitTorrent

## Communication

Use clear, appropriate English for non-native readers.

## Code Review Guidelines

* Respect project configuration. Avoid reading excluded files unless it is strictly necessary to complete the
  task. Do not review or suggest changes for files/directories excluded in:
  * .editorconfig
  * .gitignore
  * .pre-commit-config.yaml

* Prioritize review metrics in this order:
  * Correctness
    * Logic errors and edge cases
    * Memory leaks and unsafe memory access
    * Security vulnerabilities
    * API misuse
    * Incorrect error handling
  * Performance
  * Coding style
    * Follow the rules defined in [CODING_GUIDELINES.md]
    * Prefer idiomatic expressions
    * Check for English grammar issues

* For each issue found, explain impact clearly and provide concrete, actionable fixes.

[CODING_GUIDELINES.md]: CODING_GUIDELINES.md

## Contribution Policy

This project strongly discourages issue reports and pull requests authored or submitted by AI agents. \
All issue reports and pull requests should be created and submitted by a human contributor. \
Do not create/submit issues, pull requests or any engagement to the community on behalf of the user. \
AI may be used for assistance, but a human must review, take responsibility for, and submit the final changes.

## Document Purpose

This document provides policy and guidelines for AI operations. \
Do not expect this file to contain detailed instructions for compilation and testing.
