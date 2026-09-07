#!/usr/bin/env bash
set -euo pipefail

: "${GH_REPO:?Переменная GH_REPO обязательна}"
: "${PR_BRANCH:?Переменная PR_BRANCH обязательна}"
: "${MANAGED_MARKER:?Переменная MANAGED_MARKER обязательна}"

phase="${1:?Необходимо указать фазу проверки}"

case "$phase" in
  created)
    : "${GITHUB_OUTPUT:?Переменная GITHUB_OUTPUT обязательна}"
    pr_json=$(gh pr list \
      --head "$PR_BRANCH" \
      --base "$GITHUB_REF_NAME" \
      --state open \
      --json number,body,files)

    count=$(jq 'length' <<< "$pr_json")
    [[ "$count" == "1" ]] || {
      echo "Ожидался один открытый PR, найдено: ${count}" >&2
      exit 1
    }

    jq -e --arg marker "$MANAGED_MARKER" \
      '.[0].body | contains($marker)' <<< "$pr_json" >/dev/null
    jq -e \
      '.[0].files | length == 1 and .[0].path == "packagedef"' \
      <<< "$pr_json" >/dev/null

    echo "number=$(jq -r '.[0].number' <<< "$pr_json")" >> "$GITHUB_OUTPUT"
    ;;
  reused)
    : "${EXPECTED_NUMBER:?Переменная EXPECTED_NUMBER обязательна}"
    pr_numbers=$(gh pr list \
      --head "$PR_BRANCH" \
      --base "$GITHUB_REF_NAME" \
      --state open \
      --json number \
      --jq '.[].number')

    [[ "$pr_numbers" == "$EXPECTED_NUMBER" ]] || {
      echo "Ожидалось повторное использование PR ${EXPECTED_NUMBER}, найдено: ${pr_numbers}" >&2
      exit 1
    }
    ;;
  cleanup)
    branch_refs=$(gh api \
      "repos/${GH_REPO}/git/matching-refs/heads/${PR_BRANCH}" \
      --paginate \
      --jq '.[].ref')
    count=$(gh pr list \
      --head "$PR_BRANCH" \
      --state closed \
      --json body \
      --jq "map(select((.body // \"\") | contains(\"${MANAGED_MARKER}\"))) | length")
    [[ "$count" == "1" ]] || {
      echo "Ожидался один закрытый управляемый PR, найдено: ${count}" >&2
      exit 1
    }

    if grep -Fx "refs/heads/${PR_BRANCH}" <<< "$branch_refs" >/dev/null; then
      echo "Управляемая ветка всё ещё существует: ${PR_BRANCH}" >&2
      exit 1
    fi
    ;;
  safety)
    : "${EXPECTED_SHA:?Переменная EXPECTED_SHA обязательна}"
    actual_sha=$(gh api "repos/${GH_REPO}/git/ref/heads/${PR_BRANCH}" --jq '.object.sha')
    [[ "$actual_sha" == "$EXPECTED_SHA" ]] || {
      echo "Пользовательская ветка изменилась: ожидался SHA ${EXPECTED_SHA}, получен ${actual_sha}" >&2
      exit 1
    }
    ;;
  *)
    echo "Неизвестная фаза проверки: ${phase}" >&2
    exit 2
    ;;
esac
