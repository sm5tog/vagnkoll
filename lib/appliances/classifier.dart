import 'dart:async';

import '../victron/victron_scanner.dart';
import 'appliance_store.dart';
import 'load_calculator.dart';

/// Vilka apparater appen tror är på just nu, baserat på live-ström.
class ClassificationResult {
  final double totalLoadAmps;
  final List<Appliance> activeAppliances;
  final double unexplainedAmps; // ström som inte kan förklaras av träningsdata
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

  StreamSubscription<VictronState>? _sub;

  /// Min stabilitetstid: en apparat måste matcha minst så här länge innan
  /// vi anser den aktiv. Filtrerar bort kortvariga spikar.
  static const _stableDuration = Duration(seconds: 3);

  final Map<int, DateTime> _firstSeen = {};

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

    // Hitta vilka tränade apparater som matchar nuvarande ström.
    // Vi matchar mot STEADY-state-värdet (efter inrush), eftersom den
    // typiska driften ligger där apparaten är på.
    // Girig algoritm: sortera efter störst steady-ström och bortförklara
    // aktuell last steg för steg.
    final sorted = [..._appliances]..sort((a, b) => b.steadyAvg.compareTo(a.steadyAvg));
    final active = <Appliance>[];
    var remaining = load;
    for (final a in sorted) {
      // Tolerans baserad på spridning i steady-state, med min/max-clamp
      final tol = (a.steadyStd * 2).clamp(0.15, a.steadyAvg * 0.4 + 0.4);
      if (remaining >= a.steadyAvg - tol) {
        active.add(a);
        remaining -= a.steadyAvg;
      }
    }

    // Stabilitetsfilter
    final now = DateTime.now();
    final activeIds = active.map((a) => a.id ?? -1).toSet();
    _firstSeen.removeWhere((id, _) => !activeIds.contains(id));
    final stableActive = <Appliance>[];
    for (final a in active) {
      final id = a.id ?? -1;
      _firstSeen.putIfAbsent(id, () => now);
      if (now.difference(_firstSeen[id]!) >= _stableDuration) {
        stableActive.add(a);
      }
    }

    final result = ClassificationResult(
      totalLoadAmps: load,
      activeAppliances: stableActive,
      unexplainedAmps: remaining < 0 ? 0 : remaining,
    );
    _last = result;
    _result.add(result);
  }

  void dispose() {
    _sub?.cancel();
    _result.close();
  }
}
