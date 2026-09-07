#!/usr/bin/env bash
set -uo pipefail

: "${PR_BRANCH:?Переменная PR_BRANCH обязательна}"
: "${KEEP_BRANCH:?Переменная KEEP_BRANCH обязательна}"
: "${BASE_BRANCH:?Переменная BASE_BRANCH обязательна}"
: "${GH_REPO:?Переменная GH_REPO обязательна}"

cleanup_failed=false

report_error() {
  echo "::error title=Ошибка очистки E2E::$1"
  cleanup_failed=true
}

run_status() {
  gh run view "$1" --json status --jq '.status'
}

wait_for_worker() {
  local run_id="$1"
  local status

  for _ in {1..60}; do
    if ! status=$(run_status "$run_id"); then
      report_error "Не удалось получить состояние worker ${run_id}."
      return 1
    fi
    if [[ "$status" == "completed" ]]; then
      return
    fi
    sleep 2
  done

  report_error "Worker ${run_id} не завершился после отмены."
  return 1
}

cancel_active_workers() {
  local run_ids run_id status

  if ! run_ids=$(gh run list \
      --workflow worker.yml \
      --branch "$BASE_BRANCH" \
      --event workflow_dispatch \
      --limit 100 \
      --json databaseId,status \
      --jq '.[] | select(.status == "queued" or .status == "in_progress" or .status == "pending" or .status == "requested" or .status == "waiting") | .databaseId'); then
    report_error "Не удалось получить активные worker для очистки."
    return 1
  fi

  for run_id in $run_ids; do
    if ! status=$(run_status "$run_id"); then
      report_error "Не удалось получить состояние worker ${run_id}."
      return 1
    fi
    if [[ "$status" == "completed" ]]; then
      continue
    fi

    if ! gh run cancel "$run_id"; then
      if ! status=$(run_status "$run_id") || [[ "$status" != "completed" ]]; then
        report_error "Не удалось отменить worker ${run_id}."
        return 1
      fi
    fi
    if ! wait_for_worker "$run_id"; then
      return 1
    fi
  done
}

delete_branch() {
  local branch="$1"
  local refs

  if ! refs=$(gh api "repos/${GH_REPO}/git/matching-refs/heads/${branch}" --paginate --jq '.[].ref'); then
    report_error "Не удалось проверить существование ветки ${branch}."
    return
  fi

  if grep -Fx "refs/heads/${branch}" <<< "$refs" >/dev/null; then
    if ! gh api -X DELETE "repos/${GH_REPO}/git/refs/heads/${branch}"; then
      report_error "Не удалось удалить ветку ${branch}."
    fi
  fi
}

if ! cancel_active_workers; then
  exit 1
fi

if ! pr_numbers=$(gh pr list \
    --head "$PR_BRANCH" \
    --state open \
    --json number \
    --jq '.[].number'); then
  report_error "Не удалось получить список временных Pull Request."
  pr_numbers=""
fi

for pr_number in $pr_numbers; do
  if ! gh pr close "$pr_number" --comment "Очистка E2E после запуска ${GITHUB_RUN_ID}."; then
    report_error "Не удалось закрыть Pull Request ${pr_number}."
  fi
done

delete_branch "$PR_BRANCH"
delete_branch "$KEEP_BRANCH"
delete_branch "$BASE_BRANCH"

if [[ "$cleanup_failed" == true ]]; then
  exit 1
fi
