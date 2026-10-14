# Частые команды Znaika. `make` без цели — релизная сборка.

APP := build/macos/Build/Products/Release/Znaika.app

.PHONY: build run test zip setup-screen clean

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

# Удалить сборки и кэши Flutter (следующая сборка — с нуля, несколько минут).
clean:
	flutter clean
