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

      final mfgData = r.advertisementData.manufacturerData[VictronParser.kVictronManufacturerId];
      if (mfgData == null) continue;
      _state.victronAdvertsSeen++;

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
