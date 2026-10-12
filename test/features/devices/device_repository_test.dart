import 'dart:convert';

import 'package:altair_wake/core/errors/storage_exception.dart';
import 'package:altair_wake/features/devices/data/device_repository.dart';
import 'package:altair_wake/features/devices/domain/device.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fakes.dart';

void main() {
  Future<SharedPreferencesDeviceRepository> repositoryWith(
    Map<String, Object> values,
  ) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferencesDeviceRepository(await SharedPreferences.getInstance());
  }

  test('sin datos guardados devuelve una lista vacía', () async {
    final repository = await repositoryWith({});
    expect(await repository.loadAll(), isEmpty);
  });

  test('guarda y recupera varios dispositivos con todos sus campos', () async {
    final repository = await repositoryWith({});
    final attempt = LastWakeAttempt(
      at: DateTime.utc(2026, 10, 11, 18, 30).toLocal(),
      status: WakeAttemptStatus.notConfirmed,
    );
    final devices = [
      sampleDevice(lastAttempt: attempt),
      sampleDevice(
        id: 'pc-2',
        name: 'Laptop',
        localIpv4: null,
        ipv6Address: '2806:2f0:1234::10',
        remoteMode: RemoteAccessMode.ipv6,
        remoteHost: 'pc.example.net',
        probePort: null,
      ),
    ];

    await repository.saveAll(devices);
    final loaded = await repository.loadAll();

    expect(loaded.map((d) => d.toJson()), devices.map((d) => d.toJson()));
    expect(loaded.first.lastAttempt!.at, attempt.at);
    expect(loaded.last.remoteMode, RemoteAccessMode.ipv6);
    expect(loaded.last.probePort, isNull);
  });

  test('datos dañados lanzan StorageException sin borrarlos', () async {
    const corrupt = '{"schemaVersion":1,"devices":[{"id":1}]}';
    final repository = await repositoryWith({
      SharedPreferencesDeviceRepository.storageKey: corrupt,
    });

    await expectLater(repository.loadAll(), throwsA(isA<StorageException>()));
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(SharedPreferencesDeviceRepository.storageKey), corrupt);
  });

  test('JSON inválido lanza StorageException', () async {
    final repository = await repositoryWith({
      SharedPreferencesDeviceRepository.storageKey: 'no es json',
    });
    await expectLater(repository.loadAll(), throwsA(isA<StorageException>()));
  });

  test('una MAC inválida guardada se considera dato dañado', () async {
    final json = sampleDevice().toJson()..['mac'] = 'ZZ:ZZ';
    final repository = await repositoryWith({
      SharedPreferencesDeviceRepository.storageKey: jsonEncode({
        'schemaVersion': 1,
        'devices': [json],
      }),
    });
    await expectLater(repository.loadAll(), throwsA(isA<StorageException>()));
  });

  test('un puerto fuera de rango guardado se considera dato dañado', () async {
    final json = sampleDevice().toJson()..['lanPort'] = 70000;
    final repository = await repositoryWith({
      SharedPreferencesDeviceRepository.storageKey: jsonEncode({
        'schemaVersion': 1,
        'devices': [json],
      }),
    });
    await expectLater(repository.loadAll(), throwsA(isA<StorageException>()));
  });

  test('una versión de esquema desconocida no se interpreta', () async {
    final repository = await repositoryWith({
      SharedPreferencesDeviceRepository.storageKey:
          '{"schemaVersion":99,"devices":[]}',
    });
    await expectLater(repository.loadAll(), throwsA(isA<StorageException>()));
  });
}
