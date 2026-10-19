import 'package:altair_agent_protocol/altair_agent_protocol.dart';
import 'package:flutter/material.dart';

import '../../../core/network/mac_address.dart';
import '../../../core/network/network_validators.dart';
import '../../../core/storage/id_generator.dart';
import '../../remote_desktop/domain/monitor_layout.dart';
import '../../remote_desktop/domain/remote_desktop.dart';
import '../../remote_desktop/presentation/monitor_layout_field.dart';
import '../domain/device.dart';

/// Resultado del formulario. [newAgentKey] es `null` si no se ingresó una
/// clave nueva (se conserva la guardada, si existe).
class DeviceFormResult {
  const DeviceFormResult(this.device, this.newAgentKey);

  final Device device;
  final AgentKey? newAgentKey;
}

/// Alta y edición de un dispositivo. Devuelve un [DeviceFormResult] con
/// `Navigator.pop`, o `null` si se cancela.
class DeviceFormScreen extends StatefulWidget {
  const DeviceFormScreen({super.key, this.initial, this.hasStoredAgentKey = false});

  final Device? initial;

  /// Si ya hay una clave del agente guardada para [initial].
  final bool hasStoredAgentKey;

  @override
  State<DeviceFormScreen> createState() => _DeviceFormScreenState();
}

class _DeviceFormScreenState extends State<DeviceFormScreen> {
  static const int _maxNameLength = 40;

  /// El puerto del agente tiene un proceso escuchando y responde aunque la
  /// red de Windows esté en perfil Público.
  static const int _suggestedProbePort = defaultAgentPort;

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _mac;
  late final TextEditingController _localIpv4;
  late final TextEditingController _broadcast;
  late final TextEditingController _lanPort;
  late final TextEditingController _probePort;
  late final TextEditingController _ipv6;
  late final TextEditingController _remoteHost;
  late final TextEditingController _remotePort;
  late final TextEditingController _agentPort;
  late final TextEditingController _agentKey;
  late final TextEditingController _remoteDesktopPort;
  late MonitorLayout? _remoteDesktopMonitors;
  late RemoteAccessMode _remoteMode;

  bool get _isEditing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final d = widget.initial;
    _name = TextEditingController(text: d?.name);
    _mac = TextEditingController(text: d?.mac.toString());
    _localIpv4 = TextEditingController(text: d?.localIpv4);
    _broadcast = TextEditingController(
      text: d?.broadcastAddress ?? limitedBroadcastAddress,
    );
    _lanPort = TextEditingController(
      text: '${d?.lanPort ?? defaultWakeOnLanPort}',
    );
    _probePort = TextEditingController(
      text: d == null ? '$_suggestedProbePort' : d.probePort?.toString(),
    );
    _ipv6 = TextEditingController(text: d?.ipv6Address);
    _remoteHost = TextEditingController(text: d?.remoteHost);
    _remotePort = TextEditingController(
      text: '${d?.remotePort ?? defaultWakeOnLanPort}',
    );
    _remoteMode = d?.remoteMode ?? RemoteAccessMode.none;
    _agentPort = TextEditingController(text: d?.agentPort?.toString());
    _agentKey = TextEditingController();
    _remoteDesktopPort = TextEditingController(
      text: d?.remoteDesktopPort?.toString(),
    );
    _remoteDesktopMonitors = MonitorLayout.tryParse(d?.remoteDesktopMonitors);
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _mac,
      _localIpv4,
      _broadcast,
      _lanPort,
      _probePort,
      _ipv6,
      _remoteHost,
      _remotePort,
      _agentPort,
      _agentKey,
      _remoteDesktopPort,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    String? optional(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    final initial = widget.initial;
    final device = Device(
      id: initial?.id ?? generateId(),
      name: _name.text.trim(),
      mac: MacAddress.parse(_mac.text),
      localIpv4: optional(_localIpv4),
      broadcastAddress: _broadcast.text.trim(),
      lanPort: int.parse(_lanPort.text.trim()),
      ipv6Address: optional(_ipv6),
      remoteMode: _remoteMode,
      remoteHost: _remoteMode == RemoteAccessMode.none
          ? null
          : optional(_remoteHost),
      remotePort: int.parse(_remotePort.text.trim()),
      probePort: int.tryParse(_probePort.text.trim()),
      agentPort: int.tryParse(_agentPort.text.trim()),
      remoteDesktopPort: int.tryParse(_remoteDesktopPort.text.trim()),
      remoteDesktopMonitors: _remoteDesktopMonitors?.format(),
      lastAttempt: initial?.lastAttempt,
    );
    final keyText = _agentKey.text.trim();
    Navigator.of(context).pop(
      DeviceFormResult(device, keyText.isEmpty ? null : AgentKey.parse(keyText)),
    );
  }

  String? _validateRemoteHost(String? value) {
    switch (_remoteMode) {
      case RemoteAccessMode.none:
        return null;
      case RemoteAccessMode.ipv4:
        return HostValidator.validateRemoteHost(value, family: HostKind.ipv4);
      case RemoteAccessMode.ipv6:
        final hasIpv6 = _ipv6.text.trim().isNotEmpty;
        return HostValidator.validateRemoteHost(
          value,
          family: HostKind.ipv6,
          required: !hasIpv6,
        );
    }
  }

  String? _validateAgentKey(String? value) {
    final text = value?.trim() ?? '';
    if (_agentPort.text.trim().isEmpty) return null;
    if (text.isEmpty) {
      return widget.hasStoredAgentKey
          ? null
          : 'Pega la clave que generó install.ps1.';
    }
    return AgentKey.tryParse(text) == null
        ? 'Clave inválida: deben ser 43 caracteres base64url.'
        : null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Editar equipo' : 'Nuevo equipo'),
        actions: [
          TextButton(onPressed: _submit, child: const Text('Guardar')),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _buildFields(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildFields(BuildContext context) {
    const gap = SizedBox(height: 16);
    return [
      const _SectionTitle('Identificación'),
      TextFormField(
        controller: _name,
        decoration: const InputDecoration(labelText: 'Nombre'),
        maxLength: _maxNameLength,
        textInputAction: TextInputAction.next,
        validator: (v) =>
            (v == null || v.trim().isEmpty) ? 'Ingresa un nombre.' : null,
      ),
      gap,
      TextFormField(
        controller: _mac,
        decoration: const InputDecoration(
          labelText: 'Dirección MAC',
          hintText: 'AA:BB:CC:DD:EE:FF',
          helperText: 'En Windows: ipconfig /all → "Dirección física".',
        ),
        textCapitalization: TextCapitalization.characters,
        autocorrect: false,
        validator: MacAddress.validate,
      ),
      const _SectionTitle('Red local'),
      TextFormField(
        controller: _localIpv4,
        decoration: const InputDecoration(
          labelText: 'IPv4 local (opcional)',
          hintText: '192.168.100.20',
          helperText: 'Resérvala en el router (DHCP Static IP). Se usa para '
              'verificar el estado.',
          helperMaxLines: 2,
        ),
        keyboardType: TextInputType.number,
        validator: HostValidator.validateIpv4,
      ),
      gap,
      TextFormField(
        controller: _broadcast,
        decoration: const InputDecoration(
          labelText: 'Dirección de difusión',
          helperText: 'Difusión de tu subred (ej. 192.168.100.255) o '
              '255.255.255.255.',
          helperMaxLines: 2,
        ),
        keyboardType: TextInputType.number,
        validator: (v) => HostValidator.validateIpv4(v, required: true),
      ),
      gap,
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextFormField(
              controller: _lanPort,
              decoration: const InputDecoration(
                labelText: 'Puerto UDP',
                helperText: '9 por convención',
              ),
              keyboardType: TextInputType.number,
              validator: PortValidator.validate,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextFormField(
              controller: _probePort,
              decoration: const InputDecoration(
                labelText: 'Puerto TCP de sondeo',
                helperText: 'Por defecto, el del agente. Vacío la desactiva',
                helperMaxLines: 2,
              ),
              keyboardType: TextInputType.number,
              validator: (v) => PortValidator.validate(v, required: false),
            ),
          ),
        ],
      ),
      gap,
      TextFormField(
        controller: _ipv6,
        decoration: const InputDecoration(
          labelText: 'IPv6 global del equipo (opcional)',
          helperText: 'Se usa para el sondeo y como destino del modo IPv6.',
          helperMaxLines: 2,
        ),
        keyboardType: TextInputType.url,
        autocorrect: false,
        validator: HostValidator.validateGlobalIpv6,
      ),
      const _SectionTitle('Acceso remoto'),
      SegmentedButton<RemoteAccessMode>(
        segments: const [
          ButtonSegment(value: RemoteAccessMode.none, label: Text('Ninguno')),
          ButtonSegment(value: RemoteAccessMode.ipv4, label: Text('IPv4')),
          ButtonSegment(value: RemoteAccessMode.ipv6, label: Text('IPv6')),
        ],
        selected: {_remoteMode},
        // Sin el icono de selección, "Ninguno" cabe en una línea en móviles.
        showSelectedIcon: false,
        onSelectionChanged: (selection) =>
            setState(() => _remoteMode = selection.single),
      ),
      gap,
      _RemoteModeNotice(mode: _remoteMode),
      if (_remoteMode != RemoteAccessMode.none) ...[
        gap,
        TextFormField(
          controller: _remoteHost,
          decoration: InputDecoration(
            labelText: _remoteMode == RemoteAccessMode.ipv4
                ? 'IPv4 pública o nombre DNS'
                : 'IPv6 o nombre DNS (opcional si hay IPv6 global)',
            helperMaxLines: 2,
          ),
          keyboardType: TextInputType.url,
          autocorrect: false,
          validator: _validateRemoteHost,
        ),
        gap,
        TextFormField(
          controller: _remotePort,
          decoration: const InputDecoration(labelText: 'Puerto UDP remoto'),
          keyboardType: TextInputType.number,
          validator: PortValidator.validate,
        ),
      ],
      const _SectionTitle('Agente de Windows (opcional)'),
      const Text(
        'Permite consultar el estado, suspender y apagar el equipo desde la '
        'red local. Requiere instalar el agente en el PC.',
      ),
      gap,
      TextFormField(
        controller: _agentPort,
        decoration: const InputDecoration(
          labelText: 'Puerto TCP del agente',
          hintText: '',
          helperText: 'Vacío desactiva las órdenes al agente.',
        ),
        keyboardType: TextInputType.number,
        validator: (v) => PortValidator.validate(v, required: false),
      ),
      gap,
      TextFormField(
        controller: _agentKey,
        decoration: InputDecoration(
          labelText: 'Clave del agente',
          helperText: widget.hasStoredAgentKey
              ? 'Hay una clave guardada. Déjalo vacío para conservarla.'
              : 'Se guarda cifrada en el teléfono.',
          helperMaxLines: 2,
        ),
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        validator: _validateAgentKey,
      ),
      const _SectionTitle('Escritorio remoto (opcional)'),
      const Text(
        'Muestra el botón "Escritorio" cuando el equipo está encendido y abre '
        'el escritorio remoto en la app, hacia su IPv4 local. Solo funciona '
        'en la red de casa.',
      ),
      gap,
      TextFormField(
        controller: _remoteDesktopPort,
        decoration: const InputDecoration(
          labelText: 'Puerto RDP',
          hintText: '$defaultRemoteDesktopPort',
          helperText: 'Vacío oculta el escritorio remoto.',
        ),
        keyboardType: TextInputType.number,
        validator: (v) => PortValidator.validate(v, required: false),
      ),
      gap,
      MonitorLayoutField(
        initial: _remoteDesktopMonitors,
        onChanged: (layout) => _remoteDesktopMonitors = layout,
      ),
      const SizedBox(height: 24),
      FilledButton(onPressed: _submit, child: const Text('Guardar')),
    ];
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 12),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _RemoteModeNotice extends StatelessWidget {
  const _RemoteModeNotice({required this.mode});

  final RemoteAccessMode mode;

  @override
  Widget build(BuildContext context) {
    final text = switch (mode) {
      RemoteAccessMode.none =>
        'El paquete solo se enviará por difusión en la red local.',
      RemoteAccessMode.ipv4 =>
        'Requiere una IPv4 pública asignada por el ISP y un Port Mapping UDP '
            'en el router. Con CGNAT (IPv4 WAN privada) no funcionará. '
            'Cualquiera que conozca la IP y el puerto podrá enviar paquetes.',
      RemoteAccessMode.ipv6 =>
        'Requiere que el firewall IPv6 del router permita UDP entrante hacia '
            'el equipo y que el router conserve su MAC (NDP). Funcionamiento '
            'pendiente de verificar en tu red.',
    };
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 20, color: scheme.onSecondaryContainer),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
