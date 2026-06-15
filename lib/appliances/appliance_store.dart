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
  final double avgAmps;
  final double minAmps;
  final double maxAmps;
  final double stdAmps;
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
        'sample_count': sampleCount,
        'created_at': createdAt.millisecondsSinceEpoch ~/ 1000,
      };

  static Appliance fromMap(Map<String, dynamic> m) => Appliance(
        id: m['id'] as int?,
        name: m['name'] as String,
        category: ApplianceCategory.values.firstWhere(
          (c) => c.name == m['category'],
          orElse: () => ApplianceCategory.load,
        ),
        avgAmps: (m['avg_amps'] as num).toDouble(),
        minAmps: (m['min_amps'] as num).toDouble(),
        maxAmps: (m['max_amps'] as num).toDouble(),
        stdAmps: (m['std_amps'] as num).toDouble(),
        sampleCount: m['sample_count'] as int,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch((m['created_at'] as int) * 1000),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'category': category.name,
        'avg_amps': avgAmps,
        'min_amps': minAmps,
        'max_amps': maxAmps,
        'std_amps': stdAmps,
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
      version: 1,
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
            sample_count INTEGER NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
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
      await insert(Appliance(
        name: mm['name'] as String,
        category: ApplianceCategory.values.firstWhere(
          (c) => c.name == mm['category'],
          orElse: () => ApplianceCategory.load,
        ),
        avgAmps: (mm['avg_amps'] as num).toDouble(),
        minAmps: (mm['min_amps'] as num).toDouble(),
        maxAmps: (mm['max_amps'] as num).toDouble(),
        stdAmps: (mm['std_amps'] as num).toDouble(),
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
