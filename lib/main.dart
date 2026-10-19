import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/dependencies.dart';
import 'core/network/address_resolver.dart';
import 'core/network/local_network_inspector.dart';
import 'core/network/reachability_probe.dart';
import 'core/network/udp_sender.dart';
import 'core/security/agent_key_store.dart';
import 'features/devices/data/device_repository.dart';
import 'features/power_control/data/agent_client.dart';
import 'features/power_control/domain/power_control_service.dart';
import 'features/remote_desktop/domain/remote_desktop_router.dart';
import 'features/wake_on_lan/domain/wake_confirmer.dart';
import 'features/wake_on_lan/domain/wake_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  const resolver = SystemAddressResolver();
  const agentKeyStore = SecureAgentKeyStore();
  final dependencies = AppDependencies(
    repository: SharedPreferencesDeviceRepository(preferences),
    wakeService: WakeService(
      sender: const RawDatagramUdpSender(),
      resolver: resolver,
    ),
    confirmer: const WakeConfirmer(probe: TcpReachabilityProbe()),
    resolver: resolver,
    networkInspector: const SystemLocalNetworkInspector(),
    agentKeyStore: agentKeyStore,
    powerControl: const PowerControlService(
      client: AgentClient(),
      keyStore: agentKeyStore,
    ),
    remoteDesktopRouter: const RemoteDesktopRouter(keyStore: agentKeyStore),
  );
  runApp(AltairWakeApp(dependencies: dependencies));
}
