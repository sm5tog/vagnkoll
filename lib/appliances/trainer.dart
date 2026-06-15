import 'dart:async';
import 'dart:math';

import '../victron/victron_scanner.dart';
import 'appliance_store.dart';
import 'load_calculator.dart';

enum TrainingPhase {
  idle,
  baseline,     // 3 sek mätning av basström (apparaten av)
  waiting,      // väntar på att apparaten ska slås på (auto-detekt)
  measuring,    // mäter under [duration] sekunder från detekterad start
  done,
  timeout,      // användaren slog aldrig på apparaten
}

class _RecentSample {
  final DateTime time;
  final double load;
  final double shuntCurrent;
  _RecentSample(this.time, this.load, this.shuntCurrent);
}

class TrainingSession {
  final String name;
  final ApplianceCategory category;
  final Duration duration;
  final Duration inrushWindow;
  final Duration baselineDuration;
  final Duration waitTimeout;

  // Trigger när delta ≥ threshold under [confirmSamples] efter varandra
  final double triggerThreshold;

  final List<double> samples = [];
  final List<DateTime> sampleTimes = [];
  final List<double> baselineSamples = [];
  final List<_RecentSample> _waitBuffer = [];

  double? baselineAmps;
  DateTime? baselineStartedAt;
  DateTime? waitingStartedAt;
  DateTime? sampleStartedAt;
  TrainingPhase phase = TrainingPhase.idle;

  TrainingSession({
    required this.name,
    required this.category,
    this.duration = const Duration(seconds: 20),
    this.inrushWindow = const Duration(seconds: 2),
    this.baselineDuration = const Duration(seconds: 3),
    this.waitTimeout = const Duration(seconds: 60),
    this.triggerThreshold = 0.1,
  });

  int get baselineSecondsLeft {
    if (baselineStartedAt == null) return baselineDuration.inSeconds;
    final left = baselineDuration - DateTime.now().difference(baselineStartedAt!);
    return left.inMilliseconds <= 0 ? 0 : (left.inMilliseconds / 1000).ceil();
  }

  bool get isBaselineComplete =>
      baselineStartedAt != null &&
      DateTime.now().difference(baselineStartedAt!) >= baselineDuration;

  bool get isWaitTimedOut =>
      waitingStartedAt != null &&
      DateTime.now().difference(waitingStartedAt!) >= waitTimeout;

  bool get isMeasurementComplete =>
      sampleStartedAt != null &&
      DateTime.now().difference(sampleStartedAt!) >= duration;

  double get measurementProgress {
    if (sampleStartedAt == null) return 0;
    final elapsed = DateTime.now().difference(sampleStartedAt!).inMilliseconds;
    return (elapsed / duration.inMilliseconds).clamp(0.0, 1.0);
  }
}

class Trainer {
  TrainingSession? _session;
  StreamSubscription<VictronState>? _sub;
  Timer? _tick;

  final _events = StreamController<TrainingSession>.broadcast();
  Stream<TrainingSession> get events => _events.stream;

  TrainingSession? get session => _session;

  /// Startar mätningen. Tre faser:
  /// 1. baseline (3s) — mäter basström, apparaten ska vara av
  /// 2. waiting — väntar på att apparaten ska slås på (auto-detekt)
  /// 3. measuring (20s) — börjar i samma stund som ökningen upptäcks
  void start({
    required VictronScanner scanner,
    required String name,
    required ApplianceCategory category,
    Duration duration = const Duration(seconds: 20),
  }) {
    stop();
    _session = TrainingSession(
      name: name,
      category: category,
      duration: duration,
    );

    final s = scanner.current;
    _session!.baselineAmps = LoadCalculator.load(s) ?? 0.0;
    _session!.baselineStartedAt = DateTime.now();
    _session!.phase = TrainingPhase.baseline;

    _sub = scanner.stream.listen(_onState);
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final session = _session;
      if (session == null) return;

      if (session.phase == TrainingPhase.baseline && session.isBaselineComplete) {
        // Lås baseline (medel av samlade samples) och börja vänta
        if (session.baselineSamples.isNotEmpty) {
          session.baselineAmps =
              session.baselineSamples.reduce((a, b) => a + b) /
                  session.baselineSamples.length;
        }
        session.phase = TrainingPhase.waiting;
        session.waitingStartedAt = DateTime.now();
      } else if (session.phase == TrainingPhase.waiting && session.isWaitTimedOut) {
        session.phase = TrainingPhase.timeout;
        _tick?.cancel();
      } else if (session.phase == TrainingPhase.measuring &&
          session.isMeasurementComplete) {
        session.phase = TrainingPhase.done;
        _tick?.cancel();
      }
      _events.add(session);
    });
  }

  void _onState(VictronState s) {
    final session = _session;
    if (session == null) return;

    final load = LoadCalculator.load(s);
    final shuntCurrent = s.shunt?.current;
    if (load == null || shuntCurrent == null || shuntCurrent.isNaN) return;

    if (session.phase == TrainingPhase.baseline) {
      session.baselineSamples.add(load);
    } else if (session.phase == TrainingPhase.waiting) {
      _checkForTrigger(session, load, shuntCurrent);
    } else if (session.phase == TrainingPhase.measuring) {
      final delta = (load - (session.baselineAmps ?? 0))
          .clamp(0.0, double.infinity);
      session.samples.add(delta);
      session.sampleTimes.add(DateTime.now());
    }
  }

  void _checkForTrigger(TrainingSession session, double load, double shunt) {
    final now = DateTime.now();
    session._waitBuffer.add(_RecentSample(now, load, shunt));
    if (session._waitBuffer.length > 4) {
      session._waitBuffer.removeAt(0);
    }
    if (session._waitBuffer.length < 4) return;

    // Medel av äldsta 2 vs nyaste 2
    final olderLoad =
        (session._waitBuffer[0].load + session._waitBuffer[1].load) / 2;
    final newerLoad =
        (session._waitBuffer[2].load + session._waitBuffer[3].load) / 2;
    final olderShunt = (session._waitBuffer[0].shuntCurrent +
            session._waitBuffer[1].shuntCurrent) /
        2;
    final newerShunt = (session._waitBuffer[2].shuntCurrent +
            session._waitBuffer[3].shuntCurrent) /
        2;
    final loadDelta = newerLoad - olderLoad;
    final shuntDelta = newerShunt - olderShunt;

    // Trigger om:
    //   load ökade ≥ tröskeln    (en last har slagits på)
    //   OCH shunt ökade INTE     (annars är det bara mer sol → batteriet laddas mer)
    // En verklig last drar shunt nedåt (mindre laddning eller mer urladdning).
    if (loadDelta >= session.triggerThreshold && shuntDelta <= 0.05) {
      final start = session._waitBuffer[2];
      session.baselineAmps = olderLoad;
      session.phase = TrainingPhase.measuring;
      session.sampleStartedAt = start.time;
      for (var i = 2; i < session._waitBuffer.length; i++) {
        final t = session._waitBuffer[i];
        session.samples
            .add((t.load - olderLoad).clamp(0.0, double.infinity));
        session.sampleTimes.add(t.time);
      }
      session._waitBuffer.clear();
    }
  }

  /// Beräkna signatur och returnera ny Appliance. Returnerar null om
  /// för få mätningar.
  Appliance? finalize() {
    final session = _session;
    if (session == null || session.sampleStartedAt == null) return null;
    final samples = session.samples;
    final times = session.sampleTimes;
    if (samples.length < 5) return null;

    final avg = samples.reduce((a, b) => a + b) / samples.length;
    final mn = samples.reduce(min);
    final mx = samples.reduce(max);
    final variance = samples
            .map((v) => (v - avg) * (v - avg))
            .reduce((a, b) => a + b) /
        samples.length;
    final std = sqrt(variance);

    // Dela upp i inrush-fönster och steady-state
    final inrushEnd = session.sampleStartedAt!.add(session.inrushWindow);
    final steady = <double>[];
    double inrushPeak = 0;
    for (var i = 0; i < samples.length; i++) {
      if (times[i].isBefore(inrushEnd)) {
        if (samples[i] > inrushPeak) inrushPeak = samples[i];
      } else {
        steady.add(samples[i]);
      }
    }

    // Steady-state stats (fallback till hela mätningen om för få samples)
    double steadyAvg;
    double steadyStd;
    if (steady.length >= 3) {
      steadyAvg = steady.reduce((a, b) => a + b) / steady.length;
      final svar = steady
              .map((v) => (v - steadyAvg) * (v - steadyAvg))
              .reduce((a, b) => a + b) /
          steady.length;
      steadyStd = sqrt(svar);
    } else {
      steadyAvg = avg;
      steadyStd = std;
    }
    if (inrushPeak == 0) inrushPeak = mx;

    return Appliance(
      name: session.name,
      category: session.category,
      avgAmps: avg,
      minAmps: mn,
      maxAmps: mx,
      stdAmps: std,
      inrushPeak: inrushPeak,
      steadyAvg: steadyAvg,
      steadyStd: steadyStd,
      sampleCount: samples.length,
      createdAt: DateTime.now(),
    );
  }

  void stop() {
    _sub?.cancel();
    _tick?.cancel();
    _session = null;
  }

  void dispose() {
    stop();
    _events.close();
  }
}
