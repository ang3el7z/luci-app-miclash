# MiClash Update and Subscription Reliability Design

## Goal

Make MiClash package, Mihomo kernel, and subscription operations reliable and independent from the client forwarding guard and Clash service state, while preserving the intentional destructive semantics of a hard MiClash reinstall.

## Confirmed Requirements

- The client forwarding guard may block forwarded client traffic but must never block downloads initiated by the router itself.
- A hard MiClash reinstall removes the installed Mihomo kernel and leaves Clash stopped. The user installs the kernel and starts Clash explicitly afterward.
- Installing or updating the MiClash package must not automatically start Clash or the subscription auto-update daemon.
- Installing or updating the Mihomo kernel must work while Clash is stopped and regardless of the guard state.
- Updating a subscription requires an installed Mihomo kernel because the downloaded configuration must be validated.
- Updating a subscription does not require a running Clash service. If Clash is stopped, the configuration is validated and saved without starting or reloading the service.
- Starting Clash without an installed kernel must fail before changing service enable state and tell the user to install the Mihomo kernel first.
- Manual and automatic subscription updates must support the same Base64, URI-list, Remnawave `/mihomo`, raw GitHub CDN, device-header, proxy-mode transformation, and YAML validation behavior.
- An auto-update interval of three hours limits attempts to one attempt per three-hour interval, including after a failed attempt.
- User-facing success copy must not expose the internal `(Remnawave /mihomo fallback)` detail.
- Router verification must not stop the currently running Clash process. Package lifecycle behavior will be tested in an isolated shell harness rather than by reinstalling the live router package.

## Confirmed Root Causes

### Divergent subscription implementations

The manual action calls `/opt/clash/bin/miclash-subscription`, which recognizes the primary Base64 response and obtains valid YAML from the Remnawave `/mihomo` path. The auto-update daemon performs its own direct `curl`, transforms the Base64 text as if it were YAML, and fails Mihomo validation.

The configured provider returns `Profile-Update-Interval: 3`, a Base64 primary response, and a valid `/mihomo` YAML response. This reproduces the repeated auto-update validation failure without changing the live configuration.

### Retry scheduling based only on success

`miclash-autoupdate` polls every 60 seconds and treats a missing `last_success` file as immediately due. A validation failure never creates `last_success`, so the daemon retries every minute despite `AUTO_UPDATE_INTERVAL_HOURS=3`.

### Tagged installer download hides its failure

The LuCI update path intentionally downloads the tagged `install-miclash.sh` so first installation and LuCI updates use one canonical installer implementation. The defect is not that this installer is shared: its download is a single fragile request, and `miclash-update` replaces the installer's specific error with `failed to run MiClash installer`.

### Package lifecycle conflicts

The package-specific `prerm-pkg` stops Clash and performs cleanup before OpenWrt `default_prerm` stops every packaged init script again. During a hard reinstall, `postrm` removes the Mihomo kernel as intended. After installation, package-specific `postinst-pkg` runs before OpenWrt `default_postinst`, which then starts the packaged init scripts even when the package-specific script disabled Clash.

### Intermittent GitHub connectivity

The router has produced repeated 15-second connection timeouts against both raw GitHub content and release assets. The same URLs also succeed in under one second at other times. Guard-on and guard-off probes have equivalent results, and the Clash PID remains unchanged, so the client forwarding guard is not the cause. The download layer needs bounded retries, endpoint fallback where available, and preservation of the actual curl error.

## Architecture

### 1. One tagged installer for every application install

`install-miclash.sh` remains the canonical implementation for both first-time shell installation and LuCI package updates. `miclash-update app` will:

1. Ensure the curl stack is usable.
2. Download `install-miclash.sh` from the requested GitHub tag through the bounded downloader.
3. Validate that the downloaded installer is non-empty and passes `sh -n` (or `ash -n` when available).
4. Launch it in non-interactive `app` mode with the requested tag, mode, operation token, and status path.
5. Preserve the installer's specific status and stderr instead of replacing them with a generic wrapper error.

The tagged installer resolves the correct `.ipk` or `.apk`, downloads it with the same bounded retry policy, creates lifecycle intent markers, installs it, and leaves Clash and `miclash-autoupdate` stopped. A hard reinstall removes the Mihomo kernel; an ordinary update preserves it.

### 2. Consistent download policy

`miclash-update` uses the policy for the tagged installer and Mihomo archives; `install-miclash.sh` independently implements the same policy for release metadata, MiClash packages, and first-install Mihomo downloads. The downloaders will:

- use curl in direct router context without changing guard rules;
- use explicit connect and total time limits;
- retry transient connection, timeout, and HTTP 5xx failures with bounded delay;
- try all normal resolver results, including an IPv4 retry when the initial family fails;
- use a configured alternate URL only when the artifact has a known equivalent endpoint;
- write curl's final diagnostic to the job status instead of replacing it with a generic wrapper error;
- download to a temporary file and validate that it is non-empty before installation.

The design does not depend on disabling the client forwarding guard. Third-party public proxy services are not a mandatory dependency; an alternate endpoint must be explicit and testable.

### 3. Unified subscription engine

`miclash-subscription` becomes the single implementation for both manual and automatic application of subscriptions. It will expose a saved-settings entry point for the main configuration in addition to the explicit argument form used by LuCI.

The shared flow is:

1. Read the saved subscription URL and device settings.
2. Build the same user agent and device headers.
3. Download the primary URL.
4. Decode Base64 when it contains Clash YAML.
5. Detect Base64 or URI-list provider output that requires `/mihomo`.
6. Try the Remnawave `/mihomo` candidate.
7. Use the existing raw GitHub/jsDelivr fallback where applicable.
8. Apply the selected TPROXY, TUN, or MIXED configuration fragment.
9. Validate the staged file with the installed Mihomo binary.
10. Atomically replace the selected configuration.
11. Return machine-readable status fields without exposing the internal fallback path in success copy.

The engine checks for the Mihomo binary before downloading a subscription and returns the actionable error `Install the Mihomo kernel first.` when it is absent.

### 4. Auto-update scheduling

`miclash-autoupdate` will delegate the update itself to `miclash-subscription` and keep only scheduling and optional reload responsibilities.

The state directory will contain:

- `last_attempt`: timestamp written immediately before every scheduled attempt;
- `last_success`: timestamp written only after successful validation and replacement.

Due calculation uses `last_attempt`, not `last_success`. With a three-hour interval, both a success and a failure defer the next scheduled attempt for three hours. The daemon may still poll state every 60 seconds; polling no longer means downloading every 60 seconds.

After a successful update:

- if Clash is running, request a hot reload;
- if Clash is stopped, save the configuration and do nothing else.

If the kernel is absent, the attempt is recorded, an actionable warning is logged once for that interval, and neither Clash nor the guard is changed.

### 5. Package lifecycle control

OpenWrt's standard lifecycle remains responsible for stopping packaged init scripts during replacement. The duplicate explicit Clash stop and full cleanup will be removed from `prerm-pkg`.

Before installation, `miclash-update` creates one-shot no-autostart markers for Clash and `miclash-autoupdate`. Each init script consumes only its own marker when OpenWrt `default_postinst` attempts to start it, then exits successfully without launching a process. A later explicit user start is unaffected.

Hard reinstall additionally creates an explicit hard-reinstall marker. `postrm` removes the Mihomo kernel for either:

- a normal full package removal; or
- the explicit hard-reinstall operation.

A normal version update does not infer destructive intent from ambiguous package-manager arguments. The operation marker determines the behavior.

After package installation, Clash and auto-update remain stopped. Configuration and settings remain protected as conffiles and by the existing backup/restore flow.

### 6. Service and UI behavior

The service job performs a Mihomo binary preflight before enabling or starting Clash. Missing kernel behavior is consistent across service start and subscription update:

`Install the Mihomo kernel first.`

The Russian translation will use the equivalent `Сначала установите ядро Mihomo.`

The manual subscription button:

- refuses early with that message when the kernel is absent;
- downloads, validates, and saves when the kernel exists and Clash is stopped;
- additionally reloads Mihomo only when Clash is already running.

Successful subscription copy becomes `Subscription downloaded and applied.` regardless of which provider fallback was internally selected.

## Error Handling

- Each background operation preserves its originating error and phase.
- An outer helper may add context but must not replace a specific inner error with `failed to run ...`.
- Download failures report the artifact name, attempted endpoint class, curl exit code, and final curl diagnostic without leaking subscription URLs or credentials.
- Temporary downloads, request headers, lifecycle markers, and locks are cleaned on success, error, interrupt, and stale-lock recovery.
- No failure path starts Clash, changes the guard setting, or replaces the active configuration with an unvalidated file.

## Testing Strategy

### Automated shell and Node checks

- App-flow tests will assert that `miclash-update` downloads the installer from the requested tag, validates it, and passes tag, mode, token, and status path to that same installer.
- Tests will assert that `miclash-update` does not resolve or install `.ipk`/`.apk` itself, keeping `install-miclash.sh` as the canonical application installer.
- Downloader tests will simulate a primary timeout followed by a successful bounded retry or alternate endpoint, plus a fully failed case that preserves the final curl message.
- Subscription tests will use Base64 primary content and valid `/mihomo` YAML, asserting identical manual and scheduled behavior.
- Scheduler tests will assert that a failed attempt writes `last_attempt` and is not due again until the configured interval.
- Lifecycle tests will simulate OpenWrt `default_prerm/default_postinst`, asserting one stop, no automatic Clash start, no automatic auto-update start, hard-reinstall kernel removal, and normal-update kernel preservation.
- Service tests will assert that a missing kernel fails before enabling or starting Clash.
- Translation and UI checks will assert that fallback implementation details are absent from user-facing success messages.

### Live router checks

Live verification is limited to actions that cannot stop the current Clash process:

- validate downloads with the guard enabled;
- validate saved subscription fallback into a temporary file;
- validate the temporary YAML with the installed Mihomo binary;
- confirm the Clash PID and guard state before and after each check.

Package reinstall, package lifecycle, kernel replacement while Clash is running, and service stop/start are excluded from live-router verification because losing the active service would interrupt the working connection.

## Out of Scope

- Changing the semantics of the client forwarding guard.
- Automatically installing Mihomo as part of a hard MiClash reinstall.
- Automatically starting Clash after package or kernel installation.
- Introducing an always-required third-party GitHub proxy.
- Refactoring unrelated firewall, ruleset, or editor behavior.
