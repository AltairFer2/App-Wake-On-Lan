import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';

import '../../../core/network/socket_failure.dart';

enum AgentCallOutcome {
  /// El agente ejecutó o aceptó la orden (respuesta autenticada).
  accepted,

  /// El agente respondió autenticado, pero rechazó o no pudo ejecutar.
  rejected,

  /// Conectó, pero el agente cerró sin responder: clave distinta o petición
  /// inválida.
  unauthorized,

  /// Hubo respuesta, pero no está firmada con la clave esperada.
  unauthenticResponse,

  /// Sin conexión con el agente (equipo apagado, sin ruta o firewall).
  unreachable,
}

class AgentCallResult {
  const AgentCallResult(this.outcome, this.message, [this.response]);

  final AgentCallOutcome outcome;
  final String message;
  final AgentResponse? response;

  bool get isAccepted => outcome == AgentCallOutcome.accepted;
}

class AgentClient {
  const AgentClient({
    this.timeout = const Duration(seconds: 5),
    this._clock,
  });

  final Duration timeout;
  final DateTime Function()? _clock;

  Future<AgentCallResult> send(
    InternetAddress address,
    int port,
    AgentKey key,
    AgentCommand command,
  ) async {
    final request = AgentRequest.create(command, (_clock ?? DateTime.now)());
    final Socket socket;
    try {
      socket = await Socket.connect(address, port, timeout: timeout);
    } on SocketException catch (error) {
      return AgentCallResult(
        AgentCallOutcome.unreachable,
        _connectFailure(error, address, port),
      );
    }
    try {
      socket.write('${request.encode(key)}\n');
      await socket.flush();
      final reply = await utf8.decoder
          .bind(socket)
          .join()
          .timeout(timeout);
      return _interpret(reply.trim(), key, request);
    } on TimeoutException {
      return const AgentCallResult(
        AgentCallOutcome.unreachable,
        'El agente no respondió a tiempo.',
      );
    } on SocketException catch (error) {
      return AgentCallResult(
        AgentCallOutcome.unreachable,
        'Se perdió la conexión con el agente (${error.message}).',
      );
    } finally {
      socket.destroy();
    }
  }

  AgentCallResult _interpret(String reply, AgentKey key, AgentRequest request) {
    if (reply.isEmpty) {
      return const AgentCallResult(
        AgentCallOutcome.unauthorized,
        'El agente rechazó la orden sin responder: la clave no coincide.',
      );
    }
    final AgentResponse response;
    try {
      response = AgentResponse.decodeAndVerify(
        reply,
        key,
        expectedNonce: request.nonce,
      );
    } on AgentProtocolException {
      return const AgentCallResult(
        AgentCallOutcome.unauthenticResponse,
        'La respuesta no está firmada con la clave configurada.',
      );
    }
    if (response.ok) {
      return AgentCallResult(AgentCallOutcome.accepted, 'Orden aceptada.', response);
    }
    return AgentCallResult(
      AgentCallOutcome.rejected,
      switch (response.error) {
        AgentErrorCode.clockSkew =>
          'La hora del teléfono y la del PC difieren más de '
              '${maxClockSkew.inSeconds} s.',
        AgentErrorCode.replay => 'El agente detectó una petición repetida.',
        AgentErrorCode.failed => 'El PC no pudo ejecutar la orden.',
        _ => 'El agente rechazó la orden.',
      },
      response,
    );
  }

  static String _connectFailure(
    SocketException error,
    InternetAddress address,
    int port,
  ) {
    final target = '${address.address}:$port';
    return switch (classifySocketFailure(error)) {
      SocketFailureKind.connectionRefused =>
        'El PC respondió, pero el agente no escucha en $target.',
      SocketFailureKind.networkUnreachable =>
        'El teléfono no tiene ruta hacia $target. El agente solo acepta '
            'órdenes desde la red local.',
      _ =>
        'Sin respuesta de $target. El PC puede estar apagado o suspendido, '
            'o el teléfono no está en la red local.',
    };
  }
}
