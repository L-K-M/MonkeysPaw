#!/usr/bin/env bash
# Fake commands isolate update.sh from the host's Git checkout and Docker.
# Usage: bash scripts/tests/test-update.sh
# UPDATE_TEST_SHELL selects another shell for the updater (for example dash).
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
update_shell=$(command -v "${UPDATE_TEST_SHELL:-bash}")
dirname_command=$(command -v dirname)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/monkeyspaw-update.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
passed=0

cat >"$test_root/fake-command" <<'FAKE'
#!/bin/sh
set -eu
tool=${0##*/}
command_line=$tool
for argument in "$@"; do
  command_line="$command_line|$argument"
done
printf '%s\n' "$command_line" >>"$FAKE_COMMANDS"
[ "$PWD" = "$FAKE_CHECKOUT" ] || exit 97
if [ "$tool" = gh ]; then
  printf '%s\n' "$0" >"$FAKE_GH_PATH"
fi
if [ "$command_line" = "$FAKE_FAIL_AT" ]; then
  exit "$FAKE_FAIL_STATUS"
fi
case "$command_line" in
  'git|check-ref-format|--branch|'*) ;;
  'git|status|--porcelain')
    if [ "$FAKE_HIDE_UNTRACKED" = false ]; then printf '%s\n' "$FAKE_DIRTY"; fi ;;
  'git|status|--porcelain|--untracked-files=normal|--ignore-submodules=none') printf '%s\n' "$FAKE_DIRTY" ;;
  'git|checkout|'*'|--') printf '%s\n' "$2" >"$FAKE_BRANCH_FILE" ;;
  'git|symbolic-ref|--quiet|HEAD')
    [ "$FAKE_DETACHED" = false ] || exit 1
    IFS= read -r checked_branch <"$FAKE_BRANCH_FILE"
    printf 'refs/heads/%s\n' "$checked_branch" ;;
  'git|fetch|origin|'*) ;;
  'git|merge-base|--is-ancestor|HEAD|FETCH_HEAD') ;;
  'git|pull|--ff-only|origin|'*) ;;
  'gh|repo|sync|--branch|'*) exit "$FAKE_GH_STATUS" ;;
  'docker|compose|config|--services') printf '%s\n' "$FAKE_CONFIGURED" ;;
  'docker|compose|ps|--services|--status|running') printf '%s\n' "$FAKE_RUNNING" ;;
  'docker|compose|build|--pull') ;;
  'docker|compose|up|-d|--remove-orphans|--wait|--wait-timeout|120') ;;
  'docker|image|prune|-f'|'docker|compose|ps') ;;
  *) printf 'Unexpected fake command: %s\n' "$command_line" >&2; exit 99 ;;
esac
FAKE
chmod +x "$test_root/fake-command"

start_case() {
  case_name=$1
  case_root="$test_root/$case_name"
  checkout="$case_root/checkout space"
  fake_path="$case_root/path"
  mkdir -p "$checkout" "$fake_path"
  cp "$repo_root/update.sh" "$checkout/update.sh"
  # Compose reads .env itself; the updater must never source it as shell code.
  printf '%s\n' 'exit 93' >"$checkout/.env"
  for tool in gh git docker; do
    cp "$test_root/fake-command" "$fake_path/$tool"
  done
  ln -s "$dirname_command" "$fake_path/dirname"
  export FAKE_COMMANDS="$case_root/commands" FAKE_GH_PATH="$case_root/gh-path"
  export FAKE_CHECKOUT="$checkout" FAKE_DIRTY='' FAKE_FAIL_AT='' FAKE_FAIL_STATUS=42
  export FAKE_GH_STATUS=0
  export FAKE_HIDE_UNTRACKED=false FAKE_DETACHED=false FAKE_BRANCH_FILE="$case_root/branch"
  export FAKE_CONFIGURED=monkeyspaw-server FAKE_RUNNING=monkeyspaw-server
  expected="$case_root/expected"
  : >"$FAKE_COMMANDS"
  : >"$expected"
}

run_update() {
  actual_status=0
  (
    cd "$case_root"
    # Only fakes and dirname are visible, even when the host has gh installed.
    PATH="$fake_path" "$update_shell" "$checkout/update.sh" "$@"
  ) >"$case_root/stdout" 2>"$case_root/stderr" || actual_status=$?
}

expect_git() {
  expected_branch=${1:-main}
  cat >>"$expected" <<EOF
git|check-ref-format|--branch|$expected_branch
git|status|--porcelain|--untracked-files=normal|--ignore-submodules=none
git|checkout|$expected_branch|--
git|symbolic-ref|--quiet|HEAD
git|fetch|origin|$expected_branch
git|merge-base|--is-ancestor|HEAD|FETCH_HEAD
EOF
}

expect_deployment() {
  cat >>"$expected" <<EOF
docker|compose|build|--pull
docker|compose|up|-d|--remove-orphans|--wait|--wait-timeout|120
docker|image|prune|-f
docker|compose|ps
EOF
}

assert_equal() {
  if [ "$1" != "$2" ]; then
    printf '%s: expected <%s>, got <%s>\n' "$case_name" "$2" "$1" >&2
    cat "$case_root/stderr" >&2
    exit 1
  fi
}

check_case() {
  assert_equal "$actual_status" "$1"
  diff -u "$expected" "$FAKE_COMMANDS"
  passed=$((passed + 1))
  printf 'PASS %s\n' "$case_name"
}

start_case default
run_update
expect_git
printf '%s\n' 'gh|repo|sync|--branch|main' >>"$expected"
expect_deployment
assert_equal "$(cat "$FAKE_GH_PATH")" "$fake_path/gh"
assert_equal "$(cat "$case_root/stderr")" ''
check_case 0
cp "$expected" "$test_root/baseline"

start_case named-branch
run_update release/1.2
expect_git release/1.2
printf '%s\n' 'gh|repo|sync|--branch|release/1.2' >>"$expected"
expect_deployment
check_case 0

start_case legacy-caddy-does-not-enable-tls
FAKE_CONFIGURED=$(printf 'monkeyspaw-server\ncaddy\n')
FAKE_RUNNING=caddy
run_update
cp "$test_root/baseline" "$expected"
check_case 0

for gh_location in gh bin/gh 'gh tools/bin/gh'; do
  start_case "adjacent-${gh_location%%/*}"
  rm "$fake_path/gh"
  mkdir -p "$(dirname "$case_root/$gh_location")"
  cp "$test_root/fake-command" "$case_root/$gh_location"
  run_update
  cp "$test_root/baseline" "$expected"
  assert_equal "$(cat "$FAKE_GH_PATH")" "../$gh_location"
  check_case 0
done

start_case gh-path-first
cp "$test_root/fake-command" "$case_root/gh"
run_update
cp "$test_root/baseline" "$expected"
assert_equal "$(cat "$FAKE_GH_PATH")" "$fake_path/gh"
check_case 0

start_case skip-nonexecutable-gh
rm "$fake_path/gh"
cp "$test_root/fake-command" "$case_root/gh"
chmod -x "$case_root/gh"
mkdir "$case_root/bin"
cp "$test_root/fake-command" "$case_root/bin/gh"
run_update
cp "$test_root/baseline" "$expected"
assert_equal "$(cat "$FAKE_GH_PATH")" ../bin/gh
check_case 0

for fallback_reason in unavailable failed; do
  start_case "gh-$fallback_reason"
  expect_git release/1.2
  if [ "$fallback_reason" = unavailable ]; then
    rm "$fake_path/gh"
  else
    FAKE_FAIL_AT='gh|repo|sync|--branch|release/1.2'
    printf '%s\n' "$FAKE_FAIL_AT" >>"$expected"
  fi
  run_update release/1.2
  printf '%s\n' 'git|pull|--ff-only|origin|release/1.2' >>"$expected"
  expect_deployment
  grep -Fq 'trying git pull --ff-only' "$case_root/stderr"
  check_case 0
done

for dirty_kind in unstaged staged untracked; do
  start_case "dirty-$dirty_kind"
  case "$dirty_kind" in
    unstaged) FAKE_DIRTY=' M README.md' ;;
    staged) FAKE_DIRTY='M  README.md' ;;
    untracked) FAKE_DIRTY='?? draft.txt' ;;
  esac
  run_update
  head -n 2 "$test_root/baseline" >"$expected"
  grep -Fq 'dirty checkout' "$case_root/stderr"
  check_case 1
done

start_case diverged-or-ahead
FAKE_FAIL_AT='git|merge-base|--is-ancestor|HEAD|FETCH_HEAD'
FAKE_FAIL_STATUS=1
run_update
head -n 6 "$test_root/baseline" >"$expected"
grep -Fq 'ahead of or diverged' "$case_root/stderr"
check_case 1

# Each hard failure must keep its status and prevent every later command.
command_index=0
expected_prefix=
while IFS= read -r failed_command; do
  command_index=$((command_index + 1))
  expected_prefix="${expected_prefix}${failed_command}
"
  case "$failed_command" in gh\|*) continue ;; esac
  start_case "failure-$command_index"
  FAKE_FAIL_AT=$failed_command
  run_update
  printf '%s' "$expected_prefix" >"$expected"
  check_case 42
done <"$test_root/baseline"

for fallback_reason in unavailable failed; do
  start_case "fallback-failure-$fallback_reason"
  expect_git
  if [ "$fallback_reason" = unavailable ]; then
    rm "$fake_path/gh"
  else
    FAKE_GH_STATUS=44
    printf '%s\n' 'gh|repo|sync|--branch|main' >>"$expected"
  fi
  FAKE_FAIL_AT='git|pull|--ff-only|origin|main'
  FAKE_FAIL_STATUS=43
  run_update
  printf '%s\n' "$FAKE_FAIL_AT" >>"$expected"
  check_case 43
done

start_case hidden-untracked
FAKE_DIRTY='?? draft.txt'
FAKE_HIDE_UNTRACKED=true
run_update
head -n 2 "$test_root/baseline" >"$expected"
check_case 1
grep -Fq 'dirty checkout' "$case_root/stderr"

start_case tag-shadows-branch
FAKE_DETACHED=true
run_update
head -n 3 "$test_root/baseline" >"$expected"
printf '%s\n' 'git|symbolic-ref|--quiet|HEAD' >>"$expected"
check_case 1

start_case missing-env
rm "$checkout/.env"
run_update
cp "$test_root/baseline" "$expected"
grep -Fq 'Warning: .env is missing' "$case_root/stderr"
check_case 0

start_case extra-arguments
run_update main extra
check_case 2

printf '%s updater tests passed.\n' "$passed"
