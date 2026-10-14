# Сторонние компоненты

Лицензия [PolyForm Noncommercial 1.0.0](LICENSE.md) распространяется только на код Znaika.
Сторонние компоненты остаются под своими лицензиями.

## В репозитории

| Компонент | Где | Лицензия |
|---|---|---|
| LiteRT-LM v0.17.1 (Google), C API — собранная библиотека `libCLiteRTLM_mac.dylib` из релиза, урезанная до arm64 | `packages/litert_lm/macos/litert_lm/CLiteRTLM.xcframework` | Apache 2.0 — [текст](packages/litert_lm/LICENSE-LiteRT-LM) |

## Скачиваются при первом запуске (в репозитории их нет)

| Модель | Лицензия |
|---|---|
| Silero VAD | MIT |
| GigaAM v3 с пунктуацией (Сбер) | MIT |
| 3D-Speaker ERes2Net (VoxCeleb) | Apache 2.0 |
| Gemma 4 E4B / E2B (Google) | Apache 2.0 |
| Qwen3 4B Instruct 2507 (Alibaba) | Apache 2.0 |

## Зависимости Flutter и Dart

Пакеты из `pubspec.yaml` (Flutter, `macos_ui`, `sherpa_onnx`, `drift`, `sqlite3` и другие)
подключаются через pub и распространяются под своими лицензиями (BSD, MIT, Apache 2.0);
полный список с текстами — в пакетах `~/.pub-cache` или на pub.dev.
