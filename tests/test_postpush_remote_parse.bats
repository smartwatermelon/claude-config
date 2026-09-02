#!/usr/bin/env bats
# Tests for parse_remote_url() in scripts/post-push-status.sh.
#
# Why this exists: smartwatermelon/claude-config#456. The parse required the
# literal string `github.com` in the remote URL:
#
#   [[ "${REMOTE_URL}" =~ github\.com[:/]([^/]+)/([^/.]+) ]]
#
# Anyone using per-account SSH host aliases (`Host github-<account>` in
# ~/.ssh/config, a standard multi-account setup) has a remote of the form
# `git@github-smartwatermelon:owner/repo.git`, which contains no `github.com`
# substring. The script then exited 1 instead of resolving the repo.
#
# The host is not the interesting part of the URL — owner/repo is. So the parse
# now strips scheme, user, and host, then takes the last two path segments.
#
# The old pattern had a SECOND defect these tests also pin: `[^/.]+` stops the
# repo name at the first dot, so `dot.files.git` resolved to repo `dot`. That
# silently polls the wrong repo rather than failing loudly.
#
# Run: bats tests/test_postpush_remote_parse.bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/post-push-status.sh"
  # Source only the function under test: the script runs a full CI poll when
  # executed, so it cannot be sourced whole. Closing brace is at column 0.
  eval "$(sed -n '/^parse_remote_url() {/,/^}/p' "${SCRIPT}")"
}

# --- The #456 regression: SSH host aliases ---

@test "#456: SSH host alias resolves owner/repo" {
  run parse_remote_url 'git@github-smartwatermelon:smartwatermelon/huddle-transcribe.git'
  [ "${status}" -eq 0 ]
  [ "${output}" = "smartwatermelon huddle-transcribe" ]
}

@test "#456: ssh:// scheme with a host alias resolves owner/repo" {
  run parse_remote_url 'ssh://git@github-work/acme/widgets.git'
  [ "${status}" -eq 0 ]
  [ "${output}" = "acme widgets" ]
}

# --- Shapes that already worked must keep working ---

@test "scp-style github.com remote still resolves" {
  run parse_remote_url 'git@github.com:smartwatermelon/claude-config.git'
  [ "${status}" -eq 0 ]
  [ "${output}" = "smartwatermelon claude-config" ]
}

@test "https remote still resolves" {
  run parse_remote_url 'https://github.com/smartwatermelon/claude-config.git'
  [ "${status}" -eq 0 ]
  [ "${output}" = "smartwatermelon claude-config" ]
}

@test "https remote without .git suffix resolves" {
  run parse_remote_url 'https://github.com/smartwatermelon/claude-config'
  [ "${status}" -eq 0 ]
  [ "${output}" = "smartwatermelon claude-config" ]
}

@test "https remote with a trailing slash resolves" {
  run parse_remote_url 'https://github.com/owner/repo/'
  [ "${status}" -eq 0 ]
  [ "${output}" = "owner repo" ]
}

@test "https remote with an embedded user resolves" {
  run parse_remote_url 'https://user@github.com/owner/repo.git'
  [ "${status}" -eq 0 ]
  [ "${output}" = "owner repo" ]
}

@test "scp-style remote without .git suffix resolves" {
  run parse_remote_url 'git@github.com:owner/repo'
  [ "${status}" -eq 0 ]
  [ "${output}" = "owner repo" ]
}

# --- Hosts that are not github.com, and hosts carrying a port ---

@test "a non-GitHub host resolves (the host is not validated)" {
  run parse_remote_url 'git@gitlab.com:group/project.git'
  [ "${status}" -eq 0 ]
  [ "${output}" = "group project" ]
}

@test "an ssh:// URL with an explicit port resolves owner/repo, not the port" {
  # `${_u#*:}` strips through the first colon, which for this shape eats the
  # port. The trailing `^(.*/)?` in the pattern absorbs the leftover segment,
  # so the last two path components still win.
  run parse_remote_url 'ssh://git@github.com:2222/owner/repo.git'
  [ "${status}" -eq 0 ]
  [ "${output}" = "owner repo" ]
}

@test "an https URL with an explicit port resolves owner/repo" {
  run parse_remote_url 'https://github.com:443/owner/repo.git'
  [ "${status}" -eq 0 ]
  [ "${output}" = "owner repo" ]
}

# --- The dot-in-repo-name defect the old [^/.]+ pattern carried ---

@test "#456: a repo name containing a dot is not truncated" {
  # The old pattern's [^/.]+ resolved this to repo "dot", silently polling a
  # repo that is not the one the operator is in.
  run parse_remote_url 'git@github.com:smartwatermelon/dot.files.git'
  [ "${status}" -eq 0 ]
  [ "${output}" = "smartwatermelon dot.files" ]
}

# --- Non-remotes must still fail, not be coerced into a bogus owner/repo ---

@test "a bare local path does not parse as owner/repo" {
  run parse_remote_url '/local/path'
  [ "${status}" -ne 0 ]
}

@test "empty input does not parse" {
  run parse_remote_url ''
  [ "${status}" -ne 0 ]
}

@test "a single-segment remote does not parse" {
  run parse_remote_url 'git@github.com:repo.git'
  [ "${status}" -ne 0 ]
}

@test "a single-segment ssh:// remote does not invent an owner from the host" {
  # The ssh:// form of the case above. Letting the pattern absorb the host
  # segment resolved this to owner=host, which polls a repo that does not
  # exist instead of failing loudly.
  run parse_remote_url 'ssh://git@host/repo.git'
  [ "${status}" -ne 0 ]
}

@test "a file:// URL does not parse as a remote" {
  # A local path wearing a scheme.
  run parse_remote_url 'file:///home/me/repos/owner/repo.git'
  [ "${status}" -ne 0 ]
}
