import 'dart:io';

/// Registro en archivo con rotación simple por tamaño. Nunca debe recibir la
/// clave ni el contenido completo de las peticiones.
class AgentLogger {
  AgentLogger(this._file, {this.maxBytes = 1024 * 1024});

  final File? _file;
  final int maxBytes;

  void info(String message) {
    final line = '${DateTime.now().toIso8601String()} $message';
    stdout.writeln(line);
    final file = _file;
    if (file == null) return;
    try {
      if (file.existsSync() && file.lengthSync() > maxBytes) {
        file.renameSync('${file.path}.1');
      }
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } on FileSystemException catch (error) {
      stderr.writeln('No se pudo escribir el registro: ${error.message}');
    }
  }
}
