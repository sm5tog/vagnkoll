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
          'Stadigt ${a.steadyAvg.toStringAsFixed(2)} A • '
          'Inrush ${a.inrushPeak.toStringAsFixed(2)} A • '
          '${a.cycleCount} cykler',
          style: const TextStyle(color: Color(0xFF6B7280), fontSize: 12),
        ),
        trailing: const Icon(Icons.edit, size: 18, color: Color(0xFF6B7280)),
        onTap: () => _editAppliance(a),
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

  Future<void> _editAppliance(Appliance a) async {
    final action = await showDialog<_EditAction>(
      context: context,
      builder: (_) => _EditDialog(appliance: a),
    );
    if (action == null || !mounted) return;
    if (action.deleted) {
      await widget.store.delete(a.id!);
      return;
    }
    if (action.retrain) {
      // Träna om: starta träningsflödet med samma namn/kategori,
      // och ersätt den gamla efter att den nya sparats.
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _TrainingScreen(
          scanner: widget.scanner,
          store: widget.store,
          spec: _TrainSpec(action.name, action.category),
          replaceExistingId: a.id,
        ),
      ));
    } else {
      // Bara metadata ändrad
      await widget.store.updateMetadata(a.id!, action.name, action.category);
    }
  }
}

class _EditAction {
  final String name;
  final ApplianceCategory category;
  final bool retrain;
  final bool deleted;
  _EditAction({
    required this.name,
    required this.category,
    this.retrain = false,
    this.deleted = false,
  });
}

class _EditDialog extends StatefulWidget {
  final Appliance appliance;
  const _EditDialog({required this.appliance});
  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late TextEditingController _controller;
  late ApplianceCategory _cat;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.appliance.name);
    _cat = widget.appliance.category;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Redigera apparat'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            inputFormatters: [LengthLimitingTextInputFormatter(40)],
            decoration: const InputDecoration(labelText: 'Namn'),
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
                child: Text('Varning'),
              ),
            ],
            onChanged: (v) => setState(() => _cat = v ?? ApplianceCategory.load),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            _EditAction(name: '', category: _cat, deleted: true),
          ),
          child: const Text('RADERA', style: TextStyle(color: Color(0xFFEF4444))),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Avbryt'),
        ),
        OutlinedButton(
          onPressed: () {
            final name = _controller.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(
              context,
              _EditAction(name: name, category: _cat, retrain: true),
            );
          },
          child: const Text('Träna om'),
        ),
        FilledButton(
          onPressed: () {
            final name = _controller.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(context, _EditAction(name: name, category: _cat));
          },
          child: const Text('Spara'),
        ),
      ],
    );
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
  final int? replaceExistingId;
  const _TrainingScreen({
    required this.scanner,
    required this.store,
    required this.spec,
    this.replaceExistingId,
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
      // Timeout hanteras av användaren med "Tillbaka"-knappen i UI:t
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
    // Om vi tränar om: ta bort den gamla först så namn-konflikten löses
    if (widget.replaceExistingId != null) {
      await widget.store.delete(widget.replaceExistingId!);
    }
    await widget.store.insert(a);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        '${a.name} sparad (stadigt ${a.steadyAvg.toStringAsFixed(2)} A, '
        'inrush ${a.inrushPeak.toStringAsFixed(2)} A)',
      ),
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
                'Vi mäter 3 cykler av PÅ och AV. Tryck START och följ instruktionerna. Du slår PÅ och AV apparaten när det står att du ska. Appen detekterar händelserna automatiskt.',
                style: TextStyle(color: Color(0xFF9CA3AF)),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _begin,
                child: const Text('START'),
              ),
            ] else if (session != null) ...[
              if (session.totalCycles > 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'Cykel ${session.currentCycle + 1} av ${session.totalCycles}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFF6B7280), fontSize: 13),
                  ),
                ),
              if (session.phase == TrainingPhase.baseline) ...[
                const Text('Mäter basström…\nApparaten ska vara AV.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 16)),
                const SizedBox(height: 24),
                const Center(child: CircularProgressIndicator()),
              ] else if (session.phase == TrainingPhase.waitingOn) ...[
                const Text('🟡 SLÅ PÅ NU',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFFFBBF24),
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    )),
                const SizedBox(height: 24),
                const Center(child: CircularProgressIndicator()),
              ] else if (session.phase == TrainingPhase.recordingOn) ...[
                const Text('🔴 SPELAR IN PÅ',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFFEF4444),
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    )),
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: session.currentRecording.length /
                      TrainingSession.onLength,
                ),
                const SizedBox(height: 12),
                Text(
                  '${session.currentRecording.length} / ${TrainingSession.onLength} sek',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFF9CA3AF)),
                ),
              ] else if (session.phase == TrainingPhase.waitingForOff) ...[
                const Text('🟡 SLÅ AV NU',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFFFBBF24),
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    )),
                const SizedBox(height: 24),
                const Center(child: CircularProgressIndicator()),
              ] else if (session.phase == TrainingPhase.recordingOff) ...[
                const Text('🔴 SPELAR IN AV',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFFEF4444),
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    )),
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: session.currentRecording.length /
                      TrainingSession.offLength,
                ),
                const SizedBox(height: 12),
                Text(
                  '${session.currentRecording.length} / ${TrainingSession.offLength} sek',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFF9CA3AF)),
                ),
              ] else if (session.phase == TrainingPhase.timeout) ...[
                const Text('⌛ Tidsgräns',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFFEF4444), fontSize: 20)),
                const SizedBox(height: 12),
                const Text('Apparaten slogs aldrig på/av. Försök igen.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF9CA3AF))),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Tillbaka'),
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
