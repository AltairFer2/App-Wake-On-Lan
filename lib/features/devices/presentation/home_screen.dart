import 'dart:async';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';
import 'package:flutter/material.dart';

import '../../../app/branding.dart';
import '../../../app/dependencies.dart';
import '../../../core/errors/storage_exception.dart';
import '../../diagnostics/presentation/diagnostics_screen.dart';
import '../../remote_desktop/data/rdp_client.dart';
import '../../remote_desktop/data/remote_desktop_launcher.dart';
import '../../remote_desktop/domain/monitor_layout.dart';
import '../../remote_desktop/domain/remote_desktop.dart';
import '../../remote_desktop/domain/remote_desktop_router.dart';
import '../../remote_desktop/presentation/rdp_credentials_dialog.dart';
import '../../remote_desktop/presentation/rdp_session_screen.dart';
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

  Future<void> _openRemoteDesktop(Device device) async {
    final host = remoteDesktopHostOf(device);
    final port = device.remoteDesktopPort;
    if (host == null || port == null) return;
    final rdpClient = widget.dependencies.rdpClient;
    if (await rdpClient.isSupported()) {
      await _openIntegratedRemoteDesktop(device, rdpClient);
      return;
    }
    final launch = await widget.dependencies.remoteDesktop.open(host, port);
    final message = switch (launch) {
      RemoteDesktopLaunch.connection => null,
      RemoteDesktopLaunch.clientApp =>
        'Se abrió Windows App. Si el equipo no está guardado, agrégalo con '
            '$host${port == defaultRemoteDesktopPort ? '' : ':$port'}.',
      RemoteDesktopLaunch.store =>
        'Instala "Windows App" de Microsoft para conectarte al escritorio.',
      RemoteDesktopLaunch.unavailable =>
        'No se pudo abrir un cliente de escritorio remoto.',
    };
    if (message != null) _showMessage(message);
  }

  /// En casa conecta directo; fuera, por el túnel del agente.
  Future<void> _openIntegratedRemoteDesktop(Device device, RdpClient client) async {
    if (!mounted) return;
    final monitors = MonitorLayout.tryParse(device.remoteDesktopMonitors);
    final credentials = await showDialog<RdpCredentials>(
      context: context,
      builder: (_) => RdpCredentialsDialog(
        deviceName: device.name,
        monitorCount: monitors?.monitors.length ?? 1,
      ),
    );
    if (credentials == null || !mounted) return;
    final endpoint = await _findRemoteDesktop(device);
    if (endpoint == null) return;
    if (!mounted) {
      await endpoint.close();
      return;
    }
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RdpSessionScreen(
            client: client,
            title: device.name,
            host: endpoint.host,
            port: endpoint.port,
            username: credentials.username,
            password: credentials.password,
            monitors: credentials.allMonitors ? monitors : monitors?.primaryOnly,
          ),
        ),
      );
    } finally {
      await endpoint.close();
    }
  }

  /// Red local si RDP responde; si no, el túnel del agente. `null` (con
  /// aviso) si no hay forma de llegar.
  Future<RemoteDesktopEndpoint?> _findRemoteDesktop(Device device) async {
    final navigator = Navigator.of(context);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 24),
              Expanded(child: Text('Buscando ${device.name}…')),
            ],
          ),
        ),
      ),
    );
    try {
      final endpoint = await widget.dependencies.remoteDesktopRouter.connect(device);
      if (endpoint.viaAgent) _showMessage('Fuera de casa: conectando a través del agente.');
      return endpoint;
    } on RemoteDesktopRouteException catch (error) {
      _showMessage(error.message);
    } on StorageException catch (error) {
      _showMessage(error.message);
    } finally {
      navigator.pop();
    }
    return null;
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
      case DeviceAction.wakeDisplay:
        _sendPowerCommand(device, AgentCommand.wakeDisplay);
      case DeviceAction.suspend:
        _sendPowerCommand(device, AgentCommand.suspend);
      case DeviceAction.shutdown:
        _sendPowerCommand(device, AgentCommand.shutdown);
      case DeviceAction.cancelShutdown:
        _sendPowerCommand(device, AgentCommand.cancelShutdown);
      case DeviceAction.remoteDesktop:
        _openRemoteDesktop(device);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                appIconAsset,
                width: 32,
                height: 32,
                semanticLabel: 'Logotipo de $appDisplayName',
              ),
            ),
            const SizedBox(width: 12),
            const Flexible(
              child: Text(appDisplayName, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
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
