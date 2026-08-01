#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
GARDENERLESS_SETUP="${SCRIPT_DIR}/gardenerless-setup.sh"
KCP_PROVENANCE_FILE="${SCRIPT_DIR}/kcp-version.env"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/gardenerless-setup-kcp-test.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

STUB_BIN="${TEST_TMP}/bin"
RUNTIME_DIR="${TEST_TMP}/runtime"
BAD_RUNTIME_DIR="${TEST_TMP}/bad-runtime"
GIT_LOG="${TEST_TMP}/git.log"
MAKE_LOG="${TEST_TMP}/make.log"
GO_LOG="${TEST_TMP}/go.log"
RUNTIME_BIN_TRAP_LOG="${TEST_TMP}/runtime-bin-trap.log"
COMMAND_OUTPUT="${TEST_TMP}/command.out"
STATE_MARKER="${RUNTIME_DIR}/.kcp/runtime-state"
EXPECTED_RELEASE="v0.32.3"
EXPECTED_COMMIT="08be0a1c8de29f5ec6fc27d3563288be970bd3b4"
EXPECTED_REPO="https://github.com/kcp-dev/kcp.git"
WRONG_COMMIT="1111111111111111111111111111111111111111"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_log_line() {
  local expected="$1" log_file="$2" description="$3"

  grep -Fxq "$expected" "$log_file" || fail "$description"
}

assert_runtime_bin_traps_unused() {
  local command_name="$1"

  if [[ -s "$RUNTIME_BIN_TRAP_LOG" ]]; then
    cat "$RUNTIME_BIN_TRAP_LOG" >&2
    fail "${command_name} resolved a tool from the runtime bin directory"
  fi
}

# The checked-in dotenv file is the machine-readable source of truth consumed
# by setup-kcp and downstream provenance checks.
# shellcheck source=kcp-version.env
source "$KCP_PROVENANCE_FILE"
[[ "$KCP_RELEASE" == "$EXPECTED_RELEASE" ]] \
  || fail "unexpected KCP_RELEASE in kcp-version.env"
[[ "$KCP_COMMIT" == "$EXPECTED_COMMIT" ]] \
  || fail "unexpected KCP_COMMIT in kcp-version.env"
[[ "$KCP_REPO" == "$EXPECTED_REPO" ]] \
  || fail "unexpected KCP_REPO in kcp-version.env"

mkdir -p "$STUB_BIN" "${RUNTIME_DIR}/.kcp" "${RUNTIME_DIR}/bin"
printf 'preserve me\n' >"$STATE_MARKER"
: >"$GIT_LOG"
: >"$MAKE_LOG"
: >"$GO_LOG"
: >"$RUNTIME_BIN_TRAP_LOG"

for binary in git make; do
  cat >"${RUNTIME_DIR}/bin/${binary}" <<'EOF'
#!/bin/bash
tool="${0##*/}"
printf '%s\n' "$tool" >>"$KCP_RUNTIME_BIN_TRAP_LOG"
printf 'runtime-bin %s trap executed\n' "$tool" >&2
exit 97
EOF
  chmod +x "${RUNTIME_DIR}/bin/${binary}"
done

cat >"${STUB_BIN}/git" <<'EOF'
#!/bin/bash
set -euo pipefail

{
  printf 'git'
  printf '|%s' "$@"
  printf '\n'
} >>"$KCP_GIT_LOG"

repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) shift 2 ;;
    -C) repo="$2"; shift 2 ;;
    *) break ;;
  esac
done

command_name="${1:-}"
shift || true

case "$command_name" in
  rev-parse)
    case "${1:-}:${2:-}" in
      --is-inside-work-tree:)
        printf 'true\n'
        ;;
      --show-toplevel:)
        printf '%s\n' "$repo"
        ;;
      --git-dir:)
        if [[ ! -d "${repo}/.git" ]]; then
          exit 1
        fi
        printf '%s\n' "${repo}/.git"
        ;;
      --verify:refs/tags/v0.32.3^\{commit\})
        printf '%s\n' "${STUB_TAG_COMMIT:-$KCP_EXPECTED_COMMIT}"
        ;;
      --verify:HEAD)
        if [[ ! -f "${repo}/.git/HEAD_COMMIT" ]]; then
          exit 1
        fi
        cat "${repo}/.git/HEAD_COMMIT"
        ;;
      *)
        printf 'unexpected rev-parse arguments: %s %s\n' "${1:-}" "${2:-}" >&2
        exit 1
        ;;
    esac
    ;;
  symbolic-ref)
    [[ "$*" == "-q HEAD" ]]
    exit 1
    ;;
  status)
    [[ "$*" == "--porcelain=v1 --untracked-files=all --ignored=matching --ignore-submodules=none --no-ahead-behind" ]]
    printf '!! .kcp/\n!! bin/kcp\n'
    ;;
  init)
    mkdir -p "${repo}/.git"
    ;;
  remote)
    case "${1:-}:${2:-}" in
      get-url:origin)
        if [[ ! -f "${repo}/.git/origin" ]]; then
          exit 1
        fi
        cat "${repo}/.git/origin"
        ;;
      add:origin)
        printf '%s\n' "$3" >"${repo}/.git/origin"
        ;;
      set-url:origin)
        printf '%s\n' "$3" >"${repo}/.git/origin"
        ;;
      *)
        printf 'unexpected remote arguments: %s\n' "$*" >&2
        exit 1
        ;;
    esac
    ;;
  fetch)
    ;;
  checkout)
    [[ "${1:-}" == "--detach" ]]
    [[ "${2:-}" == "--force" ]]
    printf '%s\n' "$3" >"${repo}/.git/HEAD_COMMIT"
    ;;
  clean)
    [[ "$*" == "-ffdx -e .kcp/" ]]
    ;;
  *)
    printf 'unexpected git command: %s\n' "$command_name" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${STUB_BIN}/git"

cat >"${STUB_BIN}/make" <<'EOF'
#!/bin/bash
set -euo pipefail

{
  printf 'make'
  printf '|%s' "$@"
  printf '\n'
} >>"$KCP_MAKE_LOG"

[[ "${1:-}" == "-C" ]]
repo="$2"
[[ "${3:-}" == "build" ]]
mkdir -p "${repo}/bin"
for binary in kcp kubectl-kcp kubectl-ws; do
  printf '#!/bin/bash\nexit 0\n' >"${repo}/bin/${binary}"
  chmod +x "${repo}/bin/${binary}"
done
EOF
chmod +x "${STUB_BIN}/make"

cat >"${STUB_BIN}/go" <<'EOF'
#!/bin/bash
set -euo pipefail

{
  printf 'go'
  printf '|%s' "$@"
  printf '\n'
} >>"$KCP_GO_LOG"
[[ "${1:-}" == "version" && "${2:-}" == "-m" && "${3:-}" == */bin/kcp ]]
printf '%s: go1.test\n' "$3"
printf '\tbuild\tvcs.revision=%s\n' "$KCP_EXPECTED_COMMIT"
EOF
chmod +x "${STUB_BIN}/go"

run_setup_kcp() {
  env \
    PATH="${STUB_BIN}:/usr/bin:/bin" \
    GARDENERLESS_KCP_DIR="$1" \
    KCP_GIT_LOG="$GIT_LOG" \
    KCP_MAKE_LOG="$MAKE_LOG" \
    KCP_GO_LOG="$GO_LOG" \
    KCP_RUNTIME_BIN_TRAP_LOG="$RUNTIME_BIN_TRAP_LOG" \
    KCP_EXPECTED_COMMIT="$EXPECTED_COMMIT" \
    STUB_TAG_COMMIT="${STUB_TAG_COMMIT:-}" \
    "$GARDENERLESS_SETUP" setup-kcp
}

if ! run_setup_kcp "$RUNTIME_DIR" >"$COMMAND_OUTPUT" 2>&1; then
  cat "$COMMAND_OUTPUT" >&2
  cat "$GIT_LOG" >&2
  fail "initial setup-kcp run failed"
fi
assert_runtime_bin_traps_unused setup-kcp

[[ "$(cat "$STATE_MARKER")" == "preserve me" ]] \
  || fail "setup-kcp did not preserve existing .kcp runtime state"
assert_log_line \
  "git|-C|${RUNTIME_DIR}|fetch|--force|--depth=1|--no-tags|origin|refs/tags/${EXPECTED_RELEASE}:refs/tags/${EXPECTED_RELEASE}" \
  "$GIT_LOG" \
  "setup-kcp did not fetch only the pinned tag"
assert_log_line \
  "git|-C|${RUNTIME_DIR}|rev-parse|--verify|refs/tags/${EXPECTED_RELEASE}^{commit}" \
  "$GIT_LOG" \
  "setup-kcp did not verify the tag's commit"
assert_log_line \
  "git|-C|${RUNTIME_DIR}|checkout|--detach|--force|${EXPECTED_COMMIT}" \
  "$GIT_LOG" \
  "setup-kcp did not use a detached checkout"
assert_log_line \
  "git|-C|${RUNTIME_DIR}|clean|-ffdx|-e|.kcp/" \
  "$GIT_LOG" \
  "setup-kcp cleanup did not preserve .kcp"
assert_log_line \
  "make|-C|${RUNTIME_DIR}|build" \
  "$MAKE_LOG" \
  "setup-kcp did not use the repository-local build target"

if grep -Eq '(^|\|)(clone|--all|install)(\||$)' "$GIT_LOG" "$MAKE_LOG" "$GO_LOG"; then
  fail "setup-kcp used an unpinned fetch or global install path"
fi
assert_log_line \
  "go|version|-m|${RUNTIME_DIR}/bin/kcp" \
  "$GO_LOG" \
  "setup-kcp did not verify the built kcp binary metadata"
for binary in kcp kubectl-kcp kubectl-ws; do
  [[ -x "${RUNTIME_DIR}/bin/${binary}" ]] \
    || fail "setup-kcp did not retain repository-local ${binary}"
done

# A repeat performs the same pinned verification and build without deleting
# runtime state or changing checkout mode. It also restores the repository-owned
# origin if an existing checkout points elsewhere.
printf 'https://example.invalid/not-kcp.git\n' >"${RUNTIME_DIR}/.git/origin"
if ! run_setup_kcp "$RUNTIME_DIR" >"$COMMAND_OUTPUT" 2>&1; then
  cat "$COMMAND_OUTPUT" >&2
  fail "repeated setup-kcp run failed"
fi
assert_runtime_bin_traps_unused setup-kcp
[[ "$(cat "$STATE_MARKER")" == "preserve me" ]] \
  || fail "repeated setup-kcp did not preserve .kcp runtime state"
[[ "$(grep -Fc "git|-C|${RUNTIME_DIR}|fetch|--force|--depth=1|--no-tags|origin|refs/tags/${EXPECTED_RELEASE}:refs/tags/${EXPECTED_RELEASE}" "$GIT_LOG")" -eq 2 ]] \
  || fail "repeated setup-kcp did not repeat the exact pinned fetch"
[[ "$(grep -Fc "make|-C|${RUNTIME_DIR}|build" "$MAKE_LOG")" -eq 2 ]] \
  || fail "repeated setup-kcp did not rebuild the local binaries"
assert_log_line \
  "git|-C|${RUNTIME_DIR}|remote|set-url|origin|${EXPECTED_REPO}" \
  "$GIT_LOG" \
  "repeated setup-kcp did not restore the repository-owned origin"
[[ "$(cat "${RUNTIME_DIR}/.git/origin")" == "$EXPECTED_REPO" ]] \
  || fail "repeated setup-kcp left the wrong origin configured"

# Read-only diagnostics expose the same expected provenance and verify the
# detached checkout for humans and automation inspecting setup output.
env \
  PATH="${STUB_BIN}:/usr/bin:/bin" \
  GARDENERLESS_KCP_DIR="$RUNTIME_DIR" \
  KCP_GIT_LOG="$GIT_LOG" \
  KCP_EXPECTED_COMMIT="$EXPECTED_COMMIT" \
  "$GARDENERLESS_SETUP" status >"$COMMAND_OUTPUT" 2>&1
grep -Eq "^Expected kcp release:[[:space:]]+${EXPECTED_RELEASE}$" "$COMMAND_OUTPUT" \
  || fail "status did not expose the expected kcp release"
grep -Eq "^Expected kcp commit:[[:space:]]+${EXPECTED_COMMIT}$" "$COMMAND_OUTPUT" \
  || fail "status did not expose the expected kcp commit"
grep -Eq "^kcp source provenance:[[:space:]]+verified \\(detached ${EXPECTED_COMMIT}\\)$" "$COMMAND_OUTPUT" \
  || fail "status did not verify the detached kcp checkout"
assert_runtime_bin_traps_unused status

# A tag that does not resolve to the manifest commit is rejected before build.
make_lines_before="$(wc -l <"$MAKE_LOG" | tr -d ' ')"
git_lines_before="$(wc -l <"$GIT_LOG" | tr -d ' ')"
if STUB_TAG_COMMIT="$WRONG_COMMIT" \
    run_setup_kcp "$BAD_RUNTIME_DIR" >"$COMMAND_OUTPUT" 2>&1; then
  fail "setup-kcp accepted a mismatched tag commit"
fi
grep -Fq "resolves to commit ${WRONG_COMMIT}, expected ${EXPECTED_COMMIT}" "$COMMAND_OUTPUT" \
  || fail "setup-kcp did not explain the tag-commit mismatch"
[[ "$(wc -l <"$MAKE_LOG" | tr -d ' ')" == "$make_lines_before" ]] \
  || fail "setup-kcp built after a tag-commit mismatch"
if tail -n "+$((git_lines_before + 1))" "$GIT_LOG" | grep -Fq '|checkout|'; then
  fail "setup-kcp checked out a mismatched tag commit"
fi

printf 'PASS: setup-kcp is pinned, local, idempotent, and preserves runtime state\n'
