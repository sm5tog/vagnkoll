import 'dart:async';

import '../victron/victron_scanner.dart';
import 'appliance_store.dart';
import 'load_calculator.dart';

enum TrainingPhase {
  idle,
  baseline,         // Mäter basström, apparat AV
  waitingOn,        // Väntar på att apparat slås PÅ
  recordingOn,      // Spelar in PÅ-händelsen
  waitingForOff,   // Väntar på att apparat slås AV
  recordingOff,     // Spelar in AV-händelsen
  done,
  timeout,
}

class _Sample {
  final DateTime time;
  final double load;
  _Sample(this.time, this.load);
}

class TrainingSession {
  final String name;
  final ApplianceCategory category;
  final int totalCycles;
  static const int onLength = 15;   // 15 sek inspelning vid PÅ
  static const int offLength = 8;    // 8 sek inspelning vid AV
  static const double triggerThreshold = 0.1; // A delta för att räknas som händelse

  // Per cykel sparas dessa vågformer (delta från baseline)
  final List<List<double>> onTraces = [];
  final List<List<double>> offTraces = [];

  int currentCycle = 0;             // 0..totalCycles-1
  TrainingPhase phase = TrainingPhase.idle;
  DateTime? phaseStartedAt;

  // Rullande buffer för trigger-detektering
  final List<_Sample> _waitBuffer = [];

  // Pågående inspelning
  final List<double> currentRecording = [];
  DateTime? _recordingStartedAt;
  double _recordingBaseline = 0;

  // Baseline (mätt i [baseline]-fasen, uppdaterat löpande)
  double? offStateBaseline;    // load när apparat är AV (cyklens startbaseline)
  double? onStateBaseline;     // load när apparat är PÅ (för off-trigger)

  TrainingSession({
    required this.name,
    required this.category,
    this.totalCycles = 3,
  });

  bool get isFirstCycle => currentCycle == 0;
  bool get isLastCycle => currentCycle == totalCycles - 1;

  Duration get phaseAge => phaseStartedAt == null
      ? Duration.zero
      : DateTime.now().difference(phaseStartedAt!);
}

class Trainer {
  TrainingSession? _session;
  StreamSubscription<VictronState>? _sub;
  Timer? _tick;
  Timer? _captureTimer;

  static const Duration baselineDuration = Duration(seconds: 3);
  static const Duration waitTimeout = Duration(seconds: 60);
  static const Duration interBetweenCycles = Duration(seconds: 2);

  final _events = StreamController<TrainingSession>.broadcast();
  Stream<TrainingSession> get events => _events.stream;

  TrainingSession? get session => _session;
  VictronScanner? _scanner;

  void start({
    required VictronScanner scanner,
    required String name,
    required ApplianceCategory category,
    int cycles = 3,
  }) {
    stop();
    _scanner = scanner;
    _session = TrainingSession(
      name: name,
      category: category,
      totalCycles: cycles,
    );
    _enterPhase(TrainingPhase.baseline);
    _sub = scanner.stream.listen(_onState);
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) => _tickFn());
  }

  void _enterPhase(TrainingPhase phase) {
    final s = _session;
    if (s == null) return;
    s.phase = phase;
    s.phaseStartedAt = DateTime.now();
    s._waitBuffer.clear();
    _captureTimer?.cancel();
    _captureTimer = null;
    _events.add(s);
  }

  void _tickFn() {
    final s = _session;
    if (s == null) return;

    switch (s.phase) {
      case TrainingPhase.baseline:
        if (s.phaseAge >= baselineDuration) {
          // Beräkna offStateBaseline från senaste samplen
          if (s._waitBuffer.isNotEmpty) {
            s.offStateBaseline = s._waitBuffer
                    .map((e) => e.load)
                    .reduce((a, b) => a + b) /
                s._waitBuffer.length;
          } else {
            s.offStateBaseline = 0;
          }
          _enterPhase(TrainingPhase.waitingOn);
        }
        break;

      case TrainingPhase.waitingOn:
      case TrainingPhase.waitingForOff:
        if (s.phaseAge >= waitTimeout) {
          s.phase = TrainingPhase.timeout;
          _tick?.cancel();
          _events.add(s);
        }
        break;

      case TrainingPhase.recordingOn:
        // Hanteras av _captureTimer
        break;
      case TrainingPhase.recordingOff:
        // Hanteras av _captureTimer
        break;
      case TrainingPhase.idle:
      case TrainingPhase.done:
      case TrainingPhase.timeout:
        break;
    }

    _events.add(s);
  }

  void _onState(VictronState st) {
    final s = _session;
    if (s == null) return;

    final load = LoadCalculator.load(st);
    if (load == null) return;

    final now = DateTime.now();
    s._waitBuffer.add(_Sample(now, load));
    // Håll bufferten på max 5 sekunder
    s._waitBuffer.removeWhere((e) => now.difference(e.time).inSeconds > 5);

    switch (s.phase) {
      case TrainingPhase.baseline:
        // Inget mer — _tickFn beräknar offStateBaseline när tid är slut
        break;
      case TrainingPhase.waitingOn:
        _checkOnTrigger(s, load);
        break;
      case TrainingPhase.waitingForOff:
        _checkOffTrigger(s, load);
        break;
      case TrainingPhase.recordingOn:
      case TrainingPhase.recordingOff:
        // Capture-timern sköter sampling
        break;
      default:
        break;
    }
  }

  void _checkOnTrigger(TrainingSession s, double load) {
    final baseline = s.offStateBaseline ?? 0;
    if (s._waitBuffer.length < 3) return;
    // Använd medel av tidigare 2 vs senaste — robust mot enstaka spikar
    final recent = s._waitBuffer.length >= 4
        ? s._waitBuffer.sublist(s._waitBuffer.length - 2)
        : s._waitBuffer.sublist(s._waitBuffer.length - 1);
    final recentAvg = recent.map((e) => e.load).reduce((a, b) => a + b) / recent.length;
    final delta = recentAvg - baseline;
    if (delta >= TrainingSession.triggerThreshold) {
      _startRecording(s, isOn: true);
    }
  }

  void _checkOffTrigger(TrainingSession s, double load) {
    final baseline = s.onStateBaseline ?? 0;
    if (s._waitBuffer.length < 3) return;
    final recent = s._waitBuffer.length >= 4
        ? s._waitBuffer.sublist(s._waitBuffer.length - 2)
        : s._waitBuffer.sublist(s._waitBuffer.length - 1);
    final recentAvg = recent.map((e) => e.load).reduce((a, b) => a + b) / recent.length;
    final delta = baseline - recentAvg;
    if (delta >= TrainingSession.triggerThreshold) {
      _startRecording(s, isOn: false);
    }
  }

  void _startRecording(TrainingSession s, {required bool isOn}) {
    if (isOn) {
      _enterPhase(TrainingPhase.recordingOn);
      s.currentRecording.clear();
      s._recordingStartedAt = DateTime.now();
      s._recordingBaseline = s.offStateBaseline ?? 0;
    } else {
      _enterPhase(TrainingPhase.recordingOff);
      s.currentRecording.clear();
      s._recordingStartedAt = DateTime.now();
      s._recordingBaseline = s.onStateBaseline ?? 0;
    }

    final targetLen = isOn ? TrainingSession.onLength : TrainingSession.offLength;
    _captureTimer?.cancel();
    _captureTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final scanner = _scanner;
      if (scanner == null) return;
      final load = LoadCalculator.load(scanner.current);
      if (load == null) return;
      // Delta från recording-baseline
      s.currentRecording.add(load - s._recordingBaseline);
      if (s.currentRecording.length >= targetLen) {
        _captureTimer?.cancel();
        _finishRecording(s, isOn: isOn);
      }
    });
  }

  void _finishRecording(TrainingSession s, {required bool isOn}) {
    if (isOn) {
      s.onTraces.add(List<double>.from(s.currentRecording));
      // Beräkna onStateBaseline = nuvarande load (apparaten är nu PÅ)
      if (s._waitBuffer.isNotEmpty) {
        final n = s._waitBuffer.length >= 3 ? 3 : s._waitBuffer.length;
        final tail = s._waitBuffer.sublist(s._waitBuffer.length - n);
        s.onStateBaseline =
            tail.map((e) => e.load).reduce((a, b) => a + b) / tail.length;
      }
      _enterPhase(TrainingPhase.waitingForOff);
    } else {
      s.offTraces.add(List<double>.from(s.currentRecording));
      s.currentCycle++;
      if (s.currentCycle >= s.totalCycles) {
        s.phase = TrainingPhase.done;
        _tick?.cancel();
        _events.add(s);
      } else {
        // Nästa cykel — apparat ska vara AV nu (vi nyss spelade in OFF)
        _enterPhase(TrainingPhase.waitingOn);
      }
    }
  }

  /// Slå ihop alla cyklers vågformer till en medel-vågform per riktning.
  Appliance? finalize() {
    final s = _session;
    if (s == null) return null;
    if (s.onTraces.isEmpty || s.offTraces.isEmpty) return null;

    final onAvg = _averageTraces(s.onTraces, TrainingSession.onLength);
    final offAvg = _averageTraces(s.offTraces, TrainingSession.offLength);

    return Appliance(
      name: s.name,
      category: s.category,
      onTrace: onAvg,
      offTrace: offAvg,
      cycleCount: s.totalCycles,
      createdAt: DateTime.now(),
    );
  }

  static List<double> _averageTraces(List<List<double>> traces, int length) {
    final result = List<double>.filled(length, 0.0);
    final counts = List<int>.filled(length, 0);
    for (final t in traces) {
      for (var i = 0; i < t.length && i < length; i++) {
        result[i] += t[i];
        counts[i]++;
      }
    }
    for (var i = 0; i < length; i++) {
      if (counts[i] > 0) result[i] /= counts[i];
    }
    return result;
  }

  void stop() {
    _sub?.cancel();
    _tick?.cancel();
    _captureTimer?.cancel();
    _session = null;
  }

  void dispose() {
    stop();
    _events.close();
  }
}
