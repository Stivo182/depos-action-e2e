#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
controller="$root_dir/.github/workflows/e2e.yml"
worker="$root_dir/.github/workflows/worker.yml"

grep -F 'name: Контроллер E2E' "$controller" >/dev/null
grep -F 'name: Исполнитель E2E' "$worker" >/dev/null
# Обратные кавычки в Markdown проверяются как буквальный текст.
# shellcheck disable=SC2016
grep -F 'Workflow `Контроллер E2E`' "$root_dir/README.md" >/dev/null
grep -F 'повторное использование существующего PR' "$root_dir/README.md" >/dev/null
if grep -E '^\s*-?\s*name: (Checkout|Check|Run|Cleanup|Verify|Remember)' "$controller" "$worker" >/dev/null; then
  echo 'В pipeline остались английские названия этапов' >&2
  exit 1
fi

grep -F 'repository_dispatch:' "$controller" >/dev/null
grep -F 'types: [test-command]' "$controller" >/dev/null
grep -F 'ACTION_REF:' "$controller" >/dev/null
grep -F "format('refs/pull/{0}/head', github.event.client_payload.github.payload.issue.number)" "$controller" >/dev/null
grep -F 'timeout-minutes: 60' "$controller" >/dev/null
grep -F 'timeout-minutes: 15' "$worker" >/dev/null
grep -F 'github.run_attempt' "$controller" >/dev/null
grep -F 'bash scripts/lifecycle.sh' "$controller" >/dev/null
grep -F 'bash scripts/cleanup.sh' "$controller" >/dev/null
grep -F 'needs: lifecycle' "$controller" >/dev/null
grep -F 'if: always()' "$controller" >/dev/null
grep -F 'shellcheck scripts/*.sh tests/*.sh' "$controller" >/dev/null
grep -F 'uses: docker://rhysd/actionlint:1.7.12' "$controller" >/dev/null
grep -F 'bash tests/test-workflows.sh' "$controller" >/dev/null
grep -F 'bash scripts/verify.sh created' "$worker" >/dev/null
grep -F 'bash scripts/verify.sh reused' "$worker" >/dev/null
grep -F 'bash scripts/verify.sh cleanup' "$worker" >/dev/null
grep -F 'bash scripts/verify.sh safety' "$worker" >/dev/null
if grep -E 'wait_for_run\(\)|dispatch_worker\(\)' "$controller" >/dev/null; then
  echo 'Функции жизненного цикла всё ещё встроены в YAML workflow' >&2
  exit 1
fi
if grep -E 'slash_command\.args\.named\.(repository|ref)|inputs\.repository|action_repository' "$controller" "$worker" >/dev/null; then
  echo "Workflow E2E всё ещё принимает repository/ref из slash-команды" >&2
  exit 1
fi

grep -F 'repository: Stivo182/depos-action' "$worker" >/dev/null
# Выражение GitHub Actions проверяется как буквальный текст.
# shellcheck disable=SC2016
grep -F 'ref: ${{ inputs.action_ref }}' "$worker" >/dev/null
grep -F 'path: depos-action-local' "$worker" >/dev/null
grep -F 'uses: ./depos-action-local' "$worker" >/dev/null
# Выражение GitHub Actions проверяется как буквальный текст.
# shellcheck disable=SC2016
if [[ "$(grep -Fc 'base: ${{ github.ref_name }}' "$worker")" -ne 2 ]]; then
  echo 'Не все запуски depos-action получили временную базовую ветку' >&2
  exit 1
fi
grep -F 'latest_run_id' "$root_dir/scripts/lifecycle.sh" >/dev/null
if [[ "$(grep -Fc -- '--workflow worker.yml' "$root_dir/scripts/lifecycle.sh")" -ne 1 ]]; then
  echo 'Запрос последнего запуска worker продублирован в lifecycle.sh' >&2
  exit 1
fi
grep -F 'matching-refs/heads/' "$root_dir/scripts/cleanup.sh" >/dev/null
grep -F 'matching-refs/heads/' "$root_dir/scripts/verify.sh" >/dev/null
grep -F 'any(.name == "dependencies")' "$root_dir/scripts/verify.sh" >/dev/null

for variable in GH_REPO BASE_BRANCH PR_BRANCH KEEP_BRANCH; do
  if [[ "$(grep -Ec "^[[:space:]]+${variable}:" "$controller")" -ne 1 ]]; then
    echo "Общая переменная ${variable} продублирована между jobs" >&2
    exit 1
  fi
done

if grep -F 'uses: Stivo182/depos-action@main' "$worker" >/dev/null; then
  echo "Исполнитель всё ещё запускает ветку main напрямую" >&2
  exit 1
fi

bash -n \
  "$root_dir/scripts/lifecycle.sh" \
  "$root_dir/scripts/cleanup.sh" \
  "$root_dir/scripts/verify.sh"

if ! cleanup_test_output=$(bash "$root_dir/tests/test-cleanup.sh" 2>&1); then
  printf '%s\n' "$cleanup_test_output" >&2
  exit 1
fi
if grep -F '::error' <<< "$cleanup_test_output" >/dev/null; then
  echo 'Ожидаемые ошибки очистки попали в вывод успешного теста' >&2
  printf '%s\n' "$cleanup_test_output" >&2
  exit 1
fi
printf '%s\n' "$cleanup_test_output"
bash "$root_dir/tests/test-lifecycle.sh"

echo "ПРОЙДЕНО: контракт E2E с фиксированным репозиторием"
