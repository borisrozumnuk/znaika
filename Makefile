# Частые команды Znaika. `make` без цели — релизная сборка.

APP := build/macos/Build/Products/Release/Znaika.app

.PHONY: build run test zip setup-screen screenshots clean

# Релизная сборка (подписана Apple Development, см. README).
build:
	flutter build macos --release

# Собрать и открыть.
run: build
	open $(APP)

# Анализатор и тесты.
test:
	flutter analyze
	flutter test

# Сборка, проверка подписи и zip на рабочий стол — для другого Mac.
zip:
	scripts/build_zip.sh

# Экран первого запуска, даже если модели уже скачаны (отдельным окном).
setup-screen: build
	open -n --env ZNAIKA_SHOW_SETUP=1 $(APP)

# Скриншоты для README (docs/screenshots, светлые и тёмные) — из настоящего интерфейса
# на вымышленных встречах.
# Затем сжатие pngquant (меньше цветов, на глаз без разницы; `brew install pngquant`);
# без него остаются несжатые.
screenshots:
	ZNAIKA_SCREENSHOTS=1 flutter test test/readme_screenshots_test.dart
	@if command -v pngquant >/dev/null; then \
		pngquant --quality 80-95 --strip --skip-if-larger --force --ext .png docs/screenshots/*.png; \
		du -ch docs/screenshots/*.png | tail -1; \
	else \
		echo "pngquant не установлен — скриншоты не сжаты (brew install pngquant)"; \
	fi

# Удалить сборки и кэши Flutter (следующая сборка — с нуля, несколько минут).
clean:
	flutter clean
