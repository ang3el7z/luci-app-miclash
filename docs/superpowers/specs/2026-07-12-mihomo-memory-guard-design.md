# Mihomo Memory Guard Design

## Goal

Add an opt-in MiClash memory guard that detects sustained, abnormal growth of the Mihomo process and recovers it before prolonged memory pressure makes the router unresponsive.

The feature must work across different OpenWrt devices. It must not use a router-model allowlist or a single hard-coded RAM threshold.

## User experience

The operational settings page gets one checkbox:

> Monitor abnormal Mihomo memory usage

The option is disabled by default. Saving it starts or stops the guard immediately and persists `ENABLE_MEMORY_GUARD=true|false` in `/opt/clash/settings`.

The description explains that MiClash learns Mihomo's normal memory use, acts only on sustained abnormal growth combined with system memory pressure, and may restart Mihomo when a reload is insufficient.

The first version keeps threshold selection automatic. It does not expose expert tuning fields.

## Components

### `miclash-memory-guard` monitor

A small POSIX shell daemon runs as a separate procd service. Keeping it separate from the `clash` service lets it supervise and, when necessary, restart that service without restarting itself in the middle of a decision.

The monitor:

- samples the Mihomo process RSS from `/proc/<pid>/status`;
- reads `MemTotal` and `MemAvailable` from `/proc/meminfo`;
- reads `/proc/pressure/memory` when PSI is available, but remains functional without PSI;
- maintains runtime state only in `/tmp/miclash-memory-guard`;
- writes decisions and before/after measurements to syslog;
- never modifies the Mihomo configuration.

The procd init service is enabled and started only while the checkbox is enabled. Disabling the option stops and disables it immediately.

### Service operation helper

Memory recovery actions go through the existing serialized MiClash service-operation path so they cannot overlap a user start/stop/restart, an update, or another guard action.

The helper gains two internal operations:

- soft reload of the current configuration through `PUT /configs`;
- internal Mihomo restart through `POST /restart`.

The existing full `/etc/init.d/clash restart` remains the final fallback.

### Settings UI

The current settings model loads and saves `ENABLE_MEMORY_GUARD`. After saving, the UI synchronizes the guard init service with the setting. Failures are shown to the user and logged. Russian and Chinese translations are included.

## Detection model

### Learning the baseline

After a new Mihomo process appears, the guard allows a 15-minute warm-up. It then collects six RSS samples at one-minute intervals and uses their median as the process baseline.

The baseline never rises during the lifetime of that process, so slow growth cannot be learned as normal. A new process identity resets the baseline.

### Portable system reserve

The low-memory reserve is calculated from the device's reported `MemTotal`:

```text
reserve = clamp(10% of MemTotal, 16 MiB, 64 MiB)
```

This reserve is an early-warning headroom target, not a per-process memory limit.

### Mihomo anomaly

Mihomo is considered abnormally enlarged only when both conditions hold:

```text
current RSS >= 150% of baseline
current RSS - baseline >= 16 MiB
```

The detector therefore tolerates ordinary fluctuations and different configuration sizes.

### Sustained pressure

A recovery cycle starts only when:

- Mihomo meets the anomaly conditions; and
- `MemAvailable` remains below the calculated reserve for five consecutive one-minute samples.

When PSI is present, a non-zero memory `full avg10` value is recorded as evidence that tasks are already stalling. PSI strengthens diagnostics but is not required, because some supported OpenWrt kernels may not expose it.

Short loading spikes, startup, configuration updates, and a busy MiClash service-operation lock do not trigger recovery.

## Recovery ladder

For each action, the guard records Mihomo RSS, `MemAvailable`, and PSI before the action. It waits for MiClash readiness, allows a 60-second settling period, and measures again.

"Memory noticeably decreased" means Mihomo RSS fell by at least both 10% and 8 MiB compared with the measurement immediately before that action.

The approved recovery sequence is:

```text
Abnormal Mihomo growth + sustained memory pressure
                     |
                     v
             Soft config reload
                     |
          Memory noticeably decreased?
              yes -> finish successfully
               no
                     |
                     v
          Internal Mihomo /restart
                     |
              Kernel ready?
        no -> Full clash service restart
       yes
                     |
          Memory noticeably decreased?
              yes -> finish successfully
               no
                     |
                     v
          Full clash service restart
                     |
          Memory noticeably decreased?
              yes -> finish successfully
               no -> warn and enter failure cooldown
```

The full service restart is attempted at most once in a recovery cycle, including the branch where the internal restart fails readiness.

If the internal restart does not become ready, the guard proceeds directly to the full service restart and evaluates memory after that restart.

## Cooldowns and loop prevention

- After a successful recovery, no new recovery cycle may start for six hours.
- After all recovery stages fail, no new recovery cycle may start for 24 hours.
- A failed guard rearms only after the 24-hour cooldown has elapsed and `MemAvailable` has remained above the reserve for at least 30 minutes.
- Manual service operations reset the runtime baseline but do not bypass an active failure cooldown.
- Disabling and re-enabling the feature clears transient monitoring state, but the last failure timestamp is retained in `/tmp` until reboot to prevent checkbox toggling from creating a restart loop.

## Failure handling

- If Mihomo is stopped intentionally, the guard waits and takes no action.
- If the shared service lock is busy, the sample is logged and recovery is deferred.
- If soft reload fails, the guard records the error and advances to internal restart.
- If the Mihomo API is unavailable, internal restart is considered failed and the guard uses the one permitted full service restart.
- If the full restart fails or readiness times out, the guard enters the 24-hour failure cooldown.
- If memory remains high after a clean full restart, the log states that the configuration may inherently require that memory or another system component may be responsible.

The monitor must never reboot the router, kill unrelated processes, change kernel memory settings, clear system caches, or alter swap/zram.

## Observability

Each recovery cycle writes one structured, grep-friendly sequence to syslog containing:

- process PID and learned baseline;
- RSS, `MemAvailable`, calculated reserve, and PSI before each action;
- action result and readiness result;
- measurements after each action;
- selected cooldown and final reason.

A compact state file under `/tmp/miclash-memory-guard/status` exposes the current phase, last action, last result, baseline RSS, current RSS, memory headroom, and cooldown expiry for future UI diagnostics. Displaying this state in LuCI is not required in the first implementation.

## Package lifecycle

The package installs the monitor executable and its init script. Upgrade preserves `/opt/clash/settings`. Post-install synchronizes the init service with the restored setting. Removal stops and disables the guard and deletes its init script and runtime state.

## Verification

Automated checks cover:

- settings load/save and checkbox rendering;
- ACL coverage for every new executable path;
- package installation and removal entries;
- POSIX shell syntax;
- adaptive reserve and anomaly calculations at representative RAM sizes;
- sustained-sample gating;
- baseline reset when the Mihomo PID changes;
- exact recovery ordering and the single-full-restart invariant;
- successful and failed cooldown behavior;
- API failure and missing-PSI fallbacks.

Manual verification on OpenWrt should simulate memory samples without exhausting the router, confirm logs and status output, and verify that soft reload and internal restart do not invoke the full Clash stop/start path.
