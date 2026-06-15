import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'alarms/alarm_engine.dart';
import 'appliances/appliance_store.dart';
import 'appliances/appliances_screen.dart';
import 'appliances/classifier.dart';
import 'build_info.dart';
import 'energy_counter.dart';
import 'history/history_screen.dart';
import 'history/history_store.dart';
import 'secrets.dart';
import 'victron/victron_scanner.dart';

void main() {
  runApp(const VagnkollApp());
}

class VagnkollApp extends StatelessWidget {
  const VagnkollApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vagnkoll',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0E1A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF4ADE80),
          secondary: Color(0xFFFBBF24),
          surface: Color(0xFF111827),
          error: Color(0xFFEF4444),
        ),
        textTheme: const TextTheme(
          displayLarge: TextStyle(
            fontFeatures: [FontFeature.tabularFigures()],
            fontWeight: FontWeight.w300,
          ),
          displayMedium: TextStyle(
            fontFeatures: [FontFeature.tabularFigures()],
            fontWeight: FontWeight.w300,
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scanner = VictronScanner();
  final _history = HistoryStore();
  final _energy = EnergyCounter();
  final _appliances = ApplianceStore();
  final _classifier = Classifier();
  final _alarms = AlarmEngine();
  StreamSubscription<VictronState>? _sub;
  StreamSubscription<EnergyCounter>? _energySub;
  StreamSubscription<ClassificationResult>? _classSub;
  StreamSubscription<List<Alarm>>? _alarmSub;
  StreamSubscription? _applianceChangesSub;
  VictronState? _state;
  ClassificationResult? _classification;
  List<Alarm> _activeAlarms = [];
  String _status = 'Startar…';

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    _init();
  }

  Future<void> _init() async {
    final perms = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
    if (!perms.values.every((s) => s.isGranted)) {
      setState(() => _status = 'Bluetooth-rättigheter saknas');
      return;
    }
    await _history.open();
    _history.attachScanner(_scanner);
    await _energy.init();
    _energy.attachScanner(_scanner);
    await _appliances.open();
    _classifier.setLibrary(await _appliances.all());
    _classifier.attachScanner(_scanner);
    _alarms.attach(scanner: _scanner, classifier: _classifier);

    _sub = _scanner.stream.listen((s) {
      setState(() {
        _state = s;
        _status = '';
      });
    });
    _energySub = _energy.stream.listen((_) {
      if (mounted) setState(() {});
    });
    _classSub = _classifier.stream.listen((r) {
      _alarms.updateActiveAppliances(r.activeAppliances);
      if (mounted) setState(() => _classification = r);
    });
    _alarmSub = _alarms.stream.listen((a) {
      if (mounted) setState(() => _activeAlarms = a);
    });
    _applianceChangesSub = _appliances.changes.listen((_) async {
      _classifier.setLibrary(await _appliances.all());
    });
    await _scanner.start();
    setState(() => _status = 'Söker efter Victron…');
  }

  @override
  void dispose() {
    _sub?.cancel();
    _energySub?.cancel();
    _classSub?.cancel();
    _alarmSub?.cancel();
    _applianceChangesSub?.cancel();
    _scanner.dispose();
    _history.close();
    _energy.dispose();
    _classifier.dispose();
    _alarms.dispose();
    _appliances.close();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shunt = _state?.shunt;
    final solar = _state?.solar;
    final hasData = shunt != null || solar != null;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('VAGNKOLL',
                      style: TextStyle(
                        letterSpacing: 4,
                        fontSize: 14,
                        color: Color(0xFF6B7280),
                      )),
                  Row(
                    children: [
                      Text('v$kBuildId',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF4B5563),
                          )),
                      const SizedBox(width: 12),
                      IconButton(
                        icon: const Icon(Icons.electrical_services, size: 22),
                        color: const Color(0xFF6B7280),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: _openAppliances,
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.show_chart, size: 22),
                        color: const Color(0xFF6B7280),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: hasData ? _openHistory : null,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: !hasData ? _waitingView() : _liveView(shunt, solar),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openHistory() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => HistoryScreen(store: _history),
    ));
  }

  void _openAppliances() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AppliancesScreen(
        store: _appliances,
        scanner: _scanner,
      ),
    ));
  }

  Widget _waitingView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: Color(0xFF4ADE80)),
          const SizedBox(height: 24),
          Text(_status,
              style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 16)),
        ],
      ),
    );
  }

  Widget _liveView(shunt, solar) {
    // Räkna momentana värden
    final voltage = shunt?.batteryVoltage ?? solar?.batteryVoltage;
    final solarA = (solar != null && voltage != null && voltage > 0)
        ? (solar.pvPower / voltage)
        : null;
    final loadA = (solarA != null && shunt?.current != null)
        ? (solarA - shunt!.current).clamp(0.0, double.infinity)
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BigStat(
          label: 'BATTERI',
          value: shunt?.soc.toStringAsFixed(1) ?? '—',
          unit: '%',
          color: _socColor(shunt?.soc),
          subtitle: shunt?.soc != null
              ? '${(kBatteryCapacityAh * shunt!.soc / 100).toStringAsFixed(1)} Ah kvar'
              : null,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _SmallStat(
                label: 'Spänning',
                value: shunt?.batteryVoltage.toStringAsFixed(2) ?? '—',
                unit: 'V',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _SmallStat(
                label: 'Ström',
                value: shunt?.current.toStringAsFixed(1) ?? '—',
                unit: 'A',
                color: shunt != null
                    ? (shunt.current >= 0
                        ? const Color(0xFF4ADE80)
                        : const Color(0xFFFBBF24))
                    : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _SmallStat(
                label: 'Sol',
                value: solar?.pvPower.toStringAsFixed(0) ?? '—',
                unit: 'W',
                color: const Color(0xFFFBBF24),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _SmallStat(
                label: 'Idag',
                value: solar != null
                    ? (solar.yieldTodayWh / 1000).toStringAsFixed(2)
                    : '—',
                unit: 'kWh',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _SmallStat(
                label: 'Förbrukning',
                value: loadA?.toStringAsFixed(2) ?? '—',
                unit: 'A',
                color: const Color(0xFFEF4444),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _SmallStat(
                label: 'Laddning',
                value: solarA?.toStringAsFixed(2) ?? '—',
                unit: 'A',
                color: const Color(0xFF4ADE80),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _SmallStat(
                label: 'Använt idag',
                value: _energy.usedAhToday.toStringAsFixed(1),
                unit: 'Ah',
                color: const Color(0xFFEF4444),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _SmallStat(
                label: 'Laddat idag',
                value: _energy.solarAhToday.toStringAsFixed(1),
                unit: 'Ah',
                color: const Color(0xFF4ADE80),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ..._activeAlarms.map(_alarmBanner),
        if (_classification != null && _classification!.activeAppliances.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Aktivt nu: ${_classification!.activeAppliances.map((a) => a.name).join(", ")}',
              style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
            ),
          ),
        const Spacer(),
        if (shunt?.timeToGoMinutes != null)
          Text('Tid kvar: ${_formatMinutes(shunt!.timeToGoMinutes!)}',
              style: const TextStyle(color: Color(0xFF9CA3AF))),
        if (solar != null)
          Text('Laddläge: ${solar.chargeStateName}',
              style: const TextStyle(color: Color(0xFF9CA3AF))),
      ],
    );
  }

  Color _socColor(double? soc) {
    if (soc == null) return const Color(0xFF9CA3AF);
    if (soc < kSocCritical) return const Color(0xFFEF4444);
    if (soc < kSocWarn) return const Color(0xFFFBBF24);
    return const Color(0xFF4ADE80);
  }

  String _formatMinutes(int m) {
    final h = m ~/ 60;
    final mm = m % 60;
    return h > 0 ? '${h}h ${mm}m' : '${mm}m';
  }

  Widget _alarmBanner(Alarm a) {
    final c = switch (a.level) {
      AlarmLevel.emergency => const Color(0xFFEF4444),
      AlarmLevel.critical => const Color(0xFFEF4444),
      AlarmLevel.warn => const Color(0xFFFBBF24),
      AlarmLevel.info => const Color(0xFF4ADE80),
    };
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.withOpacity(0.15),
        border: Border.all(color: c, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        a.message,
        style: TextStyle(color: c, fontSize: 13),
      ),
    );
  }
}

class _BigStat extends StatelessWidget {
  final String label, value, unit;
  final Color color;
  final String? subtitle;
  const _BigStat({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Color(0xFF6B7280), letterSpacing: 2, fontSize: 11)),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, style: TextStyle(fontSize: 56, fontWeight: FontWeight.w200, color: color, height: 1.0)),
              const SizedBox(width: 6),
              Text(unit, style: TextStyle(fontSize: 22, color: color.withOpacity(0.7))),
              if (subtitle != null) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(subtitle!,
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 13, color: color.withOpacity(0.7))),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _SmallStat extends StatelessWidget {
  final String label, value, unit;
  final Color? color;
  const _SmallStat({required this.label, required this.value, required this.unit, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.white;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Color(0xFF6B7280), letterSpacing: 1, fontSize: 10)),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w300, color: c, height: 1.0)),
              const SizedBox(width: 4),
              Text(unit, style: TextStyle(fontSize: 12, color: c.withOpacity(0.7))),
            ],
          ),
        ],
      ),
    );
  }
}
