import '../core/network/address_resolver.dart';
import '../core/network/local_network_inspector.dart';
import '../core/security/agent_key_store.dart';
import '../features/devices/data/device_repository.dart';
import '../features/power_control/domain/power_control_service.dart';
import '../features/remote_desktop/data/rdp_client.dart';
import '../features/remote_desktop/data/remote_desktop_launcher.dart';
import '../features/remote_desktop/domain/remote_desktop_router.dart';
import '../features/wake_on_lan/domain/wake_confirmer.dart';
import '../features/wake_on_lan/domain/wake_service.dart';

/// Servicios compartidos de la aplicación, construidos una sola vez en `main`
/// y sustituibles por dobles en las pruebas.
class AppDependencies {
  const AppDependencies({
    required this.repository,
    required this.wakeService,
    required this.confirmer,
    required this.resolver,
    required this.networkInspector,
    required this.agentKeyStore,
    required this.powerControl,
    this.remoteDesktop = const RemoteDesktopLauncher(),
    this.rdpClient = const RdpClient(),
    required this.remoteDesktopRouter,
  });

  final DeviceRepository repository;
  final WakeService wakeService;
  final WakeConfirmer confirmer;
  final AddressResolver resolver;
  final LocalNetworkInspector networkInspector;
  final AgentKeyStore agentKeyStore;
  final PowerControlService powerControl;
  /// Cliente externo (Windows App): respaldo si el integrado no está disponible.
  final RemoteDesktopLauncher remoteDesktop;

  /// Cliente RDP integrado (FreeRDP).
  final RdpClient rdpClient;

  /// Ruta hacia el escritorio remoto: red local o túnel del agente.
  final RemoteDesktopRouter remoteDesktopRouter;
}
