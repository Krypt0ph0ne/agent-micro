# Security policy

## Supported versions

The public Developer Preview is source-only and has no supported stable binary
release. Security fixes target the current `main` branch. Preview tags, when
present, are historical source snapshots rather than a promise of binary or
long-term support.

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose local agent
sessions, approval actions, filesystem data, keyboard input, or USB device
state.

Use GitHub private vulnerability reporting:

<https://github.com/Krypt0ph0ne/agent-micro/security/advisories/new>

Include the affected version, macOS version, reproduction steps, expected
impact, and whether physical access or a connected macro pad is required. You
should receive an acknowledgement within seven days.

Agent Micro never needs API tokens or account credentials in a report. Remove
session IDs, profile contents, usernames, home-directory paths, and USB dumps
that identify a personal device.
