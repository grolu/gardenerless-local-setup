#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
GARDENERLESS_SETUP="${SCRIPT_DIR}/gardenerless-setup.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/gardenerless-verify-kcp-test.XXXXXX")"
trap 'chmod -R u+w "$TEST_TMP" 2>/dev/null || true; rm -rf "$TEST_TMP"' EXIT

STUB_BIN="${TEST_TMP}/bin"
RUNTIME_DIR="${TEST_TMP}/runtime"
STDOUT_FILE="${TEST_TMP}/stdout"
STDERR_FILE="${TEST_TMP}/stderr"
GIT_LOG="${TEST_TMP}/git.log"
GO_LOG="${TEST_TMP}/go.log"
FORBIDDEN_LOG="${TEST_TMP}/forbidden.log"
EXPECTED_RELEASE="v0.32.3"
EXPECTED_COMMIT="08be0a1c8de29f5ec6fc27d3563288be970bd3b4"
WRONG_COMMIT="1111111111111111111111111111111111111111"
EXPECTED_JSON="{\"schemaVersion\":1,\"release\":\"${EXPECTED_RELEASE}\",\"commit\":\"${EXPECTED_COMMIT}\"}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_binary() {
  rm -f "${RUNTIME_DIR}/bin/kcp"
  printf '#!/bin/bash\nexit 0\n' >"${RUNTIME_DIR}/bin/kcp"
  chmod +x "${RUNTIME_DIR}/bin/kcp"
}

run_verify() {
  env \
    PATH="${STUB_BIN}:/usr/bin:/bin" \
    GARDENERLESS_KCP_DIR="$RUNTIME_DIR" \
    KUBECONFIG="${TEST_TMP}/must-not-be-read.kubeconfig" \
    VERIFY_GIT_LOG="$GIT_LOG" \
    VERIFY_GO_LOG="$GO_LOG" \
    VERIFY_FORBIDDEN_LOG="$FORBIDDEN_LOG" \
    VERIFY_EXPECTED_COMMIT="$EXPECTED_COMMIT" \
    STUB_RUNTIME_DIR="$RUNTIME_DIR" \
    STUB_HEAD="${STUB_HEAD:-$EXPECTED_COMMIT}" \
    STUB_WORKTREE_ROOT="${STUB_WORKTREE_ROOT:-$RUNTIME_DIR}" \
    STUB_ATTACHED="${STUB_ATTACHED:-}" \
    STUB_GIT_STATUS="${STUB_GIT_STATUS:-}" \
    STUB_GO_MODE="${STUB_GO_MODE:-valid}" \
    "$GARDENERLESS_SETUP" verify-kcp --format=json \
      >"$STDOUT_FILE" 2>"$STDERR_FILE"
}

assert_success_json() {
  [[ "$(cat "$STDOUT_FILE")" == "$EXPECTED_JSON" ]] \
    || fail "successful stdout did not match the exact JSON contract"
  [[ "$(wc -l <"$STDOUT_FILE" | tr -d ' ')" == "1" ]] \
    || fail "successful verification did not print exactly one JSON line"
  [[ ! -s "$STDERR_FILE" ]] \
    || fail "successful verification wrote a diagnostic to stderr"
}

assert_failure() {
  local description="$1" diagnostic="$2"

  [[ ! -s "$STDOUT_FILE" ]] \
    || fail "$description printed partial JSON to stdout"
  grep -Fq "$diagnostic" "$STDERR_FILE" \
    || fail "$description did not print an actionable diagnostic containing '$diagnostic'"
}

mkdir -p "$STUB_BIN" "${RUNTIME_DIR}/.git" "${RUNTIME_DIR}/.kcp" "${RUNTIME_DIR}/bin"
: >"$GIT_LOG"
: >"$GO_LOG"
: >"$FORBIDDEN_LOG"
printf 'runtime state must survive verification\n' >"${RUNTIME_DIR}/.kcp/state-marker"
make_binary

cat >"${STUB_BIN}/git" <<'EOF'
#!/bin/bash
set -euo pipefail

{
  printf 'git'
  printf '|%s' "$@"
  printf '\n'
} >>"$VERIFY_GIT_LOG"

[[ "${GIT_OPTIONAL_LOCKS:-}" == "0" ]] || {
  printf 'git-with-optional-locks|%s\n' "$*" >>"$VERIFY_FORBIDDEN_LOG"
  exit 98
}

repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c)
      shift 2
      ;;
    -C)
      repo="$2"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

[[ "$repo" == "$STUB_RUNTIME_DIR" ]]
command_name="${1:-}"
shift || true

case "$command_name" in
  rev-parse)
    case "$*" in
      --is-inside-work-tree) printf 'true\n' ;;
      --show-toplevel) printf '%s\n' "$STUB_WORKTREE_ROOT" ;;
      --verify\ HEAD) printf '%s\n' "$STUB_HEAD" ;;
      *)
        printf 'git-rev-parse|%s\n' "$*" >>"$VERIFY_FORBIDDEN_LOG"
        exit 97
        ;;
    esac
    ;;
  symbolic-ref)
    [[ "$*" == "-q HEAD" ]]
    if [[ -n "$STUB_ATTACHED" ]]; then
      printf 'refs/heads/main\n'
      exit 0
    fi
    exit 1
    ;;
  status)
    [[ "$*" == "--porcelain=v1 --untracked-files=all --ignored=matching --ignore-submodules=none --no-ahead-behind" ]]
    printf '%s' "$STUB_GIT_STATUS"
    ;;
  *)
    printf 'git-%s|%s\n' "$command_name" "$*" >>"$VERIFY_FORBIDDEN_LOG"
    exit 97
    ;;
esac
EOF
chmod +x "${STUB_BIN}/git"

cat >"${STUB_BIN}/go" <<'EOF'
#!/bin/bash
set -euo pipefail

{
  printf 'go'
  printf '|%s' "$@"
  printf '\n'
} >>"$VERIFY_GO_LOG"

[[ "${1:-}" == "version" && "${2:-}" == "-m" && "${3:-}" == */bin/kcp ]]
printf '%s: go1.26.4\n' "$3"
case "$STUB_GO_MODE" in
  valid)
    printf '\tbuild\tvcs.revision=%s\n' "$VERIFY_EXPECTED_COMMIT"
    ;;
  missing)
    ;;
  duplicate)
    printf '\tbuild\tvcs.revision=%s\n' "$VERIFY_EXPECTED_COMMIT"
    printf '\tbuild\tvcs.revision=%s\n' "$VERIFY_EXPECTED_COMMIT"
    ;;
  malformed)
    printf '\tbuild\tvcs.revision=not-a-commit\n'
    ;;
  mismatch)
    printf '\tbuild\tvcs.revision=1111111111111111111111111111111111111111\n'
    ;;
  *)
    exit 96
    ;;
esac
EOF
chmod +x "${STUB_BIN}/go"

for forbidden_command in kubectl curl wget make ssh nc; do
  cat >"${STUB_BIN}/${forbidden_command}" <<'EOF'
#!/bin/bash
printf '%s|%s\n' "${0##*/}" "$*" >>"$VERIFY_FORBIDDEN_LOG"
exit 95
EOF
  chmod +x "${STUB_BIN}/${forbidden_command}"
done

# The valid fixture includes only the ignored paths owned by Gardenerless.
STUB_GIT_STATUS=$'!! .kcp/\n!! bin/kcp\n' run_verify \
  || fail "valid runtime was rejected"
assert_success_json

if STUB_HEAD="$WRONG_COMMIT" run_verify; then
  fail "wrong HEAD was accepted"
fi
assert_failure "wrong HEAD" "checkout HEAD is ${WRONG_COMMIT}, expected ${EXPECTED_COMMIT}"

if STUB_GIT_STATUS=$' M README.md\n' run_verify; then
  fail "dirty checkout was accepted"
fi
assert_failure "dirty checkout" "unexpected kcp checkout drift:  M README.md"

if STUB_GIT_STATUS=$'!! build/\n' run_verify; then
  fail "unexpected ignored build path was accepted"
fi
assert_failure "unexpected ignored path" "unexpected kcp checkout drift: !! build/"

if STUB_WORKTREE_ROOT="$TEST_TMP" run_verify; then
  fail "runtime below a different worktree root was accepted"
fi
assert_failure "unsafe worktree root" "is not the Git worktree root"

if STUB_ATTACHED=1 run_verify; then
  fail "attached checkout was accepted"
fi
assert_failure "attached checkout" "checkout is attached to a branch"

rm -f "${RUNTIME_DIR}/bin/kcp"
if run_verify; then
  fail "missing binary was accepted"
fi
assert_failure "missing binary" "is missing or not a regular file"

make_binary
chmod -x "${RUNTIME_DIR}/bin/kcp"
if run_verify; then
  fail "non-executable binary was accepted"
fi
assert_failure "non-executable binary" "is not executable"

make_binary
mv "${RUNTIME_DIR}/bin/kcp" "${TEST_TMP}/real-kcp"
ln -s "${TEST_TMP}/real-kcp" "${RUNTIME_DIR}/bin/kcp"
if run_verify; then
  fail "symlinked binary was accepted"
fi
assert_failure "symlinked binary" "must not be a symbolic link"
make_binary

for metadata_case in missing duplicate malformed mismatch; do
  if STUB_GO_MODE="$metadata_case" run_verify; then
    fail "$metadata_case vcs.revision was accepted"
  fi
  case "$metadata_case" in
    missing)   diagnostic="exactly one vcs.revision, found 0" ;;
    duplicate) diagnostic="exactly one vcs.revision, found 2" ;;
    malformed) diagnostic="is not a 40-character lowercase commit" ;;
    mismatch) diagnostic="vcs.revision is ${WRONG_COMMIT}, expected ${EXPECTED_COMMIT}" ;;
  esac
  assert_failure "$metadata_case vcs.revision" "$diagnostic"
done

# A successful verification works with the complete runtime tree read-only.
# Tool stubs reject any Git mutation and record any API/network-capable command.
chmod -R a-w "$RUNTIME_DIR"
STUB_GIT_STATUS=$'!! .kcp/\n!! bin/kcp\n' run_verify \
  || fail "verification attempted to write to the selected runtime"
assert_success_json
chmod -R u+w "$RUNTIME_DIR"
[[ "$(cat "${RUNTIME_DIR}/.kcp/state-marker")" == "runtime state must survive verification" ]] \
  || fail "verification changed runtime state"
[[ ! -s "$FORBIDDEN_LOG" ]] || {
  cat "$FORBIDDEN_LOG" >&2
  fail "verification invoked a mutating, API, or network-capable command"
}

# Invalid format is rejected before inspecting the runtime and keeps stdout empty.
git_lines_before="$(wc -l <"$GIT_LOG" | tr -d ' ')"
if env PATH="${STUB_BIN}:/usr/bin:/bin" \
    GARDENERLESS_KCP_DIR="$RUNTIME_DIR" \
    "$GARDENERLESS_SETUP" verify-kcp --format=yaml \
      >"$STDOUT_FILE" 2>"$STDERR_FILE"; then
  fail "unsupported verify-kcp format was accepted"
fi
assert_failure "unsupported format" "requires exactly '--format=json'"
[[ "$(wc -l <"$GIT_LOG" | tr -d ' ')" == "$git_lines_before" ]] \
  || fail "unsupported format inspected the runtime"

printf 'PASS: verify-kcp emits stable JSON and rejects inconsistent runtimes read-only\n'
