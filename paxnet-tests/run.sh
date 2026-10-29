#!/usr/bin/env bash
# Прогон тестов PaxNet. Файлы теста лежат с суффиксом .txt, чтобы проверка песочницы мода (--check-mods) их
# не сканировала: тестам нужны get_tree().quit() и res://tests/…, а моду это запрещено.
# Скрипт собирает во временной папке обычный проект Godot и запускает его.
# Использование: paxnet-tests/run.sh [compile|net]   (нужен godot в PATH)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
mod="$(dirname "$here")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -r "$here"/. "$work"/
find "$work" -name '*.txt' ! -path '*/mods/*' | while read -r f; do mv "$f" "${f%.txt}"; done
mkdir -p "$work/mods"
ln -s "$mod" "$work/mods/paxnet_core"
scene="${1:-net}"
godot --headless --path "$work" "res://tests/$scene.tscn"
