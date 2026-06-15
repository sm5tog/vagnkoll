import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../victron/victron_scanner.dart';
import 'appliance_store.dart';
import 'load_calculator.dart';

class ClassificationResult {
  final double totalLoadAmps;
  final List<Appliance> activeAppliances;
  ClassificationResult({
    required this.totalLoadAmps,
    required this.activeAppliances,
  });
}

class _Reading {
  final DateTime time;
  final double load;
  _Reading(this.time, this.load);
}

/// Event-baserad klassificerare. Bevakar shunt-strömmen, detekterar
/// plötsliga händelser (apparat slås på / av), spelar in vågformen
/// och korrelerar mot inlärda signaturer.
class Classifier {
  static const String _prefsKey = 'classifier_active_v1';

  // Trigger-tröskel för händelsedetektering
  static const double _triggerThreshold = 0.1;

  // Hur lång live-inspelning för matchning
  static const int _liveOnLength = 10;   // 10 sek
  static const int _liveOffLength = 6;    // 6 sek

  // Korrelations-tröskel för match
  static const double _matchThreshold = 0.75;

  // Hur länge bibehållna i live-bufferten innan en händelse kan upptäckas
  static const Duration _bufferWindow = Duration(seconds: 5);

  List<Appliance> _appliances = [];
  final Set<int> _activeIds = {};
  final _result = StreamController<ClassificationResult>.broadcast();
  Stream<ClassificationResult> get stream => _result.stream;
  ClassificationResult? _last;
  ClassificationResult? get last => _last;

  bool _paused = false;
  final List<_Reading> _history = [];
  bool _isRecording = false;
  bool _recordingIsOn = true;
  final List<double> _liveTrace = [];
  double _recordBaseline = 0;
  Timer? _recordTimer;

  SharedPreferences? _prefs;
  StreamSubscription<VictronState>? _sub;
  VictronScanner? _scanner;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final stored = _prefs?.getString(_prefsKey);
    if (stored != null) {
      try {
        final list = jsonDecode(stored) as List;
        _activeIds.addAll(list.map((e) => e as int));
      } catch (_) {}
    }
  }

  void setLibrary(List<Appliance> appliances) {
    _appliances = appliances;
    // Ta bort aktiva som inte längre finns
    final validIds = appliances.map((a) => a.id ?? -1).toSet();
    _activeIds.removeWhere((id) => !validIds.contains(id));
    _persist();
    _emit();
  }

  void attachScanner(VictronScanner scanner) {
    _scanner = scanner;
    _sub?.cancel();
    _sub = scanner.stream.listen(_onState);
  }

  /// Pausar klassificering (t.ex. under träning, för att frigöra CPU).
  void pause() {
    _paused = true;
    _recordTimer?.cancel();
    _isRecording = false;
    _history.clear();
  }

  void resume() {
    _paused = false;
  }

  void _onState(VictronState s) {
    if (_paused) return;

    final load = LoadCalculator.load(s);
    if (load == null) return;

    final now = DateTime.now();
    _history.add(_Reading(now, load));
    _history.removeWhere((r) => now.difference(r.time) > _bufferWindow);

    if (!_isRecording) {
      _checkForEvent();
    }
  }

  void _checkForEvent() {
    if (_history.length < 4) return;
    // Senaste 2 vs tidigare 2
    final n = _history.length;
    final older = _history.sublist(n - 4, n - 2);
    final newer = _history.sublist(n - 2);
    final olderAvg = older.map((r) => r.load).reduce((a, b) => a + b) / 2;
    final newerAvg = newer.map((r) => r.load).reduce((a, b) => a + b) / 2;
    final delta = newerAvg - olderAvg;

    if (delta >= _triggerThreshold) {
      _beginRecording(isOn: true, baseline: olderAvg);
    } else if (delta <= -_triggerThreshold) {
      _beginRecording(isOn: false, baseline: olderAvg);
    }
  }

  void _beginRecording({required bool isOn, required double baseline}) {
    _isRecording = true;
    _recordingIsOn = isOn;
    _recordBaseline = baseline;
    _liveTrace.clear();
    // Lägg in nuvarande senaste 2 samples som start
    if (_history.length >= 2) {
      _liveTrace.add(_history[_history.length - 2].load - baseline);
      _liveTrace.add(_history[_history.length - 1].load - baseline);
    }

    final targetLen = isOn ? _liveOnLength : _liveOffLength;
    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final scanner = _scanner;
      if (scanner == null) {
        _recordTimer?.cancel();
        _isRecording = false;
        return;
      }
      final load = LoadCalculator.load(scanner.current);
      if (load == null) return;
      _liveTrace.add(load - _recordBaseline);
      if (_liveTrace.length >= targetLen) {
        _recordTimer?.cancel();
        _finishRecording();
      }
    });
  }

  void _finishRecording() {
    _isRecording = false;

    // Hitta bästa matchning
    Appliance? best;
    double bestScore = -2;
    for (final a in _appliances) {
      final stored = _recordingIsOn ? a.onTrace : a.offTrace;
      if (stored.length < 3 || _liveTrace.length < 3) continue;
      // Jämför över så många samples som båda har
      final len = stored.length < _liveTrace.length
          ? stored.length
          : _liveTrace.length;
      final score = _pearson(
        stored.sublist(0, len),
        _liveTrace.sublist(0, len),
      );
      if (score > bestScore) {
        bestScore = score;
        best = a;
      }
    }

    if (best != null && bestScore >= _matchThreshold && best.id != null) {
      bool changed = false;
      if (_recordingIsOn) {
        changed = _activeIds.add(best.id!);
      } else {
        changed = _activeIds.remove(best.id!);
      }
      if (changed) {
        _persist();
        _emit();
      }
    }
  }

  void _persist() {
    _prefs?.setString(_prefsKey, jsonEncode(_activeIds.toList()));
  }

  void _emit() {
    final last = _history.isNotEmpty ? _history.last.load : 0.0;
    final active = _appliances.where((a) => _activeIds.contains(a.id)).toList();
    final result = ClassificationResult(
      totalLoadAmps: last,
      activeAppliances: active,
    );
    _last = result;
    _result.add(result);
  }

  /// Pearson-korrelation: värde mellan -1 och 1, där 1 = perfekt match.
  static double _pearson(List<double> x, List<double> y) {
    if (x.length != y.length || x.isEmpty) return 0;
    final n = x.length;
    double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0, sumY2 = 0;
    for (var i = 0; i < n; i++) {
      sumX += x[i];
      sumY += y[i];
      sumXY += x[i] * y[i];
      sumX2 += x[i] * x[i];
      sumY2 += y[i] * y[i];
    }
    final num_ = n * sumXY - sumX * sumY;
    final den2 = (n * sumX2 - sumX * sumX) * (n * sumY2 - sumY * sumY);
    if (den2 <= 0) return 0;
    return num_ / sqrt(den2);
  }

  void dispose() {
    _sub?.cancel();
    _recordTimer?.cancel();
    _result.close();
  }
}
