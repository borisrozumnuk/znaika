import 'dart:math' as math;
import 'dart:typed_data';

/// Различение собеседников по голосу на лету.
///
/// Каждая законченная реплика канала собеседников даёт «отпечаток голоса»
/// (speaker embedding, ERes2Net). Отпечаток сравнивается с уже известными голосами
/// по косинусному сходству: похож — тот же собеседник (его усреднённый отпечаток
/// уточняется), не похож — новый собеседник. Короткие реплики («да», «угу»)
/// дают ненадёжный отпечаток: их приписываем ближайшему голосу, новый не заводим.
///
/// На длинной встрече часть фраз (смех, перебивания, сжатый звук созвона) даёт
/// отпечаток, не похожий ни на один голос, и появляются «собеседники» на пару фраз:
/// на 89-минутном созвоне 7 человек их набралось 49. После встречи [consolidated]
/// сливает такие голоса с ближайшими настоящими.
class SpeakerClusters {
  SpeakerClusters({this.sameSpeakerThreshold = 0.5, this.minSecondsForNewSpeaker = 1.5});

  /// Сходство, начиная с которого реплика считается тем же голосом.
  final double sameSpeakerThreshold;

  /// Реплики короче этого не заводят нового собеседника.
  final double minSecondsForNewSpeaker;

  final _centroids = <Float32List>[];
  final _counts = <int>[];

  /// Сколько секунд речи у каждого голоса.
  final _seconds = <double>[];

  int get count => _centroids.length;

  /// Номер голоса последней реплики — для фраз, слишком коротких для отпечатка.
  int lastAssigned = 0;

  /// Номер собеседника (с нуля) для реплики длиной [seconds].
  int assign(Float32List embedding, double seconds) {
    lastAssigned = _assign(embedding, seconds);
    _seconds[lastAssigned] += seconds;
    return lastAssigned;
  }

  /// Фраза без отпечатка (слишком короткая) отдана голосу [index].
  void addSeconds(int index, double seconds) {
    if (index < _seconds.length) _seconds[index] += seconds;
  }

  /// Итоговый номер для каждого голоса после встречи: голоса, у которых меньше
  /// [minShare] всей речи (и меньше [maxMinorSeconds]), сливаются с ближайшим
  /// по отпечатку крупным голосом. Только если речи не меньше [minTotalSeconds]:
  /// на короткой встрече тихий участник с парой фраз — скорее настоящий человек
  /// (на русских дикторах VoxForge слияние там только ухудшает результат).
  List<int> consolidated({double minTotalSeconds = 300, double minShare = 0.02, double maxMinorSeconds = 60}) {
    final identity = List.generate(count, (i) => i);
    final total = _seconds.fold(0.0, (a, b) => a + b);
    if (total < minTotalSeconds) return identity;
    final limit = math.min(maxMinorSeconds, minShare * total);
    final major = [for (var i = 0; i < count; i++) if (_seconds[i] >= limit) i];
    if (major.isEmpty) return identity;
    return [
      for (var i = 0; i < count; i++)
        _seconds[i] >= limit ? i : major.reduce((a, b) => _dot(_centroids[i], _centroids[a]) >= _dot(_centroids[i], _centroids[b]) ? a : b),
    ];
  }

  int _assign(Float32List embedding, double seconds) {
    final v = _normalized(embedding);
    var best = -1;
    var bestScore = -2.0;
    for (var i = 0; i < _centroids.length; i++) {
      final score = _dot(v, _centroids[i]);
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    if (best >= 0 && bestScore >= sameSpeakerThreshold) {
      _update(best, v);
      return best;
    }
    if (best >= 0 && seconds < minSecondsForNewSpeaker) return best;
    _centroids.add(v);
    _counts.add(1);
    _seconds.add(0);
    return _centroids.length - 1;
  }

  /// Скользящее среднее нормированных отпечатков, снова нормированное.
  void _update(int i, Float32List v) {
    final c = _centroids[i];
    final n = _counts[i];
    for (var k = 0; k < c.length; k++) {
      c[k] = (c[k] * n + v[k]) / (n + 1);
    }
    _centroids[i] = _normalized(c);
    _counts[i] = n + 1;
  }

  static double _dot(Float32List a, Float32List b) {
    var sum = 0.0;
    for (var k = 0; k < a.length; k++) {
      sum += a[k] * b[k];
    }
    return sum;
  }

  static Float32List _normalized(Float32List v) {
    var norm = 0.0;
    for (final x in v) {
      norm += x * x;
    }
    norm = math.sqrt(norm);
    final out = Float32List(v.length);
    if (norm == 0) return out;
    for (var k = 0; k < v.length; k++) {
      out[k] = v[k] / norm;
    }
    return out;
  }
}
