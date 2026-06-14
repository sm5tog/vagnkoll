// Victron Instant Readout BLE-advertisement parser.
//
// Protokollet sänds som manufacturer specific data med Victron prefix 0x02E1.
// Format efter prefix:
//   1 byte:  protocol version (0x10 = Instant Readout v1)
//   1 byte:  model ID
//   1 byte:  read-out type
//   2 bytes: device state nonce (init vector low bytes)
//   1 byte:  first byte of encryption key (för sanity check)
//   N bytes: AES-CTR krypterad payload
//
// Payload-format beror på enhetstyp (shunt / solar) — se record-klasserna.

import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

class VictronAdvert {
  final int modelId;
  final int recordType;
  final Uint8List decryptedPayload;

  VictronAdvert({
    required this.modelId,
    required this.recordType,
    required this.decryptedPayload,
  });
}

class VictronParser {
  static const int kVictronManufacturerId = 0x02E1;

  /// Dekryptera Victron manufacturer data. Returnerar null om data inte
  /// är ett giltigt Victron Instant Readout-paket eller om nyckeln är fel.
  static Future<VictronAdvert?> parse(
    Uint8List manufacturerData,
    String hexKey,
  ) async {
    if (manufacturerData.length < 8) return null;

    final prefix = manufacturerData[0];
    if (prefix != 0x10) return null; // Instant Readout v1

    final modelId = manufacturerData[1] | (manufacturerData[2] << 8);
    final recordType = manufacturerData[3];
    final nonceLow = manufacturerData[4];
    final nonceHigh = manufacturerData[5];
    final keyFirstByte = manufacturerData[6];

    final key = _hexToBytes(hexKey);
    if (key.isEmpty || key[0] != keyFirstByte) return null;

    final ciphertext = manufacturerData.sublist(7);

    // IV: 16 bytes, första 2 bytes = nonce (LSB först), resten = 0
    final iv = Uint8List(16);
    iv[0] = nonceLow;
    iv[1] = nonceHigh;

    final algorithm = AesCtr.with128bits(macAlgorithm: MacAlgorithm.empty);
    final secretKey = SecretKey(key);

    final decrypted = await algorithm.decrypt(
      SecretBox(ciphertext, nonce: iv, mac: Mac.empty),
      secretKey: secretKey,
    );

    return VictronAdvert(
      modelId: modelId,
      recordType: recordType,
      decryptedPayload: Uint8List.fromList(decrypted),
    );
  }

  static Uint8List _hexToBytes(String hex) {
    hex = hex.replaceAll(' ', '').replaceAll(':', '');
    if (hex.length % 2 != 0) return Uint8List(0);
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}

/// Avläsning från en BMV/SmartShunt (record type 0x02 = battery monitor).
class ShuntReading {
  final double batteryVoltage; // V
  final double current;        // A (negativ = ut, positiv = in)
  final double soc;            // %
  final double? consumedAh;    // Ah förbrukad (negativ)
  final int? timeToGoMinutes;  // min kvar
  final int alarmReason;

  ShuntReading({
    required this.batteryVoltage,
    required this.current,
    required this.soc,
    this.consumedAh,
    this.timeToGoMinutes,
    required this.alarmReason,
  });

  static ShuntReading? fromPayload(Uint8List p) {
    if (p.length < 16) return null;
    final bd = ByteData.sublistView(p);
    // Layout enligt Victron docs för BMV-7xx/SmartShunt:
    //  0..1  : time-to-go (uint16, min)
    //  2..3  : battery voltage (int16, 10 mV)
    //  4..5  : alarm reason (uint16)
    //  6..7  : aux voltage (int16, 10 mV) — ignorera
    //  8..10 : consumed Ah (int24, 0.1 Ah)
    //  11..12: SoC (uint16, 0.1 %)
    //  13..15: current (int24, 1 mA)
    final ttg = bd.getUint16(0, Endian.little);
    final voltRaw = bd.getInt16(2, Endian.little);
    final alarm = bd.getUint16(4, Endian.little);
    final ahRaw = _readInt24(p, 8);
    final socRaw = bd.getUint16(11, Endian.little);
    final currentRaw = _readInt24(p, 13);

    return ShuntReading(
      batteryVoltage: voltRaw == 0x7FFF ? double.nan : voltRaw / 100.0,
      current: currentRaw == 0x7FFFFF ? double.nan : currentRaw / 1000.0,
      soc: socRaw == 0xFFFF ? double.nan : socRaw / 10.0,
      consumedAh: ahRaw == 0x7FFFFF ? null : ahRaw / 10.0,
      timeToGoMinutes: ttg == 0xFFFF ? null : ttg,
      alarmReason: alarm,
    );
  }

  static int _readInt24(Uint8List p, int offset) {
    final v = p[offset] | (p[offset + 1] << 8) | (p[offset + 2] << 16);
    return (v & 0x800000) != 0 ? v - 0x1000000 : v;
  }
}

/// Avläsning från en SmartSolar MPPT (record type 0x01 = solar charger).
class SolarReading {
  final int chargeState;       // 0=off, 3=bulk, 4=absorption, 5=float
  final int errorCode;
  final double batteryVoltage; // V
  final double batteryCurrent; // A
  final double yieldTodayWh;   // Wh idag
  final double pvPower;        // W just nu
  final double loadCurrent;    // A (vid load output)

  SolarReading({
    required this.chargeState,
    required this.errorCode,
    required this.batteryVoltage,
    required this.batteryCurrent,
    required this.yieldTodayWh,
    required this.pvPower,
    required this.loadCurrent,
  });

  static SolarReading? fromPayload(Uint8List p) {
    if (p.length < 11) return null;
    final bd = ByteData.sublistView(p);
    //  0   : device state
    //  1   : charger error
    //  2..3: battery voltage (int16, 10 mV)
    //  4..5: battery current (int16, 0.1 A)
    //  6..7: yield today (uint16, 10 Wh)
    //  8..9: pv power (uint16, 1 W)
    //  10  : load current 9-bit packed — förenkla: int8 * 0.1
    final state = p[0];
    final err = p[1];
    final voltRaw = bd.getInt16(2, Endian.little);
    final currRaw = bd.getInt16(4, Endian.little);
    final yieldRaw = bd.getUint16(6, Endian.little);
    final pvRaw = bd.getUint16(8, Endian.little);
    final loadRaw = p[10];

    return SolarReading(
      chargeState: state,
      errorCode: err,
      batteryVoltage: voltRaw == 0x7FFF ? double.nan : voltRaw / 100.0,
      batteryCurrent: currRaw == 0x7FFF ? double.nan : currRaw / 10.0,
      yieldTodayWh: yieldRaw == 0xFFFF ? double.nan : yieldRaw * 10.0,
      pvPower: pvRaw == 0xFFFF ? double.nan : pvRaw.toDouble(),
      loadCurrent: loadRaw == 0xFF ? double.nan : loadRaw / 10.0,
    );
  }

  String get chargeStateName {
    switch (chargeState) {
      case 0: return 'Av';
      case 2: return 'Fel';
      case 3: return 'Bulk';
      case 4: return 'Absorption';
      case 5: return 'Float';
      case 7: return 'Equalize';
      default: return 'Okänt ($chargeState)';
    }
  }
}
