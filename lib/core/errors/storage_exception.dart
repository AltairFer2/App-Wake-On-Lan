/// Falla al leer o escribir la configuración local. Conserva la causa
/// original para diagnóstico.
class StorageException implements Exception {
  const StorageException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      cause == null ? 'StorageException: $message' : 'StorageException: $message ($cause)';
}
