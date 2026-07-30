# Privacy and local data

Agent Micro is a local macOS application. It has no telemetry, analytics,
advertising SDK, update service, or project-operated cloud backend.

## Data the app reads

- USB and HID metadata for supported macro pads
- Codex desktop state exposed by the local Codex app-server process
- matching JSONL session records below `~/.codex/sessions` for lifecycle
  reconciliation when an app-server event was missed
- Claude desktop/CLI session metadata from Claude's local support directories
- Claude desktop session records below
  `~/Library/Application Support/Claude/claude-code-sessions`
- `~/.claude/settings.json` only when the user explicitly enables or disables
  the optional Claude status hooks

## Data the app writes

- Profiles and agent assignments under
  `~/Library/Application Support/Agent Micro`
- Preferences in macOS `UserDefaults`
- A local Claude status hook script and status log under the same Application
  Support directory, but only after explicit opt-in
- Claude hook entries in `~/.claude/settings.json` only during that opt-in

Disabling Claude status hooks removes only entries and files created by Agent
Micro.

## Permissions

- **Input Monitoring:** reads the pad's private function-key triggers.
- **Accessibility:** emits configured shortcuts to the selected local app.
- **Login Item:** optional; keeps the menu-bar controller available after login.

All permissions can be revoked in System Settings. Rebuilding an ad-hoc signed
app can cause macOS to request them again.

Agent Micro does not read arbitrary project files below `.codex` or `.claude`.
The paths above are the integration-specific locations used by the current
code.

## Approval actions

Agent Micro observes local Codex approval requests. It never approves or
declines them automatically. A response is sent only when the user explicitly
assigns that action to a hardware control and physically activates it.

The Codex and Claude names and services belong to their respective owners.
Agent Micro is independent and is not endorsed by OpenAI or Anthropic.
