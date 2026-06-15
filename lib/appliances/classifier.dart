import 'dart:async';

import '../victron/victron_scanner.dart';
import 'appliance_store.dart';

class ClassificationResult {
  final double totalLoadAmps;        // utjämnad last
  final List<Appliance> activeAppliances;
  final double unexplainedAmps;
  ClassificationResult({
    required this.totalLoadAmps,
    required this.activeAppliances,
    required this.unexplainedAmps,
  });
}

class _Reading {
  final DateTime time;
  final double solarAmps;
  final double shuntCurrent;
  final double voltage;
  _Reading(this.time, this.solarAmps, this.shuntCurrent, this.voltage);
}

class Classifier {
  List<Appliance> _appliances = [];
  final _result = StreamController<ClassificationResult>.broadcast();
  Stream<ClassificationResult> get stream => _result.stream;
  ClassificationResult? _last;
  ClassificationResult? get last => _last;

  // En matchning måste hålla i sig minst så här länge för att räknas
  static const _stableDuration = Duration(seconds: 5);

  // Utjämningsfönster — separat för solar och shunt för att eliminera
  // timing-skillnader mellan BLE-paket
  static const _smoothWindow = Duration(seconds: 10);

  // Bortom maxavstånd från den faktiska lasten räknas ingen matchning alls.
  static const _maxMatchDistance = 0.3; // A

  final Map<int, DateTime> _firstSeen = {};
  final List<_Reading> _history = [];

  StreamSubscription<VictronState>? _sub;

  void setLibrary(List<Appliance> appliances) {
    _appliances = appliances;
  }

  void attachScanner(VictronScanner scanner) {
    _sub?.cancel();
    _sub = scanner.stream.listen(_onState);
  }

  void _onState(VictronState s) {
    final voltage = s.shunt?.batteryVoltage ?? s.solar?.batteryVoltage;
    final shuntCurrent = s.shunt?.current;
    if (voltage == null || voltage.isNaN || voltage <= 0) return;
    if (shuntCurrent == null || shuntCurrent.isNaN) return;
    final solarW = s.solar?.pvPower ?? 0.0;
    final solarAmps = solarW.isNaN ? 0.0 : solarW / voltage;

    final now = DateTime.now();
    _history.add(_Reading(now, solarAmps, shuntCurrent, voltage));
    _history.removeWhere((r) => now.difference(r.time) > _smoothWindow);

    if (_history.isEmpty) return;

    // Utjämna solar och shunt VAR FÖR SIG. Detta är nyckeln: om
    // solar-paket och shunt-paket kommer i otakt blir den momentana
    // load-beräkningen instabil. Genom att jämna ut dem separat över
    // ett gemensamt fönster försvinner timing-mismatch-spikar.
    final n = _history.length.toDouble();
    final smoothSolar =
        _history.map((r) => r.solarAmps).reduce((a, b) => a + b) / n;
    final smoothShunt =
        _history.map((r) => r.shuntCurrent).reduce((a, b) => a + b) / n;
    final smoothedLoad = (smoothSolar - smoothShunt).clamp(0.0, double.infinity);

    final candidates = _bestSubset(smoothedLoad);

    // Stabilitetsfilter — kandidat måste ha matchat i ≥ 5 sek
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
    final unexplained = (smoothedLoad - stableSum).clamp(0.0, double.infinity);

    final result = ClassificationResult(
      totalLoadAmps: smoothedLoad,
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
