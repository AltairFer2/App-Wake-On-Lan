import 'dart:io';
import 'dart:typed_data';

import 'package:altair_agent_protocol/altair_agent_protocol.dart';
import 'package:altair_wake/core/errors/storage_exception.dart';
import 'package:altair_wake/core/security/agent_key_store.dart';
import 'package:altair_wake/core/network/address_resolver.dart';
import 'package:altair_wake/core/network/local_network_inspector.dart';
import 'package:altair_wake/core/network/mac_address.dart';
import 'package:altair_wake/core/network/reachability_probe.dart';
import 'package:altair_wake/core/network/udp_sender.dart';
import 'package:altair_wake/features/devices/data/device_repository.dart';
import 'package:altair_wake/features/devices/domain/device.dart';
import 'package:altair_wake/features/power_control/data/agent_client.dart';
import 'package:altair_wake/features/power_control/domain/power_control_service.dart';

Device sampleDevice({
  String id = 'pc-1',
  String name = 'PC Escritorio',
  String? localIpv4 = '192.168.100.20',
  String broadcastAddress = '192.168.100.255',
  String? ipv6Address,
  RemoteAccessMode remoteMode = RemoteAccessMode.none,
  String? remoteHost,
  int? probePort = 445,
  int? agentPort,
  LastWakeAttempt? lastAttempt,
}) => Device(
  id: id,
  name: name,
  mac: MacAddress.parse('D8:BB:C1:12:34:56'),
  localIpv4: localIpv4,
  broadcastAddress: broadcastAddress,
  ipv6Address: ipv6Address,
  remoteMode: remoteMode,
  remoteHost: remoteHost,
  probePort: probePort,
  agentPort: agentPort,
  lastAttempt: lastAttempt,
);

class SentDatagram {
  SentDatagram(this.payload, this.destination, this.port, this.broadcast);

  final Uint8List payload;
  final InternetAddress destination;
  final int port;
  final bool broadcast;
}

class FakeUdpSender implements UdpSender {
  final List<SentDatagram> sent = [];

  /// Error a lanzar por dirección de destino.
  final Map<String, Object> failures = {};

  @override
  Future<void> send(
    Uint8List payload,
    InternetAddress destination,
    int port, {
    bool broadcast = false,
  }) async {
    final failure = failures[destination.address];
    if (failure != null) throw failure;
    sent.add(SentDatagram(payload, destination, port, broadcast));
  }
}

class FakeAddressResolver implements AddressResolver {
  final Map<String, List<InternetAddress>> records = {};
  final List<String> queried = [];

  @override
  Future<List<InternetAddress>> resolve(
    String host,
    InternetAddressType type,
  ) async {
    queried.add(host);
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return [literal];
    final found = records[host]?.where((a) => a.type == type).toList();
    if (found == null || found.isEmpty) {
      throw AddressResolutionException('No se pudo resolver $host.');
    }
    return found;
  }
}

class FakeReachabilityProbe implements ReachabilityProbe {
  FakeReachabilityProbe([this.status = ReachabilityStatus.unverifiable]);

  ReachabilityStatus status;
  int calls = 0;

  @override
  Future<ReachabilityResult> probe(InternetAddress address, int port) async {
    calls++;
    return ReachabilityResult(status, 'fake ${address.address}:$port');
  }
}

class InMemoryDeviceRepository implements DeviceRepository {
  InMemoryDeviceRepository([List<Device>? initial]) : stored = [...?initial];

  List<Device> stored;
  bool failOnSave = false;
  int saves = 0;

  @override
  Future<List<Device>> loadAll() async => [...stored];

  @override
  Future<void> saveAll(List<Device> devices) async {
    if (failOnSave) throw const StorageException('fallo simulado');
    saves++;
    stored = [...devices];
  }
}

class FakeNetworkInspector implements LocalNetworkInspector {
  FakeNetworkInspector(this.snapshot);

  final LocalNetworkSnapshot snapshot;

  @override
  Future<LocalNetworkSnapshot> inspect() async => snapshot;
}

class InMemoryAgentKeyStore implements AgentKeyStore {
  final Map<String, AgentKey> keys = {};

  @override
  Future<AgentKey?> read(String deviceId) async => keys[deviceId];

  @override
  Future<void> write(String deviceId, AgentKey key) async => keys[deviceId] = key;

  @override
  Future<void> delete(String deviceId) async => keys.remove(deviceId);
}

class FakePowerControl implements PowerControlService {
  FakePowerControl([this.outcome = AgentCallOutcome.accepted]);

  AgentCallOutcome outcome;
  final List<AgentCommand> commands = [];

  @override
  Future<AgentCallResult> run(Device device, AgentCommand command) async {
    commands.add(command);
    return AgentCallResult(outcome, 'resultado simulado: ${outcome.name}');
  }
}

SocketException socketError(int code, [String message = 'error']) =>
    SocketException(message, osError: OSError(message, code));
