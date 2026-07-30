# Security policy

## Supported versions

Security fixes are provided for the latest tagged release and the current
`main` branch.

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
