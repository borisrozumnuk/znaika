/// Модели, которые приложение скачивает при первом запуске.
///
/// Адреса закреплены на конкретных коммитах Hugging Face (а не на main), суммы
/// SHA-256 сверены с проверенными копиями: если файл в репозитории поменяют,
/// загрузка не пройдёт проверку, а не подсунет неожиданную модель.
library;

class ModelFile {
  /// Путь внутри папки models.
  final String path;
  final String url;
  final int size;
  final String sha256;

  const ModelFile({required this.path, required this.url, required this.size, required this.sha256});
}

class ModelPackage {
  final String id;
  final String title;
  final String description;
  final List<ModelFile> files;

  const ModelPackage({required this.id, required this.title, required this.description, required this.files});

  int get size => files.fold(0, (sum, f) => sum + f.size);
}

const _gigaamDir = 'sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16';
const _gigaamBase =
    'https://huggingface.co/csukuangfj/$_gigaamDir/resolve/a6039be7cee829a9044a69ac0ebaf1c191217c97';

const vadPackage = ModelPackage(
  id: 'vad',
  title: 'Детектор речи',
  description: 'Silero VAD · MIT',
  files: [
    ModelFile(
      path: 'silero_vad.onnx',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx',
      size: 643854,
      sha256: '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
    ),
  ],
);

const asrPackage = ModelPackage(
  id: 'asr',
  title: 'Распознавание речи',
  description: 'GigaAM v3 с пунктуацией (Сбер) · MIT',
  files: [
    ModelFile(
      path: '$_gigaamDir/encoder.int8.onnx',
      url: '$_gigaamBase/encoder.int8.onnx',
      size: 224570820,
      sha256: '369f35a71bf288d3b8e0391fabd8dba5f2314088d440bca474056b7b4b6e66bf',
    ),
    ModelFile(
      path: '$_gigaamDir/decoder.onnx',
      url: '$_gigaamBase/decoder.onnx',
      size: 4600132,
      sha256: '38fc7475443ea2a26f63211ca350f73ac50fff824ab7a3876ee2bd610c53bbc4',
    ),
    ModelFile(
      path: '$_gigaamDir/joiner.onnx',
      url: '$_gigaamBase/joiner.onnx',
      size: 2712896,
      sha256: '602ff7017a93311aad34df1437c8d7f49911353c13d6eae7a6ee7b041339465c',
    ),
    ModelFile(
      path: '$_gigaamDir/tokens.txt',
      url: '$_gigaamBase/tokens.txt',
      size: 13354,
      sha256: '39abae20e692998290c574e606f11a9edef2902a1995463fcff63d1490cf22b7',
    ),
  ],
);

const speakersPackage = ModelPackage(
  id: 'speakers',
  title: 'Различение собеседников',
  description: 'Отпечатки голоса: 3D-Speaker ERes2Net (VoxCeleb) · Apache 2.0',
  files: [
    // Выбрана замером на русской речи (VoxForge RU: 9 дикторов, 199 фраз, пары из разных
    // сессий): EER 1,4% — лучшая среди моделей sherpa-onnx (CAM++ zh+en — 3,2%,
    // TitaNet small — 1,6%, WeSpeaker ResNet34 — 10,8%).
    ModelFile(
      path: '3dspeaker_speech_eres2net_sv_en_voxceleb_16k.onnx',
      url: 'https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/'
          '0743f301363dec56491a490f6d6cbc9d67f9a3bf/3dspeaker_speech_eres2net_sv_en_voxceleb_16k.onnx',
      size: 26485263,
      sha256: 'c59158379255ad66e161679cca6af8d52d51e389e3224ab7d7a7baae295c2db5',
    ),
  ],
);

const llmPackage = ModelPackage(
  id: 'llm',
  title: 'Заметки по встрече',
  description: 'Gemma 4 E4B (Google) · Apache 2.0',
  files: [
    ModelFile(
      path: 'gemma-4-E4B-it.litertlm',
      url: 'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/'
          '2eee7ac325f20eb8c9ac1d0e972f7c84663062da/gemma-4-E4B-it.litertlm',
      size: 3659530240,
      sha256: '0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0',
    ),
  ],
);

/// Обязательные модели, кроме модели для заметок (её выбирают, см. [summaryModels]).
/// Порядок загрузки: маленькие первыми — запись и расшифровка заработают раньше,
/// чем докачается модель для заметок.
const basePackages = [vadPackage, asrPackage, speakersPackage];

/// Модель для заметок на выбор: на экране первого запуска и щелчком по её названию
/// у кнопок окна. Качается выбранная; остальные — по запросу.
class SummaryModel {
  final String name;

  /// Чем отличается — для списка выбора.
  final String note;
  final ModelPackage package;

  const SummaryModel({required this.name, required this.note, required this.package});

  String get id => package.id;
  String get file => package.files.single.path;
}

const gemmaE4b = SummaryModel(
  name: 'Gemma 4 E4B',
  note: 'Подробные и точные заметки. Для Mac с 16 ГБ памяти и больше.',
  package: llmPackage,
);

// Дополнительные выбраны по описаниям (формат .litertlm, ≤ 4 млрд параметров — помещаются
// в 16 ГБ, контекст ≥ 8192, без режима «размышлений»); на русских встречах не проверялись —
// это знание для разработки, в интерфейс оно не выносится.
// Не взяты: Gemma 4 12B (не помещается в 16 ГБ), Qwen3-8B и Qwen3.5 (по умолчанию
// «размышляют» перед ответом), Ministral-3-3B (контекст 4096).
const gemmaE2b = SummaryModel(
  name: 'Gemma 4 E2B',
  note: 'Легче и быстрее, заметки короче. Подойдёт и для Mac с 8 ГБ памяти.',
  package: ModelPackage(
    id: 'llm-gemma-e2b',
    title: 'Gemma 4 E2B',
    description: 'Gemma 4 E2B (Google) · Apache 2.0',
    files: [
      ModelFile(
        path: 'gemma-4-E2B-it.litertlm',
        url: 'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/'
            'b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1/gemma-4-E2B-it.litertlm',
        size: 2588147712,
        sha256: '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c',
      ),
    ],
  ),
);

const qwen3_4b = SummaryModel(
  name: 'Qwen3 4B',
  note: 'Модель от Alibaba, сжатая до 4 бит: компактнее E4B, свой стиль заметок.',
  package: ModelPackage(
    id: 'llm-qwen3-4b',
    title: 'Qwen3 4B',
    description: 'Qwen3-4B-Instruct-2507 (Alibaba) · Apache 2.0',
    files: [
      ModelFile(
        path: 'qwen3_4b_instruct_2507_mixed_int4.litertlm',
        url: 'https://huggingface.co/litert-community/Qwen3-4B-Instruct-2507/resolve/'
            '4d409771b414d86b270ca54d27ffc45032a81142/qwen3_4b_instruct_2507_mixed_int4.litertlm',
        size: 2659057664,
        sha256: '9e48b165836256f5344d9d044930607b9c47f6ef34e27f82e96881664f3ba2fd',
      ),
    ],
  ),
);

const summaryModels = [gemmaE4b, gemmaE2b, qwen3_4b];

/// Рекомендованная модель для этого Mac по объёму памяти: E4B во float32 занимает
/// около 4 ГБ, на 8 ГБ вместе с системой, расшифровкой и браузером ей тесно.
SummaryModel recommendedSummaryModel(int memoryBytes) =>
    memoryBytes >= 15 * 1000 * 1000 * 1000 ? gemmaE4b : gemmaE2b;

/// Все пакеты, о которых знает ModelManager.
final allPackages = [...basePackages, for (final m in summaryModels) m.package];
