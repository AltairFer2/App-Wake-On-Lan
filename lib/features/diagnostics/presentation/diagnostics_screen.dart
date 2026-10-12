import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/dependencies.dart';
import '../../../app/theme.dart';
import '../../../core/network/address_resolver.dart';
import '../../../core/network/ip_classification.dart';
import '../../../core/network/local_network_inspector.dart';
import '../../../core/network/reachability_probe.dart';
import '../../devices/domain/device.dart';
import '../../wake_on_lan/domain/wake_confirmer.dart';
import '../../wake_on_lan/domain/wake_report.dart';
import '../domain/diagnostic_findings.dart';

/// Pruebas de red del teléfono y, si se indica [device], de ese equipo.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({
    super.key,
    required this.dependencies,
    this.device,
    this.lastReport,
  });

  final AppDependencies dependencies;
  final Device? device;
  final WakeReport? lastReport;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  bool _running = false;
  LocalNetworkSnapshot? _network;
  String? _networkError;
  List<InternetAddress>? _resolved;
  String? _resolutionError;
  List<ReachabilityResult>? _probeResults;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _networkError = null;
      _resolved = null;
      _resolutionError = null;
      _probeResults = null;
    });
    final deps = widget.dependencies;
    final device = widget.device;
    try {
      _network = await deps.networkInspector.inspect();
    } on SocketException catch (error) {
      _network = null;
      _networkError = 'No se pudieron leer las interfaces: ${error.message}';
    }
    if (device != null) {
      final host = device.remoteTarget;
      if (host != null) {
        try {
          _resolved = await deps.resolver.resolve(
            host,
            device.remoteMode == RemoteAccessMode.ipv6
                ? InternetAddressType.IPv6
                : InternetAddressType.IPv4,
          );
        } on AddressResolutionException catch (error) {
          _resolutionError = error.message;
        }
      }
      _probeResults = await deps.confirmer.probeEach(device);
    }
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final findings = _running
        ? const <DiagnosticFinding>[]
        : buildFindings(
            DiagnosticInputs(
              device: device,
              network: _network,
              resolvedRemote: _resolved,
              resolutionError: _resolutionError,
              reachability: WakeConfirmer.aggregate(_probeResults ?? const []),
              lastReport: widget.lastReport,
            ),
          );
    return Scaffold(
      appBar: AppBar(
        title: Text(device == null ? 'Diagnóstico de red' : 'Diagnóstico: ${device.name}'),
        actions: [
          IconButton(
            tooltip: 'Repetir pruebas',
            onPressed: _running ? null : _run,
            icon: const Icon(Icons.replay),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_running) const LinearProgressIndicator(),
                  _Section(
                    title: 'Red del teléfono',
                    child: _NetworkSummary(
                      network: _network,
                      error: _networkError,
                    ),
                  ),
                  if (device != null)
                    _Section(
                      title: 'Pruebas del equipo',
                      child: _DeviceTests(
                        device: device,
                        resolved: _resolved,
                        resolutionError: _resolutionError,
                        probeResults: _probeResults,
                      ),
                    ),
                  if (findings.isNotEmpty)
                    _Section(
                      title: 'Interpretación y recomendaciones',
                      child: Column(
                        children: [
                          for (final finding in findings)
                            _FindingTile(finding: finding),
                        ],
                      ),
                    ),
                  const _Section(
                    title: 'Requisitos del equipo Windows',
                    child: _WindowsChecklist(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class _NetworkSummary extends StatelessWidget {
  const _NetworkSummary({required this.network, required this.error});

  final LocalNetworkSnapshot? network;
  final String? error;

  static String _kindLabel(InterfaceKind kind) => switch (kind) {
    InterfaceKind.wifi => 'Wi-Fi',
    InterfaceKind.mobileData => 'Datos móviles',
    InterfaceKind.vpn => 'VPN/túnel',
    InterfaceKind.ethernet => 'Ethernet',
    InterfaceKind.unknown => 'Otra',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final network = this.network;
    if (error != null) return Text(error!);
    if (network == null) return const Text('Comprobando…');
    if (network.isEmpty) return const Text('Sin interfaces de red activas.');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _YesNoRow(label: 'IPv4 privada (LAN)', value: network.privateIpv4.isNotEmpty),
        _YesNoRow(label: 'IPv6 global', value: network.hasGlobalIpv6),
        const SizedBox(height: 8),
        for (final nic in network.interfaces)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${nic.name} · ${_kindLabel(nic.kind)} (estimado)',
                  style: theme.textTheme.bodyMedium,
                ),
                for (final address in nic.addresses)
                  Text(
                    '${address.address}  ${_scopeLabel(address)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

String _scopeLabel(InternetAddress address) =>
    switch (IpClassification.scopeOf(address)) {
      AddressScope.public => '(pública/global)',
      AddressScope.private => '(privada)',
      AddressScope.carrierGradeNat => '(CGNAT)',
      AddressScope.nonRoutable => '(local/no enrutable)',
    };

class _YesNoRow extends StatelessWidget {
  const _YesNoRow({required this.label, required this.value});

  final String label;
  final bool value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          value ? Icons.check_circle : Icons.cancel,
          size: 18,
          color: value ? StatusColors.success : Theme.of(context).colorScheme.error,
        ),
        const SizedBox(width: 8),
        Text('$label: ${value ? 'sí' : 'no'}'),
      ],
    );
  }
}

class _DeviceTests extends StatelessWidget {
  const _DeviceTests({
    required this.device,
    required this.resolved,
    required this.resolutionError,
    required this.probeResults,
  });

  final Device device;
  final List<InternetAddress>? resolved;
  final String? resolutionError;
  final List<ReachabilityResult>? probeResults;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remote = device.remoteTarget;
    final remoteText = switch ((remote, resolved, resolutionError)) {
      (null, _, _) => 'Sin ruta remota configurada.',
      (_, _, final String error) => error,
      (_, final List<InternetAddress> addresses, _) =>
        '$remote → ${addresses.map((a) => '${a.address} ${_scopeLabel(a)}').join(', ')}',
      _ => 'Comprobando…',
    };
    final probes = probeResults;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Dirección remota', style: theme.textTheme.labelLarge),
        Text(remoteText),
        const SizedBox(height: 12),
        Text('Sondeo TCP', style: theme.textTheme.labelLarge),
        if (probes == null)
          const Text('Comprobando…')
        else if (probes.isEmpty)
          const Text('Sin sondeo configurado (requiere IP y puerto de sondeo).')
        else
          for (final result in probes) Text(result.detail),
      ],
    );
  }
}

class _FindingTile extends StatelessWidget {
  const _FindingTile({required this.finding});

  final DiagnosticFinding finding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (IconData icon, Color color) = switch (finding.severity) {
      FindingSeverity.info => (Icons.info_outline, theme.colorScheme.primary),
      FindingSeverity.warning => (Icons.warning_amber, StatusColors.warning),
      FindingSeverity.blocking => (Icons.block, theme.colorScheme.error),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, semanticLabel: finding.severity.name),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(finding.title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(finding.explanation),
                if (finding.recommendation case final recommendation?) ...[
                  const SizedBox(height: 4),
                  Text(
                    recommendation,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WindowsChecklist extends StatelessWidget {
  const _WindowsChecklist();

  static const List<String> _items = [
    'Conecta el equipo por cable Ethernet: la Wi-Fi rara vez admite '
        'Wake-on-LAN con el equipo apagado.',
    'BIOS/UEFI: activa "Wake on LAN" / "Power On by PCI-E" y desactiva '
        'ErP/EuP o "Deep Sleep".',
    'Administrador de dispositivos → adaptador Ethernet → Administración de '
        'energía: permitir que el dispositivo active el equipo, solo con '
        'Magic Packet.',
    'Opciones avanzadas del adaptador: "Wake on Magic Packet" y, si existe, '
        '"Shutdown Wake-On-Lan" habilitados.',
    'Windows 10/11 desactiva Wake-on-LAN tras el apagado con Inicio rápido. '
        'Para encender desde apagado, desactiva "Activar inicio rápido" en '
        'Opciones de energía.',
    'Prueba primero suspensión, luego hibernación y por último apagado; no '
        'todos los equipos admiten los tres estados.',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in _items)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('•  '),
                Expanded(child: Text(item)),
              ],
            ),
          ),
      ],
    );
  }
}
