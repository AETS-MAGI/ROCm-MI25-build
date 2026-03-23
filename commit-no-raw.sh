#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./commit-no-raw.sh -m "commit message" [--push] [--add <path> ...]

Behavior:
  - stages tracked changes (`git add -u`)
  - stages extra paths passed by `--add`
  - unstages log/probe artifacts under:
      - vega_path_check_logs/
      - .rocprofv3/
  - commits with given message
  - optionally pushes current branch with `--push`
USAGE
}

msg=""
do_push=0
extra_add=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--message)
      [[ $# -ge 2 ]] || { echo "ERROR: missing value for $1" >&2; exit 2; }
      msg="$2"
      shift 2
      ;;
    --push)
      do_push=1
      shift
      ;;
    --add)
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do
        extra_add+=("$1")
        shift
      done
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$msg" ]]; then
  echo "ERROR: commit message is required." >&2
  usage >&2
  exit 2
fi

# 1) Stage tracked modifications/deletions.
git add -u

# 2) Stage extra files explicitly requested.
if [[ "${#extra_add[@]}" -gt 0 ]]; then
  git add -- "${extra_add[@]}"
fi

# 3) Always unstage known heavy artifact trees if they were staged accidentally.
git restore --staged -- vega_path_check_logs/ .rocprofv3/ 2>/dev/null || true

if git diff --cached --quiet; then
  echo "No staged changes to commit after raw-log exclusion."
  exit 0
fi

echo "--- staged changes ---"
git diff --cached --name-status

git commit -m "$msg"

if [[ "$do_push" == "1" ]]; then
  branch="$(git rev-parse --abbrev-ref HEAD)"
  git push origin "$branch"
fi
