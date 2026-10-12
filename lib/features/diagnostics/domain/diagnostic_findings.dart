import 'dart:io';

import '../../../core/network/ip_classification.dart';
import '../../../core/network/local_network_inspector.dart';
import '../../../core/network/reachability_probe.dart';
import '../../devices/domain/device.dart';
import '../../wake_on_lan/domain/wake_report.dart';

enum FindingSeverity { info, warning, blocking }

class DiagnosticFinding {
  const DiagnosticFinding({
    required this.severity,
    required this.title,
    required this.explanation,
    this.recommendation,
  });

  final FindingSeverity severity;
  final String title;
  final String explanation;
  final String? recommendation;
}

/// Datos observados que alimentan el diagnóstico. Los campos `null` indican
/// pruebas que aún no se ejecutaron.
class DiagnosticInputs {
  const DiagnosticInputs({
    this.device,
    this.network,
    this.resolvedRemote,
    this.resolutionError,
    this.reachability,
    this.lastReport,
  });

  final Device? device;
  final LocalNetworkSnapshot? network;
  final List<InternetAddress>? resolvedRemote;
  final String? resolutionError;
  final ReachabilityStatus? reachability;
  final WakeReport? lastReport;
}

/// Interpreta las observaciones. Solo afirma lo que los datos demuestran; lo
/// demás se presenta como posibilidad a comprobar.
List<DiagnosticFinding> buildFindings(DiagnosticInputs inputs) {
  final findings = <DiagnosticFinding>[];
  final network = inputs.network;
  final device = inputs.device;

  if (network != null && network.isEmpty) {
    findings.add(
      const DiagnosticFinding(
        severity: FindingSeverity.blocking,
        title: 'El teléfono no tiene conectividad',
        explanation: 'No se detectó ninguna interfaz de red con dirección IP.',
        recommendation: 'Activa la Wi-Fi o los datos móviles.',
      ),
    );
  }
  if (device == null) return findings;

  _addLanFindings(findings, device, network);
  switch (device.remoteMode) {
    case RemoteAccessMode.none:
      findings.add(
        const DiagnosticFinding(
          severity: FindingSeverity.info,
          title: 'Sin acceso remoto configurado',
          explanation:
              'El encendido solo funcionará con el teléfono conectado a la '
              'misma red local que el equipo.',
        ),
      );
    case RemoteAccessMode.ipv4:
      _addIpv4Findings(findings, inputs);
    case RemoteAccessMode.ipv6:
      _addIpv6Findings(findings, inputs);
  }
  _addReachabilityFindings(findings, device, inputs.reachability);
  _addReportFindings(findings, inputs.lastReport);
  return findings;
}

void _addLanFindings(
  List<DiagnosticFinding> findings,
  Device device,
  LocalNetworkSnapshot? network,
) {
  final localIpv4 = device.localIpv4 == null
      ? null
      : InternetAddress.tryParse(device.localIpv4!);
  if (network == null || localIpv4 == null) return;
  if (!network.sharesSlash24With(localIpv4)) {
    findings.add(
      DiagnosticFinding(
        severity: FindingSeverity.warning,
        title: 'El teléfono no parece estar en la red del equipo',
        explanation:
            'Ninguna IPv4 del teléfono pertenece a la subred de '
            '${localIpv4.address} (estimación suponiendo máscara /24). La '
            'difusión LAN no llegará desde otra red.',
        recommendation:
            'Conéctate a la Wi-Fi de casa para el encendido local.',
      ),
    );
  }
}

void _addIpv4Findings(List<DiagnosticFinding> findings, DiagnosticInputs inputs) {
  _addResolutionError(findings, inputs);
  final resolved = inputs.resolvedRemote;
  if (resolved == null || resolved.isEmpty) return;
  final scope = IpClassification.scopeOf(resolved.first);
  if (scope == AddressScope.private || scope == AddressScope.carrierGradeNat) {
    findings.add(
      DiagnosticFinding(
        severity: FindingSeverity.blocking,
        title: 'La dirección remota IPv4 no es pública',
        explanation:
            '${resolved.first.address} pertenece a un rango privado o de '
            'CGNAT. El tráfico iniciado desde Internet no llega al router, así '
            'que un Port Mapping IPv4 no funcionará.',
        recommendation:
            'Solicita al ISP una IPv4 pública o usa el modo IPv6 si tu '
            'conexión lo permite.',
      ),
    );
    return;
  }
  findings.add(
    const DiagnosticFinding(
      severity: FindingSeverity.warning,
      title: 'Requisitos del router para IPv4',
      explanation:
          'Se necesita un Port Mapping UDP hacia el equipo. Con destino '
          'unicast, el router debe conocer la MAC del equipo (ARP); esa '
          'entrada caduca minutos después del apagado si no existe ARP '
          'estático. El reenvío a difusión no está confirmado en el '
          'HG6145F.',
      recommendation:
          'Prueba el encendido remoto con distintos tiempos desde el apagado '
          'y registra los resultados.',
    ),
  );
}

void _addIpv6Findings(List<DiagnosticFinding> findings, DiagnosticInputs inputs) {
  final network = inputs.network;
  if (network != null && !network.isEmpty && !network.hasGlobalIpv6) {
    findings.add(
      const DiagnosticFinding(
        severity: FindingSeverity.blocking,
        title: 'La red actual del teléfono no tiene IPv6 global',
        explanation:
            'Sin una IPv6 global en el teléfono no es posible alcanzar la IPv6 '
            'del equipo desde esta red.',
        recommendation:
            'Prueba con otra red o confirma que el APN de datos móviles usa '
            'IPv4/IPv6.',
      ),
    );
  }
  _addResolutionError(findings, inputs);
  final resolved = inputs.resolvedRemote;
  if (resolved != null &&
      resolved.isNotEmpty &&
      !IpClassification.isGlobalUnicastIpv6(resolved.first)) {
    findings.add(
      DiagnosticFinding(
        severity: FindingSeverity.blocking,
        title: 'La dirección IPv6 no es global',
        explanation:
            '${resolved.first.address} no pertenece a 2000::/3 y no es '
            'alcanzable desde Internet.',
        recommendation: 'Usa la IPv6 global del equipo (ipconfig en Windows).',
      ),
    );
  }
  findings.add(
    const DiagnosticFinding(
      severity: FindingSeverity.warning,
      title: 'Requisitos del router para IPv6',
      explanation:
          'El firewall IPv6 del router debe permitir UDP entrante hacia el '
          'equipo. Con el equipo apagado, el router solo entrega el paquete '
          'si todavía conserva su MAC en la caché de vecinos (NDP); en '
          'suspensión, la descarga NS (NS offload) de la tarjeta puede '
          'mantenerla. Si el ISP cambia el prefijo, la IPv6 del equipo cambia.',
      recommendation:
          'Verifica el comportamiento real en suspensión, hibernación y '
          'apagado antes de depender de esta ruta.',
    ),
  );
}

void _addResolutionError(
  List<DiagnosticFinding> findings,
  DiagnosticInputs inputs,
) {
  final error = inputs.resolutionError;
  if (error == null) return;
  findings.add(
    DiagnosticFinding(
      severity: FindingSeverity.blocking,
      title: 'Error de resolución DNS',
      explanation: error,
      recommendation:
          'Revisa el nombre de host o usa directamente la dirección IP.',
    ),
  );
}

void _addReachabilityFindings(
  List<DiagnosticFinding> findings,
  Device device,
  ReachabilityStatus? reachability,
) {
  if (device.probePort == null) {
    findings.add(
      const DiagnosticFinding(
        severity: FindingSeverity.info,
        title: 'Sin sondeo de estado',
        explanation:
            'Sin un puerto de sondeo la aplicación puede enviar el paquete, '
            'pero no verificar si el equipo encendió.',
        recommendation:
            'Configura un puerto TCP que Windows tenga abierto en la red '
            'privada, por ejemplo 445.',
      ),
    );
    return;
  }
  switch (reachability) {
    case null:
      return;
    case ReachabilityStatus.reachable:
      findings.add(
        const DiagnosticFinding(
          severity: FindingSeverity.info,
          title: 'El equipo responde',
          explanation: 'El sondeo TCP obtuvo respuesta: el equipo está encendido.',
        ),
      );
    case ReachabilityStatus.unverifiable:
      findings.add(
        const DiagnosticFinding(
          severity: FindingSeverity.info,
          title: 'Estado no verificable',
          explanation:
              'El equipo no respondió al sondeo. Puede estar apagado, '
              'suspendido, desconectado o el firewall de Windows descarta el '
              'sondeo. La falta de respuesta no confirma que esté apagado.',
          recommendation:
              'Con el equipo encendido, confirma que el puerto de sondeo '
              'responde; si no, ajusta el firewall o elige otro puerto.',
        ),
      );
    case ReachabilityStatus.noRoute:
      findings.add(
        const DiagnosticFinding(
          severity: FindingSeverity.warning,
          title: 'Sin ruta hacia el equipo',
          explanation:
              'La red actual del teléfono no tiene ruta hacia las direcciones '
              'del equipo.',
        ),
      );
  }
}

void _addReportFindings(List<DiagnosticFinding> findings, WakeReport? report) {
  if (report == null) return;
  for (final route in report.routes.where((r) => !r.isSent)) {
    findings.add(
      DiagnosticFinding(
        severity: route.outcome == WakeRouteOutcome.likelyBlockedByNat
            ? FindingSeverity.blocking
            : FindingSeverity.warning,
        title: 'Último envío fallido (${route.target})',
        explanation: route.detail,
      ),
    );
  }
}
