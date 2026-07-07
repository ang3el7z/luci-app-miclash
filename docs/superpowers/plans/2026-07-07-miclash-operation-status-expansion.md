# MiClash Operation Status Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand MiClash LuCI operation-status coverage, move Settings to the lower tab group, and add dismissible detailed error UI with Copy error.

**Architecture:** Keep `config.js` as the central LuCI view module and extend its existing `setOperationStatus()`, `setOperationError()`, and `clearOperationStatus()` helpers. Reuse `showModal()`, `withButtons()`, existing service/update polling, and PO locale files instead of introducing a new UI framework or backend protocol.

**Tech Stack:** LuCI JavaScript view modules, CSS, GNU gettext PO files, Node.js static check scripts.

## Global Constraints

- Work on branch `feature-big-info-operation-status`.
- All new user-facing strings must use `_()` and be translated in `ru` and `zh-cn`.
- Do not add Show Logs to the error modal.
- Do not add smart keyword recommendations.
- `Copy error` must copy the full stored error detail.
- The operation-status close button clears only UI status and must not cancel background jobs.
- Use `apply_patch` for manual file edits.

---

### Task 1: Add Static Coverage Check

**Files:**
- Create: `tools/check-operation-status-expansion.mjs`
- Modify later: `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js`
- Modify later: `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css`

**Interfaces:**
- Consumes: source text from `config.js` and `style.css`.
- Produces: a check command that fails until the feature is implemented.

- [ ] **Step 1: Write failing check**

Create `tools/check-operation-status-expansion.mjs` that verifies:

- top control tabs do not include `data-ctrl-tab="settings"`;
- lower config tabs include `data-cfg-tab="settings"`;
- config tab binding contains `settings: '#sbox-pane-settings'`;
- `operationStatus` stores `detail` and `showCloseAt`;
- `setOperationError()` does not use `getOperationRecommendation()`;
- `showOperationErrorDetails()` and `copyOperationErrorDetail()` exist;
- DOM output contains `sbox-operation-status-detail` and `sbox-operation-status-close`;
- CSS styles these two classes;
- key actions call `setOperationStatus()` before their long-running work.

- [ ] **Step 2: Verify RED**

Run:

```bash
/Users/ang3el/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node tools/check-operation-status-expansion.mjs
```

Expected: FAIL because the feature is not implemented.

### Task 2: Implement Status Data Model, DOM, And Styling

**Files:**
- Modify: `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js`
- Modify: `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css`

**Interfaces:**
- Consumes: existing `setOperationStatus(type, message)`, `setOperationError(error)`, `clearOperationStatus()`, `showModal()`, and `updateHeaderAndControlDom()`.
- Produces: extended `setOperationStatus(type, message, options)`, `setOperationError(error, options)`, `showOperationErrorDetails()`, `copyOperationErrorDetail(text)`, and dismissible DOM controls.

- [ ] **Step 1: Update helpers**

Extend status helpers so errors store short `message`, full `detail`, optional `context`, and `showCloseAt`.

- [ ] **Step 2: Update DOM rendering**

Render status text plus detail and close buttons. Detail opens the modal; close clears status only after `Date.now() >= showCloseAt`.

- [ ] **Step 3: Add CSS**

Add compact right-side controls, button hover states, hidden close state, and full-error modal block styling.

- [ ] **Step 4: Verify GREEN for Task 2**

Run the new static check. It may still fail on action coverage until Task 3, but data-model, DOM, and CSS checks should pass.

### Task 3: Add Operation Status To User Actions

**Files:**
- Modify: `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js`
- Modify: `tools/check-service-readiness-update-flow.mjs` if existing assumptions need updating after tab movement.
- Modify: `tools/check-settings-restart-feedback.mjs` if existing assumptions need updating after tab movement.

**Interfaces:**
- Consumes: `setOperationStatus()`, `setOperationSuccess()`, `setOperationError()`, existing service/update polling.
- Produces: progress messages for settings save, proxy mode change, app/kernel updates, subscription update, YAML validation, config save/apply, set-main, rulesets save, and dashboard checks.

- [ ] **Step 1: Instrument actions**

Add concise running/success statuses before and after long-running actions without removing existing notifications.

- [ ] **Step 2: Preserve service phase polling**

Keep Start/Stop/Restart/Reload using `miclash-service` job polling and translated phase labels.

- [ ] **Step 3: Verify GREEN for Task 3**

Run:

```bash
/Users/ang3el/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node tools/check-operation-status-expansion.mjs
/Users/ang3el/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node tools/check-service-readiness-update-flow.mjs
/Users/ang3el/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node tools/check-settings-restart-feedback.mjs
```

Expected: PASS.

### Task 4: Localize And Verify

**Files:**
- Modify: `luci-app-miclash/rootfs/po/ru/miclash.po`
- Modify: `luci-app-miclash/rootfs/po/zh-cn/miclash.po`

**Interfaces:**
- Consumes: msgids extracted by `tools/check-translations.mjs`.
- Produces: complete Russian and Simplified Chinese translations for all new UI strings.

- [ ] **Step 1: Run translation check to collect missing strings**

Run:

```bash
/Users/ang3el/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node tools/check-translations.mjs
```

Expected before PO updates: FAIL with missing msgids.

- [ ] **Step 2: Add translations**

Add each missing msgid to both PO files with non-empty translations and matching placeholders.

- [ ] **Step 3: Run full verification**

Run:

```bash
/Users/ang3el/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node tools/check-operation-status-expansion.mjs
/Users/ang3el/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node tools/check-service-readiness-update-flow.mjs
/Users/ang3el/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node tools/check-settings-restart-feedback.mjs
/Users/ang3el/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node tools/check-release-channel-columns.mjs
/Users/ang3el/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node tools/check-translations.mjs
```

Expected: PASS.
