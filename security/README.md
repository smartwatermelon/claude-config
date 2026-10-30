# Authorization replacement: staged foundation

Status: **offline implementation; no live enforcement changes**.

`install.sh` excludes this directory. Nothing here is wired into user settings,
the legacy deploy job, `clauded`, or `suclauded`.

The architecture and component retirement plan live in `smartwatermelon/dev-env`
at `docs/plans/2026-10-30-authorization-rebuild.md`. This directory belongs in
the existing policy repository; no extra policy repository or resident agent
is needed.

## Implemented

- `managed-settings.guest.json`: a deliberately closed guest policy template.
  The network list is empty pending an independently enforced egress design.
  It is **not suitable for installation on Andrew's normal Mac**: its bypass
  prohibition would disable human administrative sessions there.
- `policy.py`: exact release-contract validation, plus root ownership,
  permissions and symlink checks for an installed copy. It is not a vendor
  schema validator and cannot prove settings precedence or runtime isolation.
- `events.py`: passive hook-event normalization, keyed fingerprints, private
  bounded journals with serialized writes, and reproducible summaries. Never
  stores command text, output, reasons, raw session IDs or paths. It never
  requests a retry or changes permissions. Requires Python 3.9+ on Unix.
- `workflow.py`: executable reference state machine. Denials freeze a session
  tree, require reporting, and prevent verified completion until resolved.
  It is a **test oracle**, not an installed containment control.

## Checks

```bash
python3 -m unittest discover -s security/tests -v
python3 security/policy.py security/managed-settings.guest.json
bash scripts/tests/test-hook-block-all-runtime-failure.sh
```

Synthetic observations must use their own journal and `--environment test`:

```bash
python3 security/events.py collect --directory /private/test-journal --environment test
python3 security/events.py report /private/test-journal/events.jsonl
```

The collector reads one JSON hook event on stdin, at most 1 MiB. No CLI adapter
for privileged event metadata is provided: those adapters must run in the
trusted controller. A failed tool call stays `failed/unknown`, even if its
output says “permission denied.” Test status is supplied by the trusted caller,
never inferred from potentially hostile commands, paths or descriptions.

The journal retains the current file and one backup (2 MiB per file by
default). Old observations are intentionally lost at rotation; archive them
outside the agent environment before rotation if a longer evidence window is
needed. Reports deduplicate only repeated source/policy/outcome observations
with a tool-use correlation ID; missing IDs remain counted and are flagged.
Successful tool results do not prove task completion. False-positive rates,
workflow interruption rates and retry relationships stay unknown until a
trusted adapter supplies that evidence.

## Remaining release gates

The runtime, authenticated controller transport, collector adapters for every
layer, broker capabilities, native macOS human authentication and guest/host
separation are **not implemented or validated by this foundation**. In
particular, agents can forge same-user hook events or call Python methods in
their own process. A production controller must never trust that as authority.

Keep the existing live protections until the release-gate matrix in dev-env
passes on a disposable Mac/VM. No approval is requested to deploy these files
as security controls. They do not yet supply the required boundary.
