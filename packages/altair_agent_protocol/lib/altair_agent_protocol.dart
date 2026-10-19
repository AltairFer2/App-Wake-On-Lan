/// Protocolo de órdenes entre la aplicación Altair Wake y el agente de
/// Windows: una petición JSON por línea sobre TCP, autenticada con
/// HMAC-SHA256, con marca de tiempo y nonce contra repeticiones.
library;

export 'src/agent_key.dart';
export 'src/messages.dart';
export 'src/replay_guard.dart';
export 'src/tunnel.dart';
