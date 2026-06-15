import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../victron/victron_scanner.dart';
import 'appliance_store.dart';
import 'load_calculator.dart';
import 'trainer.dart';

class AppliancesScreen extends StatefulWidget {
  final ApplianceStore store;
  final VictronScanner scanner;
  const AppliancesScreen({super.key, required this.store, required this.scanner});

  @override
  State<AppliancesScreen> createState() => _AppliancesScreenState();
}

class _AppliancesScreenState extends State<AppliancesScreen> {
  List<Appliance> _appliances = [];
  StreamSubscription? _changeSub;

  @override
  void initState() {
    super.initState();
    _load();
    _changeSub = widget.store.changes.listen((_) => _load());
  }

  Future<void> _load() async {
    final list = await widget.store.all();
    if (!mounted) return;
    setState(() => _appliances = list);
  }

  @override
  void dispose() {
    _changeSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Apparater'),
        backgroundColor: const Color(0xFF111827),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              switch (v) {
                case 'export':
                  _export();
                  break;
                case 'import':
                  _import();
                  break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'export', child: Text('Exportera till fil')),
              PopupMenuItem(value: 'import', child: Text('Importera från fil')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _startTraining,
          ),
        ],
      ),
      body: _appliances.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Inga apparater inlärda än.\n\nTryck + uppe till höger för att lära in din första apparat.',
                  style: TextStyle(color: Color(0xFF9CA3AF)),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              itemCount: _appliances.length,
              itemBuilder: (_, i) => _tile(_appliances[i]),
            ),
    );
  }

  Widget _tile(Appliance a) {
    final color = switch (a.category) {
      ApplianceCategory.warn => const Color(0xFFEF4444),
      ApplianceCategory.friendly => const Color(0xFFFBBF24),
      ApplianceCategory.load => Colors.white,
    };
    final icon = switch (a.category) {
      ApplianceCategory.warn => Icons.warning,
      ApplianceCategory.friendly => Icons.coffee,
      ApplianceCategory.load => Icons.bolt,
    };
    return Dismissible(
      key: ValueKey(a.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        color: const Color(0xFFEF4444),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: const Icon(Icons.delete),
      ),
      onDismissed: (_) => widget.store.delete(a.id!),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(a.name),
        subtitle: Text(
          'Stadigt: ${a.steadyAvg.toStringAsFixed(2)} A '
          '(σ=${a.steadyStd.toStringAsFixed(2)})  •  '
          'Inrush: ${a.inrushPeak.toStringAsFixed(2)} A',
          style: const TextStyle(color: Color(0xFF6B7280), fontSize: 12),
        ),
      ),
    );
  }

  Future<void> _export() async {
    final json = await widget.store.exportJson();
    final bytes = utf8.encode(json);
    final ts = DateTime.now().toIso8601String().substring(0, 16).replaceAll(':', '');
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Spara apparatbibliotek',
      fileName: 'vagnkoll-apparater-$ts.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
      bytes: bytes,
    );
    if (!mounted) return;
    if (path != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Sparade ${_appliances.length} apparater'),
      ));
    }
  }

  Future<void> _import() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    final file = result.files.first;
    String content;
    if (file.bytes != null) {
      content = String.fromCharCodes(file.bytes!);
    } else if (file.path != null) {
      content = await File(file.path!).readAsString();
    } else {
      return;
    }
    try {
      final n = await widget.store.importJson(content);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Importerade $n apparater'),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Fel vid import: $e'),
      ));
    }
  }

  Future<void> _startTraining() async {
    final result = await showDialog<_TrainSpec>(
      context: context,
      builder: (_) => const _TrainDialog(),
    );
    if (result == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _TrainingScreen(
        scanner: widget.scanner,
        store: widget.store,
        spec: result,
      ),
    ));
  }
}

class _TrainSpec {
  final String name;
  final ApplianceCategory category;
  _TrainSpec(this.name, this.category);
}

class _TrainDialog extends StatefulWidget {
  const _TrainDialog();
  @override
  State<_TrainDialog> createState() => _TrainDialogState();
}

class _TrainDialogState extends State<_TrainDialog> {
  final _controller = TextEditingController();
  ApplianceCategory _cat = ApplianceCategory.load;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Lär in apparat'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            inputFormatters: [LengthLimitingTextInputFormatter(40)],
            decoration: const InputDecoration(
              labelText: 'Namn (t.ex. Vattenpump)',
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<ApplianceCategory>(
            value: _cat,
            decoration: const InputDecoration(labelText: 'Typ'),
            items: const [
              DropdownMenuItem(
                value: ApplianceCategory.load,
                child: Text('Vanlig last'),
              ),
              DropdownMenuItem(
                value: ApplianceCategory.friendly,
                child: Text('Glädje (t.ex. kaffe)'),
              ),
              DropdownMenuItem(
                value: ApplianceCategory.warn,
                child: Text('Varning (golvvärme, kylskåp 230V)'),
              ),
            ],
            onChanged: (v) => setState(() => _cat = v ?? ApplianceCategory.load),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Avbryt'),
        ),
        FilledButton(
          onPressed: () {
            final name = _controller.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(context, _TrainSpec(name, _cat));
          },
          child: const Text('Nästa'),
        ),
      ],
    );
  }
}

class _TrainingScreen extends StatefulWidget {
  final VictronScanner scanner;
  final ApplianceStore store;
  final _TrainSpec spec;
  const _TrainingScreen({
    required this.scanner,
    required this.store,
    required this.spec,
  });

  @override
  State<_TrainingScreen> createState() => _TrainingScreenState();
}

class _TrainingScreenState extends State<_TrainingScreen> {
  final _trainer = Trainer();
  StreamSubscription<TrainingSession>? _sub;
  bool _started = false;
  bool _finished = false;
  Timer? _ticker;
  double _liveLoad = 0;
  StreamSubscription<VictronState>? _vSub;

  @override
  void initState() {
    super.initState();
    _vSub = widget.scanner.stream.listen((s) {
      final l = LoadCalculator.load(s);
      if (l != null && mounted) setState(() => _liveLoad = l);
    });
  }

  void _begin() {
    _trainer.start(
      scanner: widget.scanner,
      name: widget.spec.name,
      category: widget.spec.category,
    );
    _sub = _trainer.events.listen((_) {
      if (mounted) setState(() {});
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      setState(() {});
      final s = _trainer.session;
      if (s != null && s.phase == TrainingPhase.done && !_finished) {
        _finished = true;
        _save();
      }
    });
    setState(() => _started = true);
  }

  Future<void> _save() async {
    final a = _trainer.finalize();
    if (a == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('För få mätningar — försök igen.'),
        ));
        Navigator.pop(context);
      }
      return;
    }
    await widget.store.insert(a);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${a.name} sparad (${a.avgAmps.toStringAsFixed(2)} A)'),
    ));
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sub?.cancel();
    _vSub?.cancel();
    _trainer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _trainer.session;
    return Scaffold(
      appBar: AppBar(
        title: Text('Lär: ${widget.spec.name}'),
        backgroundColor: const Color(0xFF111827),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Apparaten ska vara AVSLAGEN nu.',
              style: TextStyle(color: Color(0xFF9CA3AF)),
            ),
            const SizedBox(height: 8),
            Text('Nuvarande last: ${_liveLoad.toStringAsFixed(2)} A',
                style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 24),
            if (!_started) ...[
              const Text(
                'Tryck START. Då räknas det ner 3-2-1, sen ska du slå PÅ apparaten samtidigt som mätningen börjar. Mätningen tar 20 sekunder — håll apparaten på hela tiden.',
                style: TextStyle(color: Color(0xFF9CA3AF)),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _begin,
                child: const Text('START'),
              ),
            ] else if (session != null) ...[
              if (session.phase == TrainingPhase.countdown) ...[
                const Text('Slå PÅ om…',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 18)),
                const SizedBox(height: 16),
                Text(
                  '${session.countdownSecondsLeft}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 120,
                    fontWeight: FontWeight.w200,
                    color: Color(0xFFFBBF24),
                  ),
                ),
              ] else if (session.phase == TrainingPhase.measuring) ...[
                const Text('SLÅ PÅ NU 🔴',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFFEF4444),
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    )),
                const SizedBox(height: 16),
                LinearProgressIndicator(value: session.measurementProgress),
                const SizedBox(height: 16),
                Text(
                  'Mäter… ${session.samples.length} samples',
                  style: const TextStyle(color: Color(0xFF9CA3AF)),
                ),
                const SizedBox(height: 8),
                if (session.samples.isNotEmpty)
                  Text(
                    'Senaste: ${session.samples.last.toStringAsFixed(2)} A',
                    style: const TextStyle(fontSize: 16),
                  ),
              ] else if (session.phase == TrainingPhase.done) ...[
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 16),
                const Text('Sparar…',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF9CA3AF))),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
