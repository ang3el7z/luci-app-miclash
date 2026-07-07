# MiClash Operation Status Expansion Design

Date: 2026-07-07
Branch: feature-big-info-operation-status

## Summary

Expand the LuCI `operation-status` area so users can see what MiClash is doing during long or failure-prone operations. The visible status line should stay concise, while full error details move behind an explicit details button with a copy action.

The UI should also move Settings out of the top Control tab group. The top section remains a single selected Control tab, and the lower section becomes `Config | Settings | Logs`.

## Tab Layout

Current layout:

- Top tab group: `Control | Settings`
- Lower tab group: `Config | Logs`

New layout:

- Top tab group: `Control`
- Lower tab group: `Config | Settings | Logs`

The existing settings pane and settings save behavior should be reused. Only the tab group wiring and pane placement changes.

## Operation Status Coverage

Use `operation-status` for actions where the user benefits from immediate progress feedback:

- Start, Stop, Restart, and Reload service operations.
- Proxy mode changes that save settings and restart the service.
- Settings save operations, including the service restart step.
- MiClash package install, update, and reinstall operations.
- Mihomo kernel install, update, and reinstall operations.
- Subscription URL save and config update.
- YAML validation.
- Config save and apply/reload.
- Set selected config as Main.
- Ruleset save and IP-CIDR list save.
- Dashboard readiness checks.

Operations that are instantaneous and local-only can keep existing notifications without a status entry.

## Status Behavior

The status line should support these types:

- `running`: active progress, spinner indicator.
- `success`: short completion message when useful.
- `error`: concise error summary.

Successful service/update jobs may still clear the status after completion when the existing flow already does that. Other newly instrumented actions may show a brief success message before clearing, so users can see that the operation completed.

Errors should remain visible until dismissed by the user or replaced by a new operation.

## Service Step Reporting

Start, Stop, Restart, and Reload should continue using the existing `/opt/clash/bin/miclash-service` job polling. The UI should prefer translated phase labels from `formatMiClashServiceStatus()` so users see stages such as:

- Starting service job...
- Starting Clash service...
- Checking Clash service process...
- Checking Clash API...
- Checking DNS...
- Checking TUN interface...
- Checking routing policy...
- Checking forwarding rules...
- Checking stopped state...

If the backend status includes a phase not known by the UI, show the backend message as the fallback.

## Error Details

Do not append recommendations to the visible error line.

Visible line:

```text
Error: <short error summary>
```

The full error text should be stored with the operation status. It should include all lines from the caught error message when available, not only the first line.

For error statuses, the right side of the status line should show:

- A details button (`i` or `?`) immediately.
- A close button (`x`) after a one second delay.

The details button opens a modal with:

- Full error text in a separate block.
- A short static "You can" list:
  - Try again.
  - Check `config.yaml` if the operation was related to config.
  - Check internet access on the router if the operation was related to download or update.
  - Reinstall MiClash if nothing else helped.
- A `Copy error` button.
- A normal close button.

There should be no `Show Logs` action in this modal.

## Copy Error

`Copy error` should copy the full stored error text to the clipboard. If the modern Clipboard API is unavailable, it may fall back to a temporary textarea and `document.execCommand('copy')`.

After copying, the modal button text can briefly change to `Copied`.

## Close Button

The close button should not appear immediately on error. It should become visible after one second so accidental dismissals are less likely.

Clicking close should clear only the current visible operation status. It should not cancel background jobs.

## Implementation Notes

`appState.operationStatus` should become structured enough to store:

- `type`
- `message`
- `detail`
- `context`
- `dismissible`
- `showCloseAt`

The existing `setOperationStatus()`, `clearOperationStatus()`, and `setOperationError()` helpers should remain the central API so callers do not manipulate DOM directly.

Use existing UI helpers where possible:

- `showModal()` for details.
- `withButtons()` for button busy states.
- Existing service and update polling functions for backend job progress.

## Testing And Verification

Add or update static check scripts to verify:

- Settings tab moved to the lower config tab group.
- The top control tab group only exposes Control.
- `operationStatus` stores full error detail.
- `setOperationError()` no longer appends recommendation text into the visible line.
- Error details UI exposes a copy action.
- Close button behavior is represented in DOM/CSS.
- Key user actions set operation status before long-running work.

Run the existing check scripts after implementation:

- `tools/check-service-readiness-update-flow.mjs`
- `tools/check-settings-restart-feedback.mjs`
- `tools/check-release-channel-columns.mjs`
- `tools/check-translations.mjs`

## Out Of Scope

- Automatic diagnosis by keyword.
- Smart reinstall recommendations.
- A `Show Logs` button in the error modal.
- Cancelling background jobs from the operation status close button.
- Reworking the underlying shell service job architecture.
