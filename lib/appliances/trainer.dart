import 'dart:async';
import 'dart:math';

import '../victron/victron_scanner.dart';
import 'appliance_store.dart';
import 'load_calculator.dart';

class TrainingSession {
  final String name;
  final ApplianceCategory category;
  final Duration duration;
  final List<double> samples = [];
  final List<DateTime> sampleTimes = [];
  double? baselineAmps;
  DateTime? startedAt;

  TrainingSession({
    required this.name,
    required this.category,
    this.duration = const Duration(seconds: 20),
  });

  bool get isComplete =>
      startedAt != null &&
      DateTime.now().difference(startedAt!) >= duration;

  double get progress {
    if (startedAt == null) return 0;
    final elapsed = DateTime.now().difference(startedAt!).inMilliseconds;
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

  /// Kör först några sekunder för att mäta bakgrundsström (innan apparaten
  /// slås på). Användaren ska INTE ha apparaten på då.
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

    // Använd nuvarande last som baseline
    final s = scanner.current;
    _session!.baselineAmps = LoadCalculator.load(s) ?? 0.0;
    _session!.startedAt = DateTime.now();

    _sub = scanner.stream.listen(_onState);
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_session == null) return;
      _events.add(_session!);
      if (_session!.isComplete) {
        _tick?.cancel();
      }
    });
  }

  void _onState(VictronState s) {
    final session = _session;
    if (session == null || session.startedAt == null) return;
    if (session.isComplete) return;

    final load = LoadCalculator.load(s);
    if (load == null) return;

    // Subtrahera baseline för att få "extra" ström apparaten drar
    final delta = (load - (session.baselineAmps ?? 0)).clamp(0.0, double.infinity);
    session.samples.add(delta);
    session.sampleTimes.add(DateTime.now());
  }

  /// Beräkna signatur och returnera ny Appliance. Returnerar null om
  /// för få mätningar.
  Appliance? finalize() {
    final session = _session;
    if (session == null) return null;
    final samples = session.samples;
    if (samples.length < 3) return null;

    final avg = samples.reduce((a, b) => a + b) / samples.length;
    final mn = samples.reduce(min);
    final mx = samples.reduce(max);
    final variance = samples
            .map((v) => (v - avg) * (v - avg))
            .reduce((a, b) => a + b) /
        samples.length;
    final std = sqrt(variance);

    return Appliance(
      name: session.name,
      category: session.category,
      avgAmps: avg,
      minAmps: mn,
      maxAmps: mx,
      stdAmps: std,
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
