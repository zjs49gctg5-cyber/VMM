#!/bin/zsh
# Build and verify separately before replacing the standard app output.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build dist
task_stage="$PWD/.build/VMM-build-$(uuidgen).app"
task_backup="$PWD/.build/VMM-previous-$(uuidgen).app"
task_destination="$PWD/dist/VMM-latest.app"
task_installed=0
cleanup() {
  if [[ -e "$task_backup" && "$task_installed" -eq 0 && ! -e "$task_destination" ]]; then
    mv "$task_backup" "$task_destination"
  fi
  if [[ -e "$task_stage" ]]; then rm -rf -- "$task_stage"; fi
}
trap cleanup EXIT
zsh scripts/build-app.sh "$task_stage"
codesign --verify --deep --strict "$task_stage"
if [[ -e "$task_destination" ]]; then mv "$task_destination" "$task_backup"; fi
mv "$task_stage" "$task_destination"
if ! codesign --verify --deep --strict "$task_destination"; then
  rm -rf -- "$task_destination"
  exit 1
fi
task_installed=1
if [[ -e "$task_backup" ]]; then rm -rf -- "$task_backup"; fi
printf '\n完成: %s\n' "$task_destination"
