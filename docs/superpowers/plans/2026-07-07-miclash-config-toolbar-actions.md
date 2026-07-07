# MiClash Config Toolbar Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the subscription URL action, rename config editor buttons, move Rulesets into the editor action row, and update guard protection text.

**Architecture:** Keep the existing LuCI `config.js` view and static verification style. Add a focused check script for the toolbar behavior, reuse existing `saveSubscriptionUrl()`, `setOperationStatus()`, `setOperationSuccess()`, and the current subscription update flow.

**Tech Stack:** LuCI JavaScript view module, CSS, gettext PO files, Node.js static check scripts.

## Global Constraints

- Work on branch `feature-big-info-operation-status`.
- Use TDD: add a failing static check before production changes.
- All new user-facing strings must use `_()` and be translated in `ru` and `zh-cn`.
- The clear URL button is the only control that persists an empty subscription URL.
- `Rulesets` belongs in the editor action row and is pinned to the far right.
- Use `apply_patch` for manual edits.

---

### Task 1: Add Toolbar Static Check

**Files:**
- Create: `tools/check-config-toolbar-actions.mjs`

**Interfaces:**
- Consumes: `config.js`, `style.css`, and locale PO files as text.
- Produces: a check that fails until the toolbar/action UI is implemented.

- [ ] **Step 1: Write failing check**

Verify that the combined `sbox-save-update-sub` button is gone; `sbox-save-sub-url`, `sbox-update-sub`, and `sbox-clear-sub-url` exist; update flow still calls `fetchSubscriptionAsYaml`; save-only block does not call it; clear block saves an empty URL; renamed labels and guard text are localized.

- [ ] **Step 2: Verify RED**

Run:

```bash
/Users/ang3el/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node tools/check-config-toolbar-actions.mjs
```

Expected: FAIL before implementation.

### Task 2: Implement Toolbar And Action Row

**Files:**
- Modify: `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js`
- Modify: `luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css`

**Interfaces:**
- Consumes: existing subscription update code.
- Produces: split save/update/clear handlers and updated action row.

- [ ] **Step 1: Split URL button markup and handlers**

Add separate handlers for save-only, update, and clear.

- [ ] **Step 2: Move Rulesets and rename labels**

Move Rulesets into `.sbox-actions`, pin it right, and rename Validate/Clear labels.

- [ ] **Step 3: Update guard text**

Replace `(beta)` with `(Protection)` in header and settings label.

### Task 3: Localize And Verify

**Files:**
- Modify: `luci-app-miclash/rootfs/po/ru/miclash.po`
- Modify: `luci-app-miclash/rootfs/po/zh-cn/miclash.po`

**Interfaces:**
- Consumes: msgids from `check-translations`.
- Produces: complete translations for all new/changed UI strings.

- [ ] **Step 1: Add translations**

Add missing msgids reported by `tools/check-translations.mjs`.

- [ ] **Step 2: Run checks**

Run:

```bash
/Users/ang3el/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node tools/check-config-toolbar-actions.mjs
/Users/ang3el/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node tools/check-operation-status-expansion.mjs
/Users/ang3el/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node tools/check-service-readiness-update-flow.mjs
/Users/ang3el/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node tools/check-settings-restart-feedback.mjs
/Users/ang3el/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node tools/check-release-channel-columns.mjs
/Users/ang3el/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node tools/check-translations.mjs
git diff --check
```

Expected: PASS.
