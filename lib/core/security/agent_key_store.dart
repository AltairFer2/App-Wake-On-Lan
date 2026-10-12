import 'package:altair_agent_protocol/altair_agent_protocol.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../errors/storage_exception.dart';

/// Claves de los agentes, una por dispositivo. Se guardan separadas de la
/// configuración general porque son secretos.
abstract interface class AgentKeyStore {
  Future<AgentKey?> read(String deviceId);
  Future<void> write(String deviceId, AgentKey key);
  Future<void> delete(String deviceId);
}

/// Usa el almacenamiento cifrado respaldado por Android Keystore.
class SecureAgentKeyStore implements AgentKeyStore {
  const SecureAgentKeyStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  static String _entry(String deviceId) => 'altair_wake.agent_key.$deviceId';

  @override
  Future<AgentKey?> read(String deviceId) async {
    final String? encoded;
    try {
      encoded = await _storage.read(key: _entry(deviceId));
    } on PlatformException catch (error) {
      throw StorageException('No se pudo leer la clave del agente.', error.code);
    }
    if (encoded == null) return null;
    final key = AgentKey.tryParse(encoded);
    if (key == null) {
      throw const StorageException('La clave guardada del agente está dañada.');
    }
    return key;
  }

  @override
  Future<void> write(String deviceId, AgentKey key) async {
    try {
      await _storage.write(key: _entry(deviceId), value: key.encode());
    } on PlatformException catch (error) {
      throw StorageException('No se pudo guardar la clave del agente.', error.code);
    }
  }

  @override
  Future<void> delete(String deviceId) async {
    try {
      await _storage.delete(key: _entry(deviceId));
    } on PlatformException catch (error) {
      throw StorageException('No se pudo borrar la clave del agente.', error.code);
    }
  }
}
