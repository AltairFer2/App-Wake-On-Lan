import 'package:altair_agent_protocol/altair_agent_protocol.dart';
import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../core/formatting/relative_time.dart';
import '../../../core/network/reachability_probe.dart';
import '../../remote_desktop/domain/remote_desktop.dart';
import '../../wake_on_lan/domain/wake_confirmer.dart';
import '../../wake_on_lan/domain/wake_report.dart';
import '../domain/device.dart';
import 'device_list_controller.dart';
import 'status_labels.dart';

enum DeviceAction {
  sendWake,
  edit,
  diagnose,
  delete,
  agentStatus,
  wakeDisplay,
  suspend,
  shutdown,
  cancelShutdown,
  remoteDesktop,
}

class DeviceCard extends StatelessWidget {
  const DeviceCard({
    super.key,
    required this.device,
    required this.runtime,
    required this.onWake,
    required this.onAction,
  });

  final Device device;
  final DeviceRuntimeState runtime;
  final VoidCallback onWake;
  final ValueChanged<DeviceAction> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.computer, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.name,
                        style: theme.textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // MAC e IP en líneas separadas: juntas no caben en
                      // pantallas estrechas con fuente monoespaciada.
                      for (final detail in [device.mac.toString(), ?device.localIpv4])
                        Text(
                          detail,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                PopupMenuButton<DeviceAction>(
                  tooltip: 'Opciones de ${device.name}',
                  onSelected: onAction,
                  itemBuilder: (_) => [
                    if (device.agentPort != null) ...const [
                      PopupMenuItem(
                        value: DeviceAction.agentStatus,
                        child: Text('Consultar agente'),
                      ),
                      PopupMenuItem(
                        value: DeviceAction.wakeDisplay,
                        child: Text('Encender pantalla'),
                      ),
                      PopupMenuItem(
                        value: DeviceAction.suspend,
                        child: Text('Suspender'),
                      ),
                      PopupMenuItem(
                        value: DeviceAction.shutdown,
                        child: Text('Apagar'),
                      ),
                      PopupMenuItem(
                        value: DeviceAction.cancelShutdown,
                        child: Text('Cancelar apagado'),
                      ),
                      PopupMenuDivider(),
                    ],
                    ...const [
                      // Disponible siempre: sirve si el sondeo falla o para
                      // probar la entrega del paquete.
                      PopupMenuItem(
                        value: DeviceAction.sendWake,
                        child: Text('Enviar paquete de encendido'),
                      ),
                      PopupMenuItem(value: DeviceAction.edit, child: Text('Editar')),
                      PopupMenuItem(
                        value: DeviceAction.diagnose,
                        child: Text('Diagnóstico'),
                      ),
                      PopupMenuItem(
                        value: DeviceAction.delete,
                        child: Text('Eliminar'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ConnectivityChip(device: device, runtime: runtime),
                Chip(
                  avatar: const Icon(Icons.alt_route, size: 18),
                  label: Text(remoteModeLabel(device.remoteMode)),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: runtime.phase != DevicePhase.idle
                    ? _PhaseIndicator(runtime: runtime)
                    : _LastAttempt(attempt: device.lastAttempt),
              ),
            ),
            if (runtime.lastReport case final report?) ...[
              const SizedBox(height: 8),
              _RouteResults(report: report),
            ],
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _PrimaryActions(
                device: device,
                runtime: runtime,
                onWake: onWake,
                onAction: onAction,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Acción principal según el estado observado:
/// - responde y tiene agente → Suspender / Apagar;
/// - responde sin agente → "Encendido" (no hay forma de apagarlo);
/// - sin respuesta o sin sondeo → Encender (no se afirma que esté apagado).
/// Si responde y tiene escritorio remoto configurado, se añade "Escritorio".
class _PrimaryActions extends StatelessWidget {
  const _PrimaryActions({
    required this.device,
    required this.runtime,
    required this.onWake,
    required this.onAction,
  });

  final Device device;
  final DeviceRuntimeState runtime;
  final VoidCallback onWake;
  final ValueChanged<DeviceAction> onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isOn = runtime.connectivity == ReachabilityStatus.reachable;
    final hasAgent = device.agentPort != null;
    final remoteDesktop = remoteDesktopHostOf(device) == null
        ? null
        : FilledButton.tonalIcon(
            onPressed: () => onAction(DeviceAction.remoteDesktop),
            icon: const Icon(Icons.desktop_windows_outlined),
            label: const Text('Escritorio'),
          );
    final Widget actions = switch (runtime.phase) {
      DevicePhase.poweringDown when runtime.powerCommand == AgentCommand.shutdown =>
        OutlinedButton.icon(
          onPressed: () => onAction(DeviceAction.cancelShutdown),
          icon: const Icon(Icons.cancel_outlined),
          label: const Text('Cancelar apagado'),
        ),
      DevicePhase.idle when isOn && hasAgent => Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.end,
        children: [
          ?remoteDesktop,
          OutlinedButton.icon(
            onPressed: () => onAction(DeviceAction.suspend),
            icon: const Icon(Icons.bedtime_outlined),
            label: const Text('Suspender'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.errorContainer,
              foregroundColor: scheme.onErrorContainer,
            ),
            onPressed: () => onAction(DeviceAction.shutdown),
            icon: const Icon(Icons.power_settings_new),
            label: const Text('Apagar'),
          ),
        ],
      ),
      DevicePhase.idle when isOn =>
        remoteDesktop ??
            const FilledButton.tonal(onPressed: null, child: Text('Encendido')),
      DevicePhase.idle => FilledButton.icon(
        onPressed: onWake,
        icon: const Icon(Icons.power_settings_new),
        label: const Text('Encender'),
      ),
      _ => const FilledButton(onPressed: null, child: Text('En curso…')),
    };
    return Align(
      alignment: Alignment.centerRight,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: KeyedSubtree(
          key: ValueKey((runtime.phase, isOn, hasAgent, runtime.powerCommand)),
          child: actions,
        ),
      ),
    );
  }
}

class _ConnectivityChip extends StatelessWidget {
  const _ConnectivityChip({required this.device, required this.runtime});

  final Device device;
  final DeviceRuntimeState runtime;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, String label, Color color) = switch (runtime) {
      _ when probeTargetsFor(device).isEmpty => (
        Icons.help_outline,
        'Sin sondeo configurado',
        scheme.onSurfaceVariant,
      ),
      // Solo en la primera comprobación: las periódicas conservan el último
      // estado para que el chip no parpadee.
      DeviceRuntimeState(checking: true, connectivity: null) => (
        Icons.sync,
        'Comprobando…',
        scheme.onSurfaceVariant,
      ),
      DeviceRuntimeState(connectivity: final status?) => (
        switch (status) {
          ReachabilityStatus.reachable => Icons.check_circle,
          ReachabilityStatus.unverifiable => Icons.help,
          ReachabilityStatus.noRoute => Icons.signal_wifi_off,
        },
        connectivityLabel(status),
        switch (status) {
          ReachabilityStatus.reachable => StatusColors.success,
          ReachabilityStatus.unverifiable => scheme.onSurfaceVariant,
          ReachabilityStatus.noRoute => StatusColors.warning,
        },
      ),
      _ => (Icons.help_outline, 'Estado desconocido', scheme.onSurfaceVariant),
    };
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: Chip(
        key: ValueKey(label),
        avatar: Icon(icon, size: 18, color: color),
        label: Text(label),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _PhaseIndicator extends StatelessWidget {
  const _PhaseIndicator({required this.runtime});

  final DeviceRuntimeState runtime;

  @override
  Widget build(BuildContext context) {
    final text = switch (runtime.phase) {
      DevicePhase.sending => 'Enviando paquete mágico…',
      DevicePhase.confirming => 'Paquete enviado. Esperando respuesta del equipo…',
      DevicePhase.poweringDown when runtime.powerCommand == AgentCommand.suspend =>
        'Suspendiendo… esperando que deje de responder.',
      _ => 'Apagando… esperando que deje de responder.',
    };
    return Column(
      key: ValueKey(runtime.phase),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 8),
        const LinearProgressIndicator(),
      ],
    );
  }
}

class _LastAttempt extends StatelessWidget {
  const _LastAttempt({required this.attempt});

  final LastWakeAttempt? attempt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final attempt = this.attempt;
    final text = attempt == null
        ? 'Sin intentos de encendido'
        : 'Último intento ${formatRelativeTime(attempt.at, DateTime.now())} · '
              '${attemptStatusLabel(attempt.status)}';
    final color = switch (attempt?.status) {
      WakeAttemptStatus.confirmedAwake => StatusColors.success,
      WakeAttemptStatus.notSent => theme.colorScheme.error,
      _ => theme.colorScheme.onSurfaceVariant,
    };
    return Text(
      text,
      key: ValueKey(text),
      style: theme.textTheme.bodyMedium?.copyWith(color: color),
    );
  }
}

class _RouteResults extends StatelessWidget {
  const _RouteResults({required this.report});

  final WakeReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final route in report.routes)
          Padding(
            padding: const EdgeInsets.only(top: 4, right: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  route.isSent ? Icons.outbox : Icons.error_outline,
                  size: 18,
                  color: route.isSent
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${routeKindLabel(route.kind)} ${route.target}: '
                    '${routeOutcomeLabel(route.outcome)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
