#!/usr/bin/env bash
# Функции gh вызываются из подключаемого файла, путь к которому вычисляется во время запуска.
# shellcheck disable=SC1091,SC2317,SC2329
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case_dir="$(mktemp -d)"
trap 'rm -rf -- "$case_dir"' EXIT

# Подключение файла не должно запускать жизненный цикл целиком.
source "$root_dir/scripts/lifecycle.sh"

export BASE_BRANCH='e2e/test-base'

counter="$case_dir/counter"
printf '0\n' > "$counter"

gh() {
  local count
  count=$(<"$counter")
  count=$((count + 1))
  printf '%s\n' "$count" > "$counter"
  if [[ "$count" -eq 1 ]]; then
    printf '100\n'
  else
    printf '200\n'
  fi
}

sleep() {
  return 0
}

run_id=$(wait_for_run 100)
[[ "$run_id" == 200 ]]
[[ "$(<"$counter")" == 2 ]]

printf '0\n' > "$counter"
gh() {
  local count
  count=$(<"$counter")
  printf '%s\n' "$((count + 1))" > "$counter"
}

if wait_for_run >/dev/null; then
  echo 'Ожидание запуска не завершилось ошибкой после исчерпания попыток' >&2
  exit 1
fi
[[ "$(<"$counter")" == 90 ]]

call_log="$case_dir/dispatch.log"
: > "$call_log"
export ACTION_SHA='abc123'
export GH_REPO='Stivo182/depos-action-e2e'
gh() {
  printf '%s\n' "$*" >> "$call_log"
  case "$*" in
    'run list '*) printf '100\n' ;;
    'workflow run '*) ;;
    'run watch 200 '*) ;;
    *) return 64 ;;
  esac
}
wait_for_run() {
  printf 'previous=%s\n' "${1:-}" >> "$call_log"
  printf '200\n'
}

run_id=$(dispatch_worker create depos/test)
[[ "$run_id" == 200 ]]
mapfile -t dispatch_calls < "$call_log"
[[ "${dispatch_calls[0]}" == run\ list* ]]
[[ "${dispatch_calls[1]}" == workflow\ run* ]]
[[ "${dispatch_calls[2]}" == 'previous=100' ]]
[[ "${dispatch_calls[3]}" == run\ watch\ 200* ]]

echo 'ПРОЙДЕНО: ожидание вспомогательного workflow'
