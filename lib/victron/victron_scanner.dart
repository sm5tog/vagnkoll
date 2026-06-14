import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../secrets.dart';
import 'victron_parser.dart';

class VictronState {
  ShuntReading? shunt;
  SolarReading? solar;
  DateTime? shuntUpdated;
  DateTime? solarUpdated;
  // Diagnostik
  int totalBleDevicesSeen = 0;
  int victronAdvertsSeen = 0;
  int decryptFailures = 0;
  final Set<String> seenMacs = {};
  String? lastRawHex;
  String? lastKeyMismatch; // "förväntade XX, fick YY"
  String? lastError;
  String? lastAllMfgKeys; // alla manufacturer-ID:n vi sett
  int lastRawLength = 0;
}

class VictronScanner {
  final _stateController = StreamController<VictronState>.broadcast();
  final _state = VictronState();
  StreamSubscription<List<ScanResult>>? _scanSub;

  Stream<VictronState> get stream => _stateController.stream;
  VictronState get current => _state;

  Future<void> start() async {
    // Lyssna på alla BLE-paket kontinuerligt
    _scanSub = FlutterBluePlus.scanResults.listen(_onScanResults);
    await FlutterBluePlus.startScan(
      continuousUpdates: true,
      removeIfGone: const Duration(seconds: 30),
    );
  }

  Future<void> stop() async {
    await _scanSub?.cancel();
    await FlutterBluePlus.stopScan();
  }

  Future<void> _onScanResults(List<ScanResult> results) async {
    for (final r in results) {
      final mac = r.device.remoteId.str.toUpperCase();
      _state.seenMacs.add(mac);
      _state.totalBleDevicesSeen = _state.seenMacs.length;

      VictronDevice? match;
      for (final d in kVictronDevices) {
        if (d.mac.toUpperCase() == mac) {
          match = d;
          break;
        }
      }
      if (match == null) {
        _stateController.add(_state);
        continue;
      }

      // Logga ALLA mfg-ID vi ser från denna enhet
      final allKeys = r.advertisementData.manufacturerData.keys
          .map((k) => '0x${k.toRadixString(16).padLeft(4, '0')}')
          .join(',');
      _state.lastAllMfgKeys = allKeys;

      // Försök med Victron-ID först, sen alla andra mfg-data
      var mfgData = r.advertisementData.manufacturerData[VictronParser.kVictronManufacturerId];
      if (mfgData == null) {
        // Testa alla mfg-data som börjar med 0x10 (Victron Instant Readout-marker)
        for (final entry in r.advertisementData.manufacturerData.entries) {
          if (entry.value.isNotEmpty && entry.value[0] == 0x10) {
            mfgData = entry.value;
            break;
          }
        }
        if (mfgData == null) continue;
      }
      _state.victronAdvertsSeen++;
      _state.lastRawLength = mfgData.length;

      final result = await VictronParser.parseDetailed(
        Uint8List.fromList(mfgData),
        match.encryptionKey,
      );
      _state.lastRawHex = result.rawHex;
      if (result.error != VictronParseError.ok) {
        _state.decryptFailures++;
        _state.lastError = result.error.name;
        if (result.error == VictronParseError.keyMismatch) {
          final exp = result.expectedKeyByte?.toRadixString(16).padLeft(2, '0');
          final act = result.actualKeyByte?.toRadixString(16).padLeft(2, '0');
          _state.lastKeyMismatch = 'väntade $exp, fick $act';
        }
        _stateController.add(_state);
        continue;
      }
      final advert = result.advert!;

      if (match.kind == 'shunt') {
        final reading = ShuntReading.fromPayload(advert.decryptedPayload);
        if (reading != null) {
          _state.shunt = reading;
          _state.shuntUpdated = DateTime.now();
        }
      } else if (match.kind == 'solar') {
        final reading = SolarReading.fromPayload(advert.decryptedPayload);
        if (reading != null) {
          _state.solar = reading;
          _state.solarUpdated = DateTime.now();
        }
      }
      _stateController.add(_state);
    }
  }

  void dispose() {
    _stateController.close();
    stop();
  }
}
