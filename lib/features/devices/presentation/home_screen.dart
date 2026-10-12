import 'dart:async';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';
import 'package:flutter/material.dart';

import '../../../app/dependencies.dart';
import '../../../core/errors/storage_exception.dart';
import '../../diagnostics/presentation/diagnostics_screen.dart';
import '../domain/device.dart';
import 'device_card.dart';
import 'device_form_screen.dart';
import 'device_list_controller.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const double _maxContentWidth = 760;

  /// Frecuencia del sondeo automático mientras la app está en primer plano.
  static const Duration _refreshInterval = Duration(seconds: 15);

  late final DeviceListController _controller;
  late final StreamSubscription<String> _messages;
  late final AppLifecycleListener _lifecycle;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    final deps = widget.dependencies;
    _controller = DeviceListController(
      repository: deps.repository,
      wakeService: deps.wakeService,
      confirmer: deps.confirmer,
      powerControl: deps.powerControl,
    );
    _messages = _controller.messages.listen(_showMessage);
    _controller.load();
    _startAutoRefresh();
    // En segundo plano no se sondea: ahorra batería y datos.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        _controller.refreshConnectivity();
        _startAutoRefresh();
      },
      onHide: _stopAutoRefresh,
    );
  }

  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      _refreshInterval,
      (_) => _controller.refreshConnectivity(),
    );
  }

  void _stopAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  @override
  void dispose() {
    _stopAutoRefresh();
    _lifecycle.dispose();
    _messages.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openForm([Device? device]) async {
    final keyStore = widget.dependencies.agentKeyStore;
    var hasStoredKey = false;
    if (device != null) {
      try {
        hasStoredKey = await keyStore.read(device.id) != null;
      } on StorageException catch (error) {
        _showMessage(error.message);
      }
    }
    if (!mounted) return;
    final result = await Navigator.of(context).push<DeviceFormResult>(
      MaterialPageRoute(
        builder: (_) => DeviceFormScreen(
          initial: device,
          hasStoredAgentKey: hasStoredKey,
        ),
      ),
    );
    if (result == null) return;
    try {
      final saved = result.device;
      final newKey = result.newAgentKey;
      if (saved.agentPort == null) {
        await keyStore.delete(saved.id);
      } else if (newKey != null) {
        await keyStore.write(saved.id, newKey);
      }
      await _controller.upsert(saved);
    } on StorageException catch (error) {
      _showMessage(error.message);
    }
  }

  Future<void> _sendPowerCommand(Device device, AgentCommand command) async {
    final (title, body, action) = switch (command) {
      AgentCommand.suspend => (
        'Suspender equipo',
        '¿Suspender "${device.name}"? Podrás encenderlo con Wake-on-LAN.',
        'Suspender',
      ),
      AgentCommand.shutdown => (
        'Apagar equipo',
        '¿Apagar "${device.name}"? Windows cerrará las aplicaciones en 30 s; '
            'se puede cancelar desde la app o con shutdown /a.',
        'Apagar',
      ),
      _ => ('', '', ''),
    };
    if (action.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await _controller.sendPowerCommand(device, command);
  }

  void _openDiagnostics([Device? device]) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DiagnosticsScreen(
          dependencies: widget.dependencies,
          device: device,
          lastReport: device == null
              ? null
              : _controller.runtimeOf(device.id).lastReport,
        ),
      ),
    );
  }

  Future<void> _confirmDelete(Device device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar equipo'),
        content: Text('¿Eliminar "${device.name}" de la lista?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _controller.delete(device.id);
      await widget.dependencies.agentKeyStore.delete(device.id);
    } on StorageException catch (error) {
      _showMessage(error.message);
    }
  }

  void _onAction(Device device, DeviceAction action) {
    switch (action) {
      case DeviceAction.sendWake:
        _controller.wake(device);
      case DeviceAction.edit:
        _openForm(device);
      case DeviceAction.diagnose:
        _openDiagnostics(device);
      case DeviceAction.delete:
        _confirmDelete(device);
      case DeviceAction.agentStatus:
        _sendPowerCommand(device, AgentCommand.status);
      case DeviceAction.suspend:
        _sendPowerCommand(device, AgentCommand.suspend);
      case DeviceAction.shutdown:
        _sendPowerCommand(device, AgentCommand.shutdown);
      case DeviceAction.cancelShutdown:
        _sendPowerCommand(device, AgentCommand.cancelShutdown);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Altair Wake'),
        actions: [
          IconButton(
            tooltip: 'Diagnóstico de red',
            icon: const Icon(Icons.network_check),
            onPressed: _openDiagnostics,
          ),
          IconButton(
            tooltip: 'Comprobar estado',
            icon: const Icon(Icons.refresh),
            onPressed: _controller.refreshConnectivity,
          ),
        ],
      ),
      // En el estado vacío ya hay un botón central para agregar.
      floatingActionButton: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) =>
            _controller.loadState == LoadState.ready &&
                _controller.devices.isEmpty
            ? const SizedBox.shrink()
            : FloatingActionButton.extended(
                onPressed: _openForm,
                icon: const Icon(Icons.add),
                label: const Text('Agregar equipo'),
              ),
      ),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => switch (_controller.loadState) {
          LoadState.loading => const Center(child: CircularProgressIndicator()),
          LoadState.failed => _LoadError(
            message: _controller.loadError ?? 'Error desconocido.',
            onRetry: _controller.load,
          ),
          LoadState.ready when _controller.devices.isEmpty => _EmptyState(
            onAdd: _openForm,
          ),
          LoadState.ready => RefreshIndicator(
            onRefresh: _controller.refreshConnectivity,
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              itemCount: _controller.devices.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final device = _controller.devices[index];
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: _maxContentWidth),
                    child: DeviceCard(
                      device: device,
                      runtime: _controller.runtimeOf(device.id),
                      onWake: () => _controller.wake(device),
                      onAction: (action) => _onAction(device, action),
                    ),
                  ),
                );
              },
            ),
          ),
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.power_settings_new, size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('Sin equipos registrados', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Agrega una computadora con su dirección MAC para encenderla '
              'mediante Wake-on-LAN.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Agregar equipo'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Reintentar')),
          ],
        ),
      ),
    );
  }
}
