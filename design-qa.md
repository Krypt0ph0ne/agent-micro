# Design QA

- Source visual truth: `DesignQA/source-settings.jpg` and `CodexPad.dc.html` from the supplied `Codex Pad UI Verbesserung.zip`
- Implementation screenshots:
  - `DesignQA/implementation-compact.jpg`
  - `DesignQA/implementation-action-picker.jpg`
  - `DesignQA/implementation-all-lights.jpg`
  - `DesignQA/implementation-reactions.jpg`
  - `DesignQA/implementation-settings.jpg`
- Side-by-side settings comparison: `DesignQA/settings-comparison.jpg`
- Viewport: native 440 pt-wide main window with content-driven height; verified at approximately 550 pt compact height and larger feature-dependent heights
- State: dark appearance; shortcut assignment, expanded action picker, agent/thread picker, all-key lighting, reaction editor, and Settings inspected

## Full-view comparison evidence

The supplied target and implementation retain the same compact information architecture: profile/status strip, 3 × 2 pad plus encoder, Belegung/Licht switch, contextual editor, and persistent validation/upload footer. The new implementation now covers the target's expandable action search, live thread/subagent results, all-key LED scope, per-key scope, and event-reaction editor.

The window no longer reserves a fixed 720 pt content height. `implementation-compact.jpg` shows the reduced shortcut state without empty panel space. The agent list, action picker, all-key lighting, and reaction states grow the native window only by their bounded content regions.

The supplied settings target and native settings implementation remain compared together in `DesignQA/settings-comparison.jpg`. Native SwiftUI Form sections, segmented pickers, buttons, toggle, menus, sliders, color wells, toolbar, alerts, and Settings scene intentionally replace HTML control imitations.

## Focused-region comparison evidence

The feature screenshots isolate each important content region at native scale. Separate crops were not needed because labels, status colors, search fields, action rows, scope segments, reaction colors, and effect menus are readable in the full captures.

## Findings

- No actionable P0, P1, or P2 mismatch remains.
- P3: Thread previews are intentionally single-line and truncated in the compact window. The complete thread remains accessible in Codex through “Öffnen”.
- P3: Native grouped controls use slightly more vertical space than the HTML imitation. Bounded scroll regions keep the resulting window within a practical desktop size.

Required fidelity surfaces:

- Fonts and typography: native San Francisco hierarchy, optical weights, truncation, and monospaced shortcut styling are consistent and readable.
- Spacing and layout rhythm: 440 pt width, stable pad geometry, bounded picker lists, and content-driven window height match the intended compact rhythm without persistent blank space.
- Colors and visual tokens: system dark materials, accent blue, semantic green/orange/red/purple status colors, configurable color wells, and adaptive text preserve the target palette.
- Image quality and asset fidelity: no raster artwork is required by the target; SF Symbols and native controls replace HTML-drawn icons as requested.
- Copy and content: target labels, all-key scope, seven reaction types, action search, thread/subagent search, profile status, and upload actions are present.

## Comparison history

1. Earlier initial pass found a P1 overlap in the Licht state when the fixed window compressed the pad. A stable pad region fixed the overlap.
2. The fixed 720 pt window then left unnecessary space in short assignment states. The fixed height and infinity-sized editor panels were removed; `windowResizability(.contentSize)` now follows the view's intrinsic height.
3. Post-fix evidence: `implementation-compact.jpg` is substantially shorter, while `implementation-action-picker.jpg` and `implementation-reactions.jpg` expand without clipping the footer or pad.

## Implementation checklist

- [x] Content-driven native window height
- [x] Searchable action picker with shortcuts, categories, selection state, and quick actions
- [x] Searchable thread and subagent list with preview, type, live status, open, remove, refresh, and reconnect actions
- [x] All-key and per-key RGB scope
- [x] Apply all, apply one, and all-off hardware paths
- [x] Persisted reaction colors and effects for Diktat, Senden, running, completed, attention, failed, and interrupted
- [x] Functional one-shot reaction restore
- [x] Backward-compatible profile decoding
- [x] Compact, expanded, light, reaction, and settings states inspected
- [x] Swift test suite passed

## Follow-up polish

- Physical LED timing still requires the optional hardware test pass on a Mac with the CodexPad connected.

final result: passed
