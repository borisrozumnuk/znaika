#!/bin/zsh
# Релизная сборка Znaika → zip на рабочий стол, чтобы перенести на другой Mac.
#
#   scripts/build_zip.sh          # собрать и упаковать
#   scripts/build_zip.sh --test   # сначала анализатор и тесты
#
# Подпись — Apple Development из macos/Runner/Configs/Signing.local.xcconfig (у автора —
# бесплатный Apple ID), без нотаризации: на другом Mac первый запуск надо разрешить вручную.
# Без своей команды (ad-hoc) скрипт останавливается: такая сборка на другом Mac теряет
# разрешения после каждого обновления.
set -euo pipefail

cd "${0:A:h}/.."
APP=build/macos/Build/Products/Release/Znaika.app

if [[ "${1:-}" == "--test" ]]; then
  echo "→ Анализатор и тесты"
  flutter analyze
  flutter test
fi

echo "→ Сборка"
flutter build macos --release

echo "→ Проверка подписи"
codesign --verify --deep --strict "$APP"
SIGNED_BY=$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=\(Apple Development.*\)/\1/p' | head -1)
if [[ -z "$SIGNED_BY" ]]; then
  echo "⚠️  Сборка не подписана сертификатом Apple Development (ad-hoc?)." >&2
  echo "   Своя команда — в macos/Runner/Configs/Signing.local.xcconfig (см. README, «Установка»);" >&2
  echo "   сертификаты на этом Mac: security find-identity -v -p codesigning" >&2
  exit 1
fi
echo "   $SIGNED_BY"

VERSION=$(sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml)
ZIP="$HOME/Desktop/Znaika-$VERSION-$(date +%Y-%m-%d-%H%M).zip"
echo "→ Упаковка"
# ditto, а не zip: сохраняет подпись, симлинки фреймворков и атрибуты.
ditto -c -k --keepParent "$APP" "$ZIP"

cat <<EOF

Готово: $ZIP ($(du -h "$ZIP" | cut -f1))

На другом Mac (Apple Silicon, macOS 14.2+):
  1. Распаковать и перенести Znaika.app в «Программы».
  2. Первый запуск: «Системные настройки → Конфиденциальность и безопасность →
     Всё равно открыть», или в Терминале:
       xattr -dr com.apple.quarantine /Applications/Znaika.app
  3. Модели (~3,7 ГБ) скачаются при первом запуске. Чтобы не качать, скопируйте папку
     ~/Library/Application Support/local.experiments.znaika/models туда же.
EOF
