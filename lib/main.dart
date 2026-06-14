import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'build_info.dart';
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
  StreamSubscription<VictronState>? _sub;
  VictronState? _state;
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
    _sub = _scanner.stream.listen((s) {
      setState(() {
        _state = s;
        _status = '';
      });
    });
    await _scanner.start();
    setState(() => _status = 'Söker efter Victron…');
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scanner.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shunt = _state?.shunt;
    final solar = _state?.solar;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
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
                  Text('v$kBuildId',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF4B5563),
                      )),
                ],
              ),
              const SizedBox(height: 24),
              Expanded(
                child: shunt == null && solar == null
                    ? _waitingView()
                    : _liveView(shunt, solar),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _waitingView() {
    final s = _state;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: Color(0xFF4ADE80)),
          const SizedBox(height: 24),
          Text(_status,
              style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 16)),
          const SizedBox(height: 32),
          if (s != null) ...[
            Text('BLE-enheter sedda: ${s.totalBleDevicesSeen}',
                style: const TextStyle(color: Color(0xFF6B7280), fontSize: 13)),
            Text('Victron-paket: ${s.victronAdvertsSeen}',
                style: const TextStyle(color: Color(0xFF6B7280), fontSize: 13)),
            Text('Dekrypterings-fel: ${s.decryptFailures} (${s.lastError ?? "-"})',
                style: TextStyle(
                  color: s.decryptFailures > 0
                      ? const Color(0xFFEF4444)
                      : const Color(0xFF6B7280),
                  fontSize: 13,
                )),
            if (s.lastKeyMismatch != null)
              Text('Key-check: ${s.lastKeyMismatch}',
                  style: const TextStyle(color: Color(0xFFEF4444), fontSize: 11)),
            if (s.lastRawHex != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Råa bytes (${s.lastRawLength}b):\n${s.lastRawHex}',
                    style: const TextStyle(color: Color(0xFF4B5563), fontSize: 11)),
              ),
            if (s.lastAllMfgKeys != null)
              Text('Mfg-ID:n: ${s.lastAllMfgKeys}',
                  style: const TextStyle(color: Color(0xFF4B5563), fontSize: 11)),
            const SizedBox(height: 8),
            Text('Förväntar:\n${kVictronDevices.map((d) => '  ${d.mac} (${d.name})').join('\n')}',
                style: const TextStyle(color: Color(0xFF4B5563), fontSize: 10),
                textAlign: TextAlign.left),
          ],
        ],
      ),
    );
  }

  Widget _liveView(shunt, solar) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BigStat(
          label: 'BATTERI',
          value: shunt?.soc.toStringAsFixed(1) ?? '—',
          unit: '%',
          color: _socColor(shunt?.soc),
        ),
        const SizedBox(height: 20),
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
        const SizedBox(height: 12),
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
}

class _BigStat extends StatelessWidget {
  final String label, value, unit;
  final Color color;
  const _BigStat({required this.label, required this.value, required this.unit, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Color(0xFF6B7280), letterSpacing: 2, fontSize: 12)),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, style: TextStyle(fontSize: 72, fontWeight: FontWeight.w200, color: color)),
              const SizedBox(width: 6),
              Text(unit, style: TextStyle(fontSize: 28, color: color.withOpacity(0.7))),
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Color(0xFF6B7280), letterSpacing: 1, fontSize: 11)),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, style: TextStyle(fontSize: 32, fontWeight: FontWeight.w300, color: c)),
              const SizedBox(width: 4),
              Text(unit, style: TextStyle(fontSize: 14, color: c.withOpacity(0.7))),
            ],
          ),
        ],
      ),
    );
  }
}
