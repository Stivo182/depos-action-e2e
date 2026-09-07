#!/usr/bin/env bash
set -euo pipefail

wait_for_run() {
  local previous_id="${1:-}"
  local run_id

  # Очередь GitHub Actions может задержать появление запуска на несколько минут.
  for _ in {1..90}; do
    run_id=$(latest_run_id)

    if [[ -n "$run_id" && "$run_id" != "$previous_id" ]]; then
      printf '%s\n' "$run_id"
      return 0
    fi
    sleep 2
  done

  echo "Запуск вспомогательного workflow не был создан" >&2
  return 1
}

latest_run_id() {
  gh run list \
    --workflow worker.yml \
    --branch "$BASE_BRANCH" \
    --event workflow_dispatch \
    --limit 1 \
    --json databaseId \
    --jq '.[0].databaseId // empty'
}

dispatch_worker() {
  local phase="$1"
  local pr_branch="$2"
  local previous_id
  local run_id

  previous_id=$(latest_run_id)

  gh workflow run worker.yml \
    --ref "$BASE_BRANCH" \
    -f phase="$phase" \
    -f pr_branch="$pr_branch" \
    -f action_ref="$ACTION_SHA" >&2

  run_id=$(wait_for_run "$previous_id")
  echo "Фаза ${phase}: https://github.com/${GH_REPO}/actions/runs/${run_id}" >&2
  gh run watch "$run_id" --exit-status >&2
  printf '%s\n' "$run_id"
}

main() {
  : "${GH_REPO:?Переменная GH_REPO обязательна}"
  : "${BASE_BRANCH:?Переменная BASE_BRANCH обязательна}"
  : "${PR_BRANCH:?Переменная PR_BRANCH обязательна}"
  : "${KEEP_BRANCH:?Переменная KEEP_BRANCH обязательна}"
  : "${ACTION_REF:?Переменная ACTION_REF обязательна}"

  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

  ACTION_SHA=$(git -C depos-action-source rev-parse HEAD)
  echo "Тестируется Stivo182/depos-action@${ACTION_REF} (${ACTION_SHA})"

  git switch -c "$BASE_BRANCH"
  git push origin "HEAD:refs/heads/$BASE_BRANCH"

  dispatch_worker create "$PR_BRANCH" >/dev/null

  git fetch origin "$PR_BRANCH"
  git show FETCH_HEAD:packagedef > packagedef
  git add packagedef
  git commit -m "test: apply dependency update"
  git push origin "HEAD:refs/heads/$BASE_BRANCH"

  dispatch_worker cleanup "$PR_BRANCH" >/dev/null

  git push origin "HEAD:refs/heads/$KEEP_BRANCH"
  dispatch_worker safety "$KEEP_BRANCH" >/dev/null
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
