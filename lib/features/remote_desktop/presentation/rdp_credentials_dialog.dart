import 'package:flutter/material.dart';

class RdpCredentials {
  const RdpCredentials(this.username, this.password, {this.allMonitors = false});

  final String username;
  final String password;

  /// Usar todos los monitores configurados del PC en lugar del principal.
  final bool allMonitors;
}

/// Pide usuario y contraseña de Windows para una sesión. No se guardan.
class RdpCredentialsDialog extends StatefulWidget {
  const RdpCredentialsDialog({
    super.key,
    required this.deviceName,
    this.monitorCount = 1,
  });

  final String deviceName;

  /// Monitores configurados del PC; con más de uno se ofrece usarlos todos.
  final int monitorCount;

  @override
  State<RdpCredentialsDialog> createState() => _RdpCredentialsDialogState();
}

class _RdpCredentialsDialogState extends State<RdpCredentialsDialog> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  late bool _allMonitors = widget.monitorCount > 1;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      RdpCredentials(
        _username.text.trim(),
        _password.text,
        allMonitors: widget.monitorCount > 1 && _allMonitors,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Conectar a ${widget.deviceName}'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _username,
              decoration: const InputDecoration(labelText: 'Usuario de Windows'),
              autocorrect: false,
              enableSuggestions: false,
              autofocus: true,
              textInputAction: TextInputAction.next,
              validator: (value) =>
                  (value?.trim().isEmpty ?? true) ? 'Escribe el usuario.' : null,
            ),
            TextFormField(
              controller: _password,
              decoration: const InputDecoration(
                labelText: 'Contraseña',
                helperText: 'Vacía si la cuenta no tiene contraseña.',
              ),
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              onFieldSubmitted: (_) => _submit(),
            ),
            if (widget.monitorCount > 1)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Usar los ${widget.monitorCount} monitores'),
                subtitle: _allMonitors ? null : const Text('Solo el principal'),
                value: _allMonitors,
                onChanged: (value) => setState(() => _allMonitors = value),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Conectar')),
      ],
    );
  }
}
