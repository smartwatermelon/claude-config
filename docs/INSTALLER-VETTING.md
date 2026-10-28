# Vetting Untrusted Installers

Use this when Andrew asks whether an app, `.pkg`, `.dmg`, or installer stub is safe to run, from any vendor. It came from a GOG install on 2026-10-27, where the web installer wanted more access than the game needed.

## 1. Static analysis, inside the sandbox

Unpack each download into its own new directory under `$TMPDIR`. Never run anything from that directory.

1. Signature: `codesign -dvvv --entitlements - <app>`, then `codesign --verify --deep --strict -v <app>`. Record the Authority chain and the TeamIdentifier.
2. Packages: `pkgutil --check-signature <pkg>`, then `pkgutil --expand <pkg> <dir>`. Read every `preinstall` and `postinstall` in full. Expand nested `.pkg` files and unpack tarballs in `Scripts/` too.
3. Look for these in scripts and bundles:
   - persistence: `/Library/LaunchDaemons`, `/Library/LaunchAgents`, `LoginItems`, `SMJobBless` / `SMPrivilegedExecutables`, `/Library/PrivilegedHelperTools`;
   - weak permissions: `chmod -R 777`, `chown` of system paths to the user, world-writable directories that a launchd job runs a binary from;
   - trust bypass: `xattr -d com.apple.quarantine`, `installer -allowUntrusted`;
   - privacy (TCC) APIs: `AXIsProcessTrusted`, `CGRequestScreenCaptureAccess`, `CGEventTapCreate`, `IOHIDRequestAccess`, and `*UsageDescription` keys in `Info.plist`;
   - entitlements such as `disable-library-validation` and `allow-dyld-environment-variables`.
4. Network: run `strings -a` on the binaries, filter for URLs, and group the results by host. Flag config fetched over plain `http://` and `NSAllowsArbitraryLoads`.
5. Residue: if Andrew already started the installer, check `/Applications`, `/Users/Shared`, `~/Library/Application Support`, `~/Library/Preferences`, the launchd folders, and `pkgutil --pkgs`.

## 2. Gatekeeper and notarization, outside the sandbox

Inside the sandbox, `spctl` returns "internal error" and `stapler` fails on CloudKit DNS. That result does not mean "not notarized". Give Andrew the check to run with `!`, which runs outside the sandbox:

```
! spctl -a -vvv -t exec "<abs path to .app>"
! spctl -a -vvv -t install "<abs path to .pkg>"
```

Keep the sandbox on for step 1. It limits what an unpacked payload can reach.

Report three facts separately. Each one says nothing about the others:

- **Signed by the real vendor**: the team ID and cert fingerprint match the vendor's other files.
- **Notarized**: Apple ran its malware scan on it.
- **Safe install practice**: the scripts do not leave world-writable code, root helpers, or persistence that the app does not need.

## 3. Root helpers

For each privileged helper, search for known CVEs. Then check whether the shipped binary still has the vulnerable pattern. Example: an XPC helper that validates callers by PID (`processIdentifier`, `areRequirementsValidForProcessId:`) instead of by audit token can be raced. If static analysis cannot show that the bug is fixed, say so.

## 4. Install with the least privilege

If a postinstall script only moves the payload into place, skip the package. Have Andrew copy the payload `.app` into `~/Applications` with `!`. That needs no admin password and runs no root script. Then compare the SHA-256 of the installed main binary with the copy you inspected.

## 5. Report and clean up

Lead with the verdict: whether the file is genuine, and what the real risk is. Then rank the findings by severity. After Andrew confirms, delete the temp copies and any stub installers.

## Vendor notes

### GOG (2026-10-27)

- The genuine Developer ID is "GOG Sp. z o.o.", team `9WS36Q8886`.
- The "GOG Galaxy - <Game>.app" web installer installs the Galaxy client. That pkg is notarized, but it does the following:
  - runs `chmod -R 777` on `/Users/Shared/GOG.com`;
  - adds `/Library/LaunchAgents/com.gog.galaxy.commservice.plist`, which runs a binary from that world-writable folder at every user's login;
  - installs the root helper `com.gog.galaxy.ClientService`, which had CVE-2023-40713. Helper 1.10.55 still validates callers by PID.
- Prefer the offline game installer from the game's page in the GOG library. The Cat Isle offline pkg was signed by GOG but **unnotarized**. Its payload is at `package.pkg/Scripts/payload`. The postinstall only moves the app, strips quarantine, and runs `chown`, so copying the payload to `~/Applications` worked with no prompts.
