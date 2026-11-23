#!/usr/bin/env bash
# GitHub Actions (windows-latest, macos-latest): Godot 4.5.1 and its export templates.
# Usage: setup.sh <editor zip name>
set -euo pipefail
GODOT=4.5.1
base=https://github.com/godotengine/godot/releases/download/${GODOT}-stable
mkdir -p "$RUNNER_TEMP/godot" && cd "$RUNNER_TEMP/godot"
curl -fL --retry 8 --retry-all-errors -sS -o editor.zip "$base/$1"
unzip -q editor.zip
for i in $(seq 1 30); do curl -fL -sS -C - -o templates.tpz "$base/Godot_v${GODOT}-stable_export_templates.tpz" && break; sleep 5; done
case "$(uname -s)" in
  Darwin) dir="$HOME/Library/Application Support/Godot/export_templates/${GODOT}.stable"
          bin="$RUNNER_TEMP/godot/Godot.app/Contents/MacOS/Godot"
          files="templates/version.txt templates/macos.zip" ;;
  *)      dir="$APPDATA/Godot/export_templates/${GODOT}.stable"
          bin="$(ls "$RUNNER_TEMP"/godot/Godot_v${GODOT}-stable_win64_console.exe)"
          files="templates/version.txt templates/windows_release_x86_64.exe templates/windows_debug_x86_64.exe templates/windows_release_x86_64_console.exe templates/windows_debug_x86_64_console.exe" ;;
esac
mkdir -p "$dir"
unzip -q -j -o templates.tpz $files -d "$dir"
echo "GODOT_BIN=$bin" >> "$GITHUB_ENV"
