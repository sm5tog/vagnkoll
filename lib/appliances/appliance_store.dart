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

class Appliance {
  final int? id;
  final String name;
  final ApplianceCategory category;
  final double avgAmps;       // medel över hela mätningen (inkl inrush)
  final double minAmps;
  final double maxAmps;
  final double stdAmps;
  final double inrushPeak;    // max-värde under första 2 sekunderna
  final double steadyAvg;     // medel från sekund 2 och framåt
  final double steadyStd;     // std från sekund 2 och framåt
  final int sampleCount;
  final DateTime createdAt;

  Appliance({
    this.id,
    required this.name,
    required this.category,
    required this.avgAmps,
    required this.minAmps,
    required this.maxAmps,
    required this.stdAmps,
    required this.inrushPeak,
    required this.steadyAvg,
    required this.steadyStd,
    required this.sampleCount,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'category': category.name,
        'avg_amps': avgAmps,
        'min_amps': minAmps,
        'max_amps': maxAmps,
        'std_amps': stdAmps,
        'inrush_peak': inrushPeak,
        'steady_avg': steadyAvg,
        'steady_std': steadyStd,
        'sample_count': sampleCount,
        'created_at': createdAt.millisecondsSinceEpoch ~/ 1000,
      };

  static Appliance fromMap(Map<String, dynamic> m) {
    final avg = (m['avg_amps'] as num).toDouble();
    final mx = (m['max_amps'] as num).toDouble();
    final std = (m['std_amps'] as num).toDouble();
    return Appliance(
      id: m['id'] as int?,
      name: m['name'] as String,
      category: ApplianceCategory.values.firstWhere(
        (c) => c.name == m['category'],
        orElse: () => ApplianceCategory.load,
      ),
      avgAmps: avg,
      minAmps: (m['min_amps'] as num).toDouble(),
      maxAmps: mx,
      stdAmps: std,
      inrushPeak: (m['inrush_peak'] as num?)?.toDouble() ?? mx,
      steadyAvg: (m['steady_avg'] as num?)?.toDouble() ?? avg,
      steadyStd: (m['steady_std'] as num?)?.toDouble() ?? std,
      sampleCount: m['sample_count'] as int,
      createdAt:
          DateTime.fromMillisecondsSinceEpoch((m['created_at'] as int) * 1000),
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'category': category.name,
        'avg_amps': avgAmps,
        'min_amps': minAmps,
        'max_amps': maxAmps,
        'std_amps': stdAmps,
        'inrush_peak': inrushPeak,
        'steady_avg': steadyAvg,
        'steady_std': steadyStd,
        'sample_count': sampleCount,
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
      version: 2,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE appliances (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            category TEXT NOT NULL,
            avg_amps REAL NOT NULL,
            min_amps REAL NOT NULL,
            max_amps REAL NOT NULL,
            std_amps REAL NOT NULL,
            inrush_peak REAL NOT NULL DEFAULT 0,
            steady_avg REAL NOT NULL DEFAULT 0,
            steady_std REAL NOT NULL DEFAULT 0,
            sample_count INTEGER NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          // Lägg till nya kolumner och kopiera värden från befintliga
          await db.execute('ALTER TABLE appliances ADD COLUMN inrush_peak REAL NOT NULL DEFAULT 0');
          await db.execute('ALTER TABLE appliances ADD COLUMN steady_avg REAL NOT NULL DEFAULT 0');
          await db.execute('ALTER TABLE appliances ADD COLUMN steady_std REAL NOT NULL DEFAULT 0');
          await db.rawUpdate(
            'UPDATE appliances SET inrush_peak = max_amps, steady_avg = avg_amps, steady_std = std_amps',
          );
        }
      },
    );
  }

  Future<List<Appliance>> all() async {
    final db = _db;
    if (db == null) return [];
    final rows = await db.query('appliances', orderBy: 'avg_amps ASC');
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
      final avg = (mm['avg_amps'] as num).toDouble();
      final mx = (mm['max_amps'] as num).toDouble();
      final std = (mm['std_amps'] as num).toDouble();
      await insert(Appliance(
        name: mm['name'] as String,
        category: ApplianceCategory.values.firstWhere(
          (c) => c.name == mm['category'],
          orElse: () => ApplianceCategory.load,
        ),
        avgAmps: avg,
        minAmps: (mm['min_amps'] as num).toDouble(),
        maxAmps: mx,
        stdAmps: std,
        inrushPeak: (mm['inrush_peak'] as num?)?.toDouble() ?? mx,
        steadyAvg: (mm['steady_avg'] as num?)?.toDouble() ?? avg,
        steadyStd: (mm['steady_std'] as num?)?.toDouble() ?? std,
        sampleCount: mm['sample_count'] as int,
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
