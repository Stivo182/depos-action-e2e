#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case_dir="$(mktemp -d)"
cleanup_case() {
  local status="$?"
  if [[ "$status" -ne 0 && -f "${GH_CALL_LOG:-}" ]]; then
    echo 'Вызовы gh перед ошибкой:' >&2
    sed 's/^/  /' "$GH_CALL_LOG" >&2
  fi
  rm -rf -- "$case_dir"
  exit "$status"
}
trap cleanup_case EXIT

cat > "$case_dir/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_CALL_LOG"
case "$*" in
  'run list '*)
    if [[ "${GH_RUN_LIST_FAIL:-false}" == true ]]; then
      exit 8
    fi
    if [[ "${GH_ACTIVE_RUN:-false}" == true ]]; then
      printf '77\n'
    fi
    ;;
  'run cancel 77')
    if [[ "${GH_RUN_CANCEL_FAIL:-false}" == true ]]; then
      exit 9
    fi
    printf 'true\n' > "$GH_CANCELLED_FILE"
    ;;
  'run view 77 '*)
    if [[ "${GH_RUN_VIEW_FAIL:-false}" == true ]]; then
      exit 10
    fi
    if [[ "${GH_NEVER_COMPLETE:-false}" == true ]]; then
      printf 'in_progress\n'
      exit 0
    fi
    if [[ -s "$GH_CANCELLED_FILE" ]]; then
      printf 'completed\n'
    else
      printf 'in_progress\n'
    fi
    ;;
  'pr list '*) printf '42\n' ;;
  'pr close '*)
    if [[ "${GH_CLOSE_FAIL:-false}" == true ]]; then
      exit 7
    fi
    ;;
  'api repos/'*'/git/matching-refs/heads/'*)
    if [[ "${GH_REF_LIST_FAIL:-false}" == true ]]; then
      exit 9
    fi
    branch="${2}"
    branch="${branch#*/git/matching-refs/heads/}"
    if [[ "$branch" != 'e2e/missing' ]]; then
      printf 'refs/heads/%s\n' "$branch"
    fi
    ;;
  'api -X DELETE '*) ;;
  *)
    echo "Неожиданный вызов gh: $*" >&2
    exit 64
    ;;
esac
SH
chmod +x "$case_dir/gh"

cat > "$case_dir/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$case_dir/sleep"

export PATH="$case_dir:$PATH"
export GH_CALL_LOG="$case_dir/gh.log"
export GH_CANCELLED_FILE="$case_dir/cancelled"
export GH_REPO='Stivo182/depos-action-e2e'
export PR_BRANCH='depos/test'
export KEEP_BRANCH='e2e/keep'
export BASE_BRANCH='e2e/missing'
export GITHUB_RUN_ID=123
expected_error_log="$case_dir/expected-error.log"

assert_reported_error() {
  local expected_message="$1"

  if ! grep -Fx "::error title=Ошибка очистки E2E::${expected_message}" "$expected_error_log" >/dev/null; then
    echo "Не найдена ожидаемая ошибка очистки: ${expected_message}" >&2
    sed 's/^/  /' "$expected_error_log" >&2
    exit 1
  fi
}

GH_ACTIVE_RUN=true bash "$root_dir/scripts/cleanup.sh"
grep -F 'run cancel 77' "$GH_CALL_LOG" >/dev/null
grep -F 'pr close 42' "$GH_CALL_LOG" >/dev/null
grep -F 'matching-refs/heads/depos/test' "$GH_CALL_LOG" >/dev/null
grep -F 'git/refs/heads/depos/test' "$GH_CALL_LOG" >/dev/null
grep -F 'git/refs/heads/e2e/keep' "$GH_CALL_LOG" >/dev/null

cancel_line=$(grep -nF 'run cancel 77' "$GH_CALL_LOG" | cut -d: -f1)
delete_line=$(grep -nF 'api -X DELETE' "$GH_CALL_LOG" | head -n1 | cut -d: -f1)
if (( cancel_line >= delete_line )); then
  echo 'Временные ветки удаляются до отмены worker' >&2
  exit 1
fi

assert_worker_failure_is_closed() {
  local failure_variable="$1"
  local expected_message="$2"

  : > "$GH_CALL_LOG"
  : > "$expected_error_log"
  rm -f -- "$GH_CANCELLED_FILE"
  if env GH_ACTIVE_RUN=true "$failure_variable=true" \
      bash "$root_dir/scripts/cleanup.sh" >"$expected_error_log" 2>&1; then
    echo "Ошибка worker ${failure_variable} не остановила очистку" >&2
    exit 1
  fi
  assert_reported_error "$expected_message"
  if grep -Eq 'pr close|api -X DELETE' "$GH_CALL_LOG"; then
    echo "После ошибки worker ${failure_variable} началось удаление ресурсов" >&2
    exit 1
  fi
}

assert_worker_failure_is_closed \
  GH_RUN_LIST_FAIL \
  'Не удалось получить активные worker для очистки.'
assert_worker_failure_is_closed \
  GH_RUN_VIEW_FAIL \
  'Не удалось получить состояние worker 77.'
assert_worker_failure_is_closed \
  GH_RUN_CANCEL_FAIL \
  'Не удалось отменить worker 77.'
assert_worker_failure_is_closed \
  GH_NEVER_COMPLETE \
  'Worker 77 не завершился после отмены.'

: > "$expected_error_log"
if GH_CLOSE_FAIL=true bash "$root_dir/scripts/cleanup.sh" >"$expected_error_log" 2>&1; then
  echo 'Ошибка закрытия PR была скрыта' >&2
  exit 1
fi
assert_reported_error 'Не удалось закрыть Pull Request 42.'

: > "$expected_error_log"
if GH_REF_LIST_FAIL=true bash "$root_dir/scripts/cleanup.sh" >"$expected_error_log" 2>&1; then
  echo 'Ошибка получения веток была принята за их отсутствие' >&2
  exit 1
fi
assert_reported_error 'Не удалось проверить существование ветки depos/test.'
assert_reported_error 'Не удалось проверить существование ветки e2e/keep.'
assert_reported_error 'Не удалось проверить существование ветки e2e/missing.'

echo 'ПРОЙДЕНО: очистка ресурсов E2E'
