import 'dart:async';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

enum ApplianceCategory {
  load,     // vanlig last (lampor, pump, fläkt)
  friendly, // ofarlig glädje (kaffe)
  warn,     // bör inte vara på (golvvärme, kylskåp på 230V)
}

/// En "signatur" består av två vågformer som beskriver apparaten:
///   onTrace  — formen på påslagshändelsen (15 mätpunkter, en per sekund)
///   offTrace — formen på avstängningshändelsen (8 mätpunkter)
///
/// Vågformerna är delta från baseline (subtraherat), så de visar
/// förändringen apparaten orsakar, inte den absoluta lasten.
class Appliance {
  final int? id;
  final String name;
  final ApplianceCategory category;
  final List<double> onTrace;   // delta från baseline (15 samples)
  final List<double> offTrace;  // delta från baseline (8 samples, negativa värden)
  final int cycleCount;          // antal träningscykler som ingår i medel
  final DateTime createdAt;

  // Legacy summary stats (för bakåtkompatibilitet / quick checks)
  double get steadyAvg {
    if (onTrace.length < 5) return 0;
    final tail = onTrace.sublist(5);
    return tail.reduce((a, b) => a + b) / tail.length;
  }

  double get inrushPeak =>
      onTrace.isEmpty ? 0 : onTrace.reduce((a, b) => a > b ? a : b);

  Appliance({
    this.id,
    required this.name,
    required this.category,
    required this.onTrace,
    required this.offTrace,
    required this.cycleCount,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'category': category.name,
        'on_trace': jsonEncode(onTrace),
        'off_trace': jsonEncode(offTrace),
        'cycle_count': cycleCount,
        'created_at': createdAt.millisecondsSinceEpoch ~/ 1000,
      };

  static Appliance fromMap(Map<String, dynamic> m) {
    List<double> parseTrace(String? s) {
      if (s == null || s.isEmpty) return [];
      try {
        return (jsonDecode(s) as List).map((e) => (e as num).toDouble()).toList();
      } catch (_) {
        return [];
      }
    }

    return Appliance(
      id: m['id'] as int?,
      name: m['name'] as String,
      category: ApplianceCategory.values.firstWhere(
        (c) => c.name == m['category'],
        orElse: () => ApplianceCategory.load,
      ),
      onTrace: parseTrace(m['on_trace'] as String?),
      offTrace: parseTrace(m['off_trace'] as String?),
      cycleCount: m['cycle_count'] as int? ?? 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          (m['created_at'] as int) * 1000),
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'category': category.name,
        'on_trace': onTrace,
        'off_trace': offTrace,
        'cycle_count': cycleCount,
        'created_at': createdAt.toIso8601String(),
      };
}

class ApplianceStore {
  Database? _db;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  Future<void> open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'appliances.db');
    _db = await openDatabase(
      path,
      version: 3,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE appliances (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            category TEXT NOT NULL,
            on_trace TEXT NOT NULL DEFAULT '[]',
            off_trace TEXT NOT NULL DEFAULT '[]',
            cycle_count INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 3) {
          // Rensa gamla tabellen — kan inte konvertera summary stats till vågform
          await db.execute('DROP TABLE IF EXISTS appliances');
          await db.execute('''
            CREATE TABLE appliances (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL UNIQUE,
              category TEXT NOT NULL,
              on_trace TEXT NOT NULL DEFAULT '[]',
              off_trace TEXT NOT NULL DEFAULT '[]',
              cycle_count INTEGER NOT NULL DEFAULT 1,
              created_at INTEGER NOT NULL
            )
          ''');
        }
      },
    );
  }

  Future<List<Appliance>> all() async {
    final db = _db;
    if (db == null) return [];
    final rows = await db.query('appliances', orderBy: 'name ASC');
    return rows.map(Appliance.fromMap).toList();
  }

  Future<int> insert(Appliance a) async {
    final db = _db;
    if (db == null) return -1;
    final id = await db.insert(
      'appliances',
      a.toMap()..remove('id'),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _changes.add(null);
    return id;
  }

  Future<void> updateMetadata(int id, String name, ApplianceCategory category) async {
    final db = _db;
    if (db == null) return;
    await db.update(
      'appliances',
      {'name': name, 'category': category.name},
      where: 'id = ?',
      whereArgs: [id],
    );
    _changes.add(null);
  }

  Future<void> delete(int id) async {
    await _db?.delete('appliances', where: 'id = ?', whereArgs: [id]);
    _changes.add(null);
  }

  Future<String> exportJson() async {
    final list = await all();
    return const JsonEncoder.withIndent('  ')
        .convert(list.map((a) => a.toJson()).toList());
  }

  Future<int> importJson(String jsonStr) async {
    final list = jsonDecode(jsonStr) as List;
    var n = 0;
    for (final m in list) {
      final mm = m as Map<String, dynamic>;
      final onT = (mm['on_trace'] as List?)?.map((e) => (e as num).toDouble()).toList() ?? <double>[];
      final offT = (mm['off_trace'] as List?)?.map((e) => (e as num).toDouble()).toList() ?? <double>[];
      await insert(Appliance(
        name: mm['name'] as String,
        category: ApplianceCategory.values.firstWhere(
          (c) => c.name == mm['category'],
          orElse: () => ApplianceCategory.load,
        ),
        onTrace: onT,
        offTrace: offT,
        cycleCount: mm['cycle_count'] as int? ?? 1,
        createdAt: DateTime.tryParse(mm['created_at'] as String) ?? DateTime.now(),
      ));
      n++;
    }
    return n;
  }

  Future<void> close() async {
    await _db?.close();
    await _changes.close();
  }
}
