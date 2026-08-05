#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
GARDENERLESS_SETUP="${SCRIPT_DIR}/gardenerless-setup.sh"
KCP_PROVENANCE_FILE="${SCRIPT_DIR}/kcp-version.env"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/gardenerless-setup-kcp-test.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

REAL_GIT="$(command -v git)"
STUB_BIN="${TEST_TMP}/bin"
RUNTIME_DIR="${TEST_TMP}/runtime"
BAD_RUNTIME_DIR="${TEST_TMP}/bad-runtime"
NESTED_PARENT_DIR="${TEST_TMP}/enclosing-worktree"
NESTED_RUNTIME_DIR="${NESTED_PARENT_DIR}/nested-runtime"
UNSAFE_RUNTIME_DIR="${NESTED_PARENT_DIR}/unsafe-runtime"
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

mkdir -p "$STUB_BIN" "${RUNTIME_DIR}/.git" "${RUNTIME_DIR}/.kcp" "${RUNTIME_DIR}/bin"
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
        if [[ -n "${KCP_USE_REAL_REPOSITORY_LAYOUT:-}" ]]; then
          "$KCP_REAL_GIT" -C "$repo" rev-parse --is-inside-work-tree
        elif [[ -d "${repo}/.git" ]]; then
          printf 'true\n'
        else
          exit 1
        fi
        ;;
      --show-toplevel:)
        if [[ -n "${KCP_USE_REAL_REPOSITORY_LAYOUT:-}" ]]; then
          "$KCP_REAL_GIT" -C "$repo" rev-parse --show-toplevel
        else
          printf '%s\n' "$repo"
        fi
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
    if [[ -n "${KCP_USE_REAL_REPOSITORY_LAYOUT:-}" ]]; then
      "$KCP_REAL_GIT" -C "$repo" init --quiet
    else
      mkdir -p "${repo}/.git"
    fi
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
    KCP_REAL_GIT="$REAL_GIT" \
    KCP_USE_REAL_REPOSITORY_LAYOUT="${KCP_USE_REAL_REPOSITORY_LAYOUT:-}" \
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

# A fresh empty runtime nested in another worktree must become its own
# repository without changing any enclosing-repository state.
mkdir -p "$NESTED_PARENT_DIR"
"$REAL_GIT" -C "$NESTED_PARENT_DIR" init --quiet
"$REAL_GIT" -C "$NESTED_PARENT_DIR" config user.name 'Setup KCP Test'
"$REAL_GIT" -C "$NESTED_PARENT_DIR" config user.email 'setup-kcp-test@example.invalid'
"$REAL_GIT" -C "$NESTED_PARENT_DIR" config gardenerless.test-marker 'preserve parent config'
printf 'nested-runtime/\nunsafe-runtime/\n' >"${NESTED_PARENT_DIR}/.gitignore"
printf 'parent fixture\n' >"${NESTED_PARENT_DIR}/fixture"
"$REAL_GIT" -C "$NESTED_PARENT_DIR" add .gitignore fixture
"$REAL_GIT" -c commit.gpgsign=false -C "$NESTED_PARENT_DIR" commit --quiet -m 'Create enclosing fixture'
"$REAL_GIT" -C "$NESTED_PARENT_DIR" remote add enclosing https://example.invalid/enclosing.git

parent_head_before=$("$REAL_GIT" -C "$NESTED_PARENT_DIR" rev-parse HEAD)
parent_status_before=$("$REAL_GIT" -C "$NESTED_PARENT_DIR" status --porcelain=v1 --untracked-files=all)
parent_remotes_before=$("$REAL_GIT" -C "$NESTED_PARENT_DIR" remote -v)
parent_config_before=$("$REAL_GIT" -C "$NESTED_PARENT_DIR" config --local --list)

if ! KCP_USE_REAL_REPOSITORY_LAYOUT=1 \
    run_setup_kcp "$NESTED_RUNTIME_DIR" >"$COMMAND_OUTPUT" 2>&1; then
  cat "$COMMAND_OUTPUT" >&2
  fail "setup-kcp rejected a fresh runtime nested in another worktree"
fi
assert_log_line \
  "git|-C|${NESTED_RUNTIME_DIR}|init" \
  "$GIT_LOG" \
  "setup-kcp did not initialize the nested runtime"
nested_runtime_root=$("$REAL_GIT" -C "$NESTED_RUNTIME_DIR" rev-parse --show-toplevel)
[[ "$nested_runtime_root" == "$(cd -- "$NESTED_RUNTIME_DIR" && pwd -P)" ]] \
  || fail "nested runtime was not initialized at its selected worktree root"
if ! KCP_USE_REAL_REPOSITORY_LAYOUT=1 \
    run_setup_kcp "$NESTED_RUNTIME_DIR" >"$COMMAND_OUTPUT" 2>&1; then
  cat "$COMMAND_OUTPUT" >&2
  fail "repeated setup-kcp rejected the valid nested repository"
fi
[[ "$(grep -Fc "git|-C|${NESTED_RUNTIME_DIR}|init" "$GIT_LOG")" -eq 1 ]] \
  || fail "repeated setup-kcp reinitialized the valid nested repository"

# A non-empty directory that merely inherits the enclosing worktree is unsafe:
# refuse it before repository initialization or any mutating Git workflow.
mkdir -p "$UNSAFE_RUNTIME_DIR"
printf 'must not be taken over\n' >"${UNSAFE_RUNTIME_DIR}/existing-data"
unsafe_git_lines_before=$(wc -l <"$GIT_LOG" | tr -d ' ')
if KCP_USE_REAL_REPOSITORY_LAYOUT=1 \
    run_setup_kcp "$UNSAFE_RUNTIME_DIR" >"$COMMAND_OUTPUT" 2>&1; then
  fail "setup-kcp accepted a non-empty mismatched worktree layout"
fi
grep -Fq "is not the Git worktree root" "$COMMAND_OUTPUT" \
  || fail "setup-kcp did not explain the unsafe worktree-root mismatch"
if tail -n "+$((unsafe_git_lines_before + 1))" "$GIT_LOG" \
    | grep -Eq '\|(init|remote|fetch|checkout|clean)(\||$)'; then
  fail "setup-kcp mutated an unsafe mismatched worktree layout"
fi
[[ "$(cat "${UNSAFE_RUNTIME_DIR}/existing-data")" == "must not be taken over" ]] \
  || fail "setup-kcp changed existing data in the unsafe runtime"

[[ "$("$REAL_GIT" -C "$NESTED_PARENT_DIR" rev-parse HEAD)" == "$parent_head_before" ]] \
  || fail "setup-kcp changed the enclosing repository HEAD"
[[ "$("$REAL_GIT" -C "$NESTED_PARENT_DIR" status --porcelain=v1 --untracked-files=all)" == "$parent_status_before" ]] \
  || fail "setup-kcp changed the enclosing repository status"
[[ "$("$REAL_GIT" -C "$NESTED_PARENT_DIR" remote -v)" == "$parent_remotes_before" ]] \
  || fail "setup-kcp changed the enclosing repository remotes"
[[ "$("$REAL_GIT" -C "$NESTED_PARENT_DIR" config --local --list)" == "$parent_config_before" ]] \
  || fail "setup-kcp changed the enclosing repository configuration"

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

printf 'PASS: setup-kcp is pinned, local, idempotent, nested-safe, and preserves runtime state\n'
