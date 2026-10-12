import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/errors/storage_exception.dart';
import '../domain/device.dart';

abstract interface class DeviceRepository {
  /// Lanza [StorageException] si los datos guardados no pueden leerse.
  Future<List<Device>> loadAll();

  /// Lanza [StorageException] si los datos no pueden guardarse.
  Future<void> saveAll(List<Device> devices);
}

/// Persiste los dispositivos como JSON versionado en el almacenamiento privado
/// de la aplicación (en Android, `SharedPreferences` dentro del sandbox; la
/// copia de seguridad automática está desactivada en el manifiesto).
class SharedPreferencesDeviceRepository implements DeviceRepository {
  SharedPreferencesDeviceRepository(this._preferences);

  static const String storageKey = 'altair_wake.devices';
  static const int schemaVersion = 1;

  final SharedPreferences _preferences;

  @override
  Future<List<Device>> loadAll() async {
    final raw = _preferences.getString(storageKey);
    if (raw == null) return [];
    try {
      final document = jsonDecode(raw) as Map<String, Object?>;
      final version = document['schemaVersion'];
      if (version != schemaVersion) {
        throw FormatException('Versión de esquema no soportada: $version');
      }
      final entries = document['devices'] as List<Object?>;
      return [
        for (final entry in entries)
          Device.fromJson(entry as Map<String, Object?>),
      ];
    } on FormatException catch (error) {
      throw StorageException('Los datos guardados están dañados.', error);
    } on TypeError catch (error) {
      throw StorageException('Los datos guardados están dañados.', error);
    }
  }

  @override
  Future<void> saveAll(List<Device> devices) async {
    final raw = jsonEncode({
      'schemaVersion': schemaVersion,
      'devices': [for (final device in devices) device.toJson()],
    });
    final bool saved;
    try {
      saved = await _preferences.setString(storageKey, raw);
    } on Exception catch (error) {
      throw StorageException('No se pudo guardar la configuración.', error);
    }
    if (!saved) {
      throw const StorageException('No se pudo guardar la configuración.');
    }
  }
}
