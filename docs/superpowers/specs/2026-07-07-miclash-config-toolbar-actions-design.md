# MiClash Config Toolbar Actions Design

Date: 2026-07-07
Branch: feature-big-info-operation-status

## Summary

Split the combined subscription URL action into separate controls and tighten the config editor action labels/layout. This is a UI clarity pass on top of the expanded operation-status work.

## Subscription URL Toolbar

Replace `Save URL / Update Config` with three controls:

- `Save`: saves the current non-empty subscription URL for the selected config profile and does not download or apply config.
- `Update`: saves the current non-empty subscription URL and then runs the existing subscription download/update/apply flow.
- `x`: clears the subscription URL input and immediately saves an empty subscription URL for the selected config profile.

The existing non-empty URL validation applies to `Save` and `Update`. The clear button is the only path that persists an empty URL.

Operation status messages should match the action:

- Save: `Saving subscription URL...`
- Update: `Saving subscription URL...`, then `Downloading subscription...`, then any reload status.
- Clear: `Clearing subscription URL...`

## Editor Action Row

Rename labels:

- `Validate YAML` -> `Check`
- `Clear Editor` -> `Clear`

Move `Rulesets` into the same editor action row as `Check`, `Save`, `Clear`, and `Set as Main`. `Rulesets` should be pinned to the far right edge of the row. `Set as Main` stays at the end of the normal action flow before the right-pinned `Rulesets` button.

## Guard Text

Rename `Client devices only through MiClash (beta)` to `Client devices only through MiClash (Protection)` everywhere it appears in the UI, including the header guard title and settings checkbox label.

## Localization

All changed and new user-facing strings must use `_()` and be translated in the shipped locale files:

- Russian
- Simplified Chinese

Run the translation check after implementation.

## Testing And Verification

Add or update static checks to verify:

- The combined `sbox-save-update-sub` button no longer exists.
- Separate save, update, and clear URL controls exist.
- Save URL does not call the subscription download flow.
- Update URL still calls the subscription download flow.
- Clear URL persists an empty URL and has its own operation status.
- `Check`, `Clear`, and the protection guard text are localized.
- `Rulesets` is in the editor action row and remains right-pinned.

Run the existing verification scripts after implementation.
