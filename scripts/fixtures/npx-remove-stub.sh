#!/usr/bin/env bash
set -euo pipefail

target_root="$PWD"
lock_path="$target_root/skills-lock.json"
if [[ " ${*} " == *" --global "* ]]; then
  target_root="$HOME"
  lock_path="${XDG_STATE_HOME:-$HOME/.agents}/skills/.skill-lock.json"
fi

[[ -z "${METAGENT_NPX_LOG:-}" ]] || printf '%s\n' "$*" >>"$METAGENT_NPX_LOG"
for skill_name in "${@:4}"; do
  [[ "$skill_name" == "--yes" || "$skill_name" == "--global" ]] && continue
  mv "$target_root/.agents/skills/$skill_name" "$target_root/.agents/skills/.removed-$skill_name"
  if [[ -e "$target_root/.codex/skills/$skill_name" ]]; then
    mv "$target_root/.codex/skills/$skill_name" "$target_root/.codex/skills/.removed-$skill_name"
  fi
  if [[ "${METAGENT_NPX_LEAVE_LOCK:-}" != "1" ]]; then
    jq --arg skill "$skill_name" 'del(.skills[$skill])' "$lock_path" >"$lock_path.next"
    mv "$lock_path.next" "$lock_path"
  fi
  if [[ "${METAGENT_NPX_FAIL_AFTER_FIRST:-}" == "1" ]]; then
    exit 42
  fi
  if [[ "${METAGENT_NPX_CORRUPT_AFTER_FIRST:-}" == "1" ]]; then
    printf '{not-json' >"$lock_path"
    exit 42
  fi
  if [[ "${METAGENT_NPX_PARTIAL_SUCCESS_CORRUPT:-}" == "1" ]]; then
    printf '{not-json' >"$lock_path"
    exit 0
  fi
done
