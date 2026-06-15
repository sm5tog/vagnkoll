import 'dart:async';

import '../victron/victron_scanner.dart';
import 'appliance_store.dart';
import 'load_calculator.dart';

class ClassificationResult {
  final double totalLoadAmps;        // utjämnad last (last 5 sek)
  final List<Appliance> activeAppliances;
  final double unexplainedAmps;
  ClassificationResult({
    required this.totalLoadAmps,
    required this.activeAppliances,
    required this.unexplainedAmps,
  });
}

class Classifier {
  List<Appliance> _appliances = [];
  final _result = StreamController<ClassificationResult>.broadcast();
  Stream<ClassificationResult> get stream => _result.stream;
  ClassificationResult? _last;
  ClassificationResult? get last => _last;

  // Stabilitetskrav: matchningen måste hålla i sig minst så här länge.
  static const _stableDuration = Duration(seconds: 3);

  // Utjämningsfönster — medel av senaste samplen för att dämpa BLE-timing-brus.
  static const _smoothWindow = Duration(seconds: 5);

  // Bortom maxavstånd från den faktiska lasten räknas ingen matchning alls.
  static const _maxMatchDistance = 0.3; // A

  final Map<int, DateTime> _firstSeen = {};
  final List<MapEntry<DateTime, double>> _loadHistory = [];

  StreamSubscription<VictronState>? _sub;

  void setLibrary(List<Appliance> appliances) {
    _appliances = appliances;
  }

  void attachScanner(VictronScanner scanner) {
    _sub?.cancel();
    _sub = scanner.stream.listen(_onState);
  }

  void _onState(VictronState s) {
    final load = LoadCalculator.load(s);
    if (load == null) return;

    final now = DateTime.now();
    _loadHistory.add(MapEntry(now, load));
    _loadHistory.removeWhere((e) => now.difference(e.key) > _smoothWindow);

    // Utjämnad last = medel av senaste 5 sek
    final smoothed = _loadHistory.isEmpty
        ? load
        : _loadHistory.map((e) => e.value).reduce((a, b) => a + b) /
            _loadHistory.length;

    final candidates = _bestSubset(smoothed);

    // Stabilitetsfilter — kandidat måste ha matchat i ≥ 3 sek
    final candidateIds = candidates.map((a) => a.id ?? -1).toSet();
    _firstSeen.removeWhere((id, _) => !candidateIds.contains(id));
    final stable = <Appliance>[];
    for (final a in candidates) {
      final id = a.id ?? -1;
      _firstSeen.putIfAbsent(id, () => now);
      if (now.difference(_firstSeen[id]!) >= _stableDuration) {
        stable.add(a);
      }
    }

    final stableSum = stable.fold<double>(0, (s, a) => s + a.steadyAvg);
    final unexplained = (smoothed - stableSum).clamp(0.0, double.infinity);

    final result = ClassificationResult(
      totalLoadAmps: smoothed,
      activeAppliances: stable,
      unexplainedAmps: unexplained,
    );
    _last = result;
    _result.add(result);
  }

  /// Provar alla delmängder av apparater och returnerar den vars summa
  /// är närmast den faktiska lasten — inom [_maxMatchDistance].
  List<Appliance> _bestSubset(double load) {
    final n = _appliances.length;
    if (n == 0) return const [];
    if (n > 12) {
      // För många apparater för exhaustiv sökning — fall tillbaka på girig
      return _greedyFallback(load);
    }
    final total = 1 << n;
    List<Appliance>? best;
    double bestDist = double.infinity;
    for (var mask = 0; mask < total; mask++) {
      double sum = 0;
      final subset = <Appliance>[];
      for (var i = 0; i < n; i++) {
        if ((mask >> i) & 1 == 1) {
          sum += _appliances[i].steadyAvg;
          subset.add(_appliances[i]);
        }
      }
      final dist = (sum - load).abs();
      if (dist < bestDist) {
        bestDist = dist;
        best = subset;
      }
    }
    if (bestDist > _maxMatchDistance) return const [];
    return best ?? const [];
  }

  List<Appliance> _greedyFallback(double load) {
    final sorted = [..._appliances]
      ..sort((a, b) => b.steadyAvg.compareTo(a.steadyAvg));
    final active = <Appliance>[];
    var remaining = load;
    for (final a in sorted) {
      if (remaining >= a.steadyAvg - 0.15) {
        active.add(a);
        remaining -= a.steadyAvg;
      }
    }
    return active;
  }

  void dispose() {
    _sub?.cancel();
    _result.close();
  }
}
