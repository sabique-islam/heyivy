#!/usr/bin/env bash
# Copies every skill from the submodules, skills/<pack>/skills/<name>, to .agents/skills/<name>.
#
#   scripts/export-skills.sh                  rebuild .agents/skills
#   scripts/export-skills.sh --dest <folder>  export somewhere else
#   scripts/export-skills.sh --check          fail if the export is missing or out of date
#
# It writes real copies because some agent tools skip symlinked skill folders.
# Never edit the export. Change skills upstream, update the submodule, then export again.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
marker=".exported-by-ivy"
dest="$root/.agents/skills"
mode="export"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) mode="check"; shift ;;
    --dest)
      [ "$#" -ge 2 ] || { echo "--dest needs a folder" >&2; exit 2; }
      dest="$2"
      shift 2
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT

# A partial export would look fine while silently missing a whole pack.
for pack_dir in "$root"/skills/*/; do
  if [ ! -d "$pack_dir/skills" ]; then
    echo "$(basename "$pack_dir") is empty. Run: git submodule update --init" >&2
    exit 1
  fi
done

skill_count=0
for skill_file in "$root"/skills/*/skills/*/SKILL.md; do
  [ -f "$skill_file" ] || { echo "No skills found. Run: git submodule update --init" >&2; exit 1; }
  skill_dir="$(dirname "$skill_file")"
  name="$(basename "$skill_dir")"
  # Two packs with one skill name would silently overwrite each other.
  if [ -e "$build_dir/$name" ]; then
    echo "Two packs both have a skill named $name. Rename one upstream." >&2
    exit 1
  fi
  cp -R "$skill_dir" "$build_dir/$name"
  skill_count=$((skill_count + 1))
done
find "$build_dir" -name __pycache__ -type d -prune -exec rm -rf {} +

if [ "$mode" = "check" ]; then
  if diff -r -x "$marker" -x __pycache__ -x .DS_Store "$build_dir" "$dest" >/dev/null 2>&1; then
    echo "OK       $dest matches skills/ ($skill_count skills)"
    exit 0
  fi
  echo "DIFFERS  $dest does not match skills/. Run scripts/export-skills.sh." >&2
  exit 1
fi

# Only replace a folder this script created, so a wrong --dest can't delete real work.
if [ -d "$dest" ] && [ -n "$(ls -A "$dest")" ] && [ ! -f "$dest/$marker" ]; then
  echo "$dest has files this script didn't create. Refusing to replace it." >&2
  exit 1
fi

touch "$build_dir/$marker"
mkdir -p "$(dirname "$dest")"
rm -rf "$dest"
cp -R "$build_dir" "$dest"
echo "Exported $skill_count skills to $dest"
