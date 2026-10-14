#!/bin/zsh
# Релизная сборка Znaika → zip на рабочий стол, чтобы перенести на другой Mac.
#
#   scripts/build_zip.sh            # собрать и упаковать на рабочий стол
#   scripts/build_zip.sh --test     # сначала анализатор и тесты
#   scripts/build_zip.sh --release  # для GitHub Releases: build/release/Znaika-<версия>.zip,
#                                   # подпись ad-hoc (в сертификате Apple Development — почта
#                                   # Apple ID автора, в публичной сборке её быть не должно)
#
# В архиве — папка Znaika-<версия> с приложением и лицензиями: LICENSE.md (Znaika),
# THIRD_PARTY_NOTICES.md и LICENSE-LiteRT-LM (Apache 2.0 требует распространять её текст
# вместе с библиотекой). Лицензии пакетов Flutter Flutter сам кладёт в приложение (NOTICES).
#
# Подпись — Apple Development из macos/Runner/Configs/Signing.local.xcconfig (у автора —
# бесплатный Apple ID), без нотаризации: на другом Mac первый запуск надо разрешить вручную.
# Без своей команды (ad-hoc) скрипт останавливается: такая сборка на другом Mac теряет
# разрешения после каждого обновления.
set -euo pipefail

cd "${0:A:h}/.."
APP=build/macos/Build/Products/Release/Znaika.app

TEST=0
RELEASE=0
for arg in "$@"; do
  case $arg in
    --test) TEST=1 ;;
    --release) RELEASE=1 ;;
    *) echo "Неизвестный параметр: $arg" >&2; exit 2 ;;
  esac
done

if (( TEST )); then
  echo "→ Анализатор и тесты"
  flutter analyze
  flutter test
fi

echo "→ Сборка"
flutter build macos --release

echo "→ Проверка подписи"
codesign --verify --deep --strict "$APP"
SIGNED_BY=$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=\(Apple Development.*\)/\1/p' | head -1)
if [[ -z "$SIGNED_BY" ]] && (( ! RELEASE )); then
  echo "⚠️  Сборка не подписана сертификатом Apple Development (ad-hoc?)." >&2
  echo "   Своя команда — в macos/Runner/Configs/Signing.local.xcconfig (см. README, «Установка»);" >&2
  echo "   сертификаты на этом Mac: security find-identity -v -p codesigning" >&2
  exit 1
fi
(( RELEASE )) || echo "   $SIGNED_BY"

VERSION=$(sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml)
if (( RELEASE )); then
  mkdir -p build/release
  ZIP="$PWD/build/release/Znaika-$VERSION.zip"
  rm -f "$ZIP"
else
  ZIP="$HOME/Desktop/Znaika-$VERSION-$(date +%Y-%m-%d-%H%M).zip"
fi
echo "→ Упаковка"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
DIR="$STAGE/Znaika-$VERSION"
mkdir -p "$DIR"
# ditto, а не cp/zip: сохраняет подпись, симлинки фреймворков и атрибуты.
ditto "$APP" "$DIR/Znaika.app"
if (( RELEASE )); then
  echo "→ Подпись ad-hoc (без сертификата и почты автора)"
  # Сначала вложенное (библиотеки, фреймворки), потом само приложение; права (микрофон,
  # сеть) и идентификатор сохраняются.
  find "$DIR/Znaika.app/Contents/Frameworks" -depth \( -name "*.dylib" -o -name "*.framework" \) \
    -exec codesign --force --sign - --preserve-metadata=identifier,entitlements,flags {} \;
  # Hardened runtime остаётся (переменные DYLD_* не подсунут чужую библиотеку), но у ad-hoc
  # подписи нет команды, и проверка библиотек отвергла бы собственные dylib приложения
  # («different Team IDs») — для публичной сборки она отключается правом
  # disable-library-validation. У сборок с командой автора проверка библиотек полная.
  ENT="$STAGE/entitlements.plist"
  codesign -d --entitlements - --xml "$APP" > "$ENT" 2>/dev/null
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENT"
  # Право на отладку в публичной сборке не нужно (обычно его и так нет — см. AppInfo.xcconfig).
  /usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$ENT" 2>/dev/null || true
  codesign --force --sign - --options runtime --entitlements "$ENT" --preserve-metadata=identifier \
    "$DIR/Znaika.app"
  codesign --verify --deep --strict "$DIR/Znaika.app"
  if codesign -dv --verbose=2 "$DIR/Znaika.app" 2>&1 | grep -q '^Authority='; then
    echo "⚠️  В подписи остался сертификат" >&2
    exit 1
  fi
fi
cp LICENSE.md THIRD_PARTY_NOTICES.md packages/litert_lm/LICENSE-LiteRT-LM "$DIR/"
ditto -c -k --keepParent "$DIR" "$ZIP"

cat <<EOF

Готово: $ZIP ($(du -h "$ZIP" | cut -f1))

На другом Mac (Apple Silicon, macOS 14.2+):
  1. Распаковать и перенести Znaika.app из папки Znaika-$VERSION в «Программы».
  2. Первый запуск: «Системные настройки → Конфиденциальность и безопасность →
     Всё равно открыть», или в Терминале:
       xattr -dr com.apple.quarantine /Applications/Znaika.app
  3. Модели (~3,7 ГБ) скачаются при первом запуске. Чтобы не качать, скопируйте папку
     ~/Library/Application Support/local.experiments.znaika/models туда же.
EOF
