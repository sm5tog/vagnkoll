import 'dart:async';
import 'dart:math';

import '../victron/victron_scanner.dart';
import 'appliance_store.dart';
import 'load_calculator.dart';

enum TrainingPhase {
  idle,
  countdown,    // 3-2-1 nedräkning innan apparat slås på
  measuring,    // mäter under [duration] sekunder
  done,
}

class TrainingSession {
  final String name;
  final ApplianceCategory category;
  final Duration duration;
  final Duration inrushWindow;
  final List<double> samples = [];
  final List<DateTime> sampleTimes = [];
  double? baselineAmps;
  DateTime? countdownStartedAt;
  DateTime? sampleStartedAt;
  TrainingPhase phase = TrainingPhase.idle;

  TrainingSession({
    required this.name,
    required this.category,
    this.duration = const Duration(seconds: 20),
    this.inrushWindow = const Duration(seconds: 2),
  });

  /// 3 sekunder nedräkning innan mätning startar
  Duration get countdownDuration => const Duration(seconds: 3);

  int get countdownSecondsLeft {
    if (countdownStartedAt == null) return 3;
    final elapsed = DateTime.now().difference(countdownStartedAt!);
    final left = countdownDuration - elapsed;
    return left.inMilliseconds <= 0 ? 0 : (left.inMilliseconds / 1000).ceil();
  }

  bool get isCountdownComplete =>
      countdownStartedAt != null &&
      DateTime.now().difference(countdownStartedAt!) >= countdownDuration;

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

  /// Startar nedräkning. Användaren ska SLÅ PÅ apparaten vid 0.
  /// Vi mäter baseline under nedräkningen.
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
    _session!.countdownStartedAt = DateTime.now();
    _session!.phase = TrainingPhase.countdown;

    _sub = scanner.stream.listen(_onState);
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final session = _session;
      if (session == null) return;
      if (session.phase == TrainingPhase.countdown && session.isCountdownComplete) {
        // Övergå till mätning
        session.phase = TrainingPhase.measuring;
        session.sampleStartedAt = DateTime.now();
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
    if (load == null) return;

    if (session.phase == TrainingPhase.countdown) {
      // Uppdatera baseline löpande under nedräkningen
      session.baselineAmps = load;
    } else if (session.phase == TrainingPhase.measuring) {
      final delta = (load - (session.baselineAmps ?? 0))
          .clamp(0.0, double.infinity);
      session.samples.add(delta);
      session.sampleTimes.add(DateTime.now());
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
