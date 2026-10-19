import 'package:flutter/material.dart';

import '../domain/monitor_layout.dart';

/// Selector de los monitores del PC: cuántos hay y la resolución de cada
/// uno. "Auto" (ninguno) deja que la sesión use la pantalla del móvil.
class MonitorLayoutField extends StatefulWidget {
  const MonitorLayoutField({super.key, this.initial, required this.onChanged});

  final MonitorLayout? initial;
  final ValueChanged<MonitorLayout?> onChanged;

  /// Monitores que ofrece el selector (más si ya había más guardados).
  static const int selectableMonitors = 4;

  static const Size defaultResolution = Size(1920, 1080);

  @override
  State<MonitorLayoutField> createState() => _MonitorLayoutFieldState();
}

class _MonitorLayoutFieldState extends State<MonitorLayoutField> {
  /// Resoluciones elegidas; se conservan al bajar el número de monitores
  /// para recuperarlas si se vuelve a subir.
  late final List<Size> _resolutions = [...?widget.initial?.monitors];
  late int _count = _resolutions.length;

  /// Cambia la clave de los menús para que muestren el valor real aunque se
  /// cancele "Otra…".
  int _revision = 0;

  late final int _maxCount = _count > MonitorLayoutField.selectableMonitors
      ? _count
      : MonitorLayoutField.selectableMonitors;

  void _setCount(int count) {
    while (_resolutions.length < count) {
      _resolutions.add(
        _resolutions.isEmpty ? MonitorLayoutField.defaultResolution : _resolutions.last,
      );
    }
    setState(() => _count = count);
    _notify();
  }

  Future<void> _setResolution(int index, Size? choice) async {
    final size = choice == _customChoice ? await _askCustom(index) : choice;
    if (!mounted) return;
    setState(() {
      _revision++;
      if (size != null) _resolutions[index] = size;
    });
    if (size != null) _notify();
  }

  Future<Size?> _askCustom(int index) => showDialog<Size>(
    context: context,
    builder: (_) => _CustomResolutionDialog(
      initial: MonitorLayout.formatResolution(_resolutions[index]),
    ),
  );

  void _notify() => widget.onChanged(
    _count == 0 ? null : MonitorLayout(_resolutions.take(_count).toList()),
  );

  /// Valor del menú que abre el diálogo de resolución personalizada.
  static const Size _customChoice = Size.zero;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Monitores del PC', style: theme.textTheme.bodyLarge),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: [
            const ButtonSegment(value: 0, label: Text('Auto')),
            for (var count = 1; count <= _maxCount; count++)
              ButtonSegment(value: count, label: Text('$count')),
          ],
          selected: {_count},
          showSelectedIcon: false,
          onSelectionChanged: (selection) => _setCount(selection.single),
        ),
        const SizedBox(height: 8),
        Text(
          _count == 0
              ? 'La sesión usa la resolución de la pantalla del teléfono.'
              : 'Ordénalos de izquierda a derecha como en Windows '
                    '(Configuración → Pantalla), con el principal primero.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        for (var index = 0; index < _count; index++) ...[
          const SizedBox(height: 12),
          _ResolutionDropdown(
            key: ValueKey('monitor-$index-$_revision'),
            label: index == 0 ? 'Monitor 1 (principal)' : 'Monitor ${index + 1}',
            value: _resolutions[index],
            customChoice: _customChoice,
            onChanged: (choice) => _setResolution(index, choice),
          ),
        ],
      ],
    );
  }
}

class _ResolutionDropdown extends StatelessWidget {
  const _ResolutionDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.customChoice,
    required this.onChanged,
  });

  final String label;
  final Size value;
  final Size customChoice;
  final ValueChanged<Size?> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = {...MonitorLayout.commonResolutions, value}.toList()
      ..sort((a, b) => (a.width * a.height).compareTo(b.width * b.height));
    return DropdownButtonFormField<Size>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final size in options)
          DropdownMenuItem(
            value: size,
            child: Text(MonitorLayout.formatResolution(size)),
          ),
        DropdownMenuItem(value: customChoice, child: const Text('Otra…')),
      ],
      onChanged: onChanged,
    );
  }
}

/// Pide una resolución que no está en la lista, p. ej. "1152x720".
class _CustomResolutionDialog extends StatefulWidget {
  const _CustomResolutionDialog({required this.initial});

  final String initial;

  @override
  State<_CustomResolutionDialog> createState() => _CustomResolutionDialogState();
}

class _CustomResolutionDialogState extends State<_CustomResolutionDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(context, MonitorLayout.tryParseResolution(_text.text));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Otra resolución'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _text,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Ancho x alto',
            hintText: '1152x720',
          ),
          keyboardType: TextInputType.visiblePassword,
          autocorrect: false,
          onFieldSubmitted: (_) => _submit(),
          validator: (value) => MonitorLayout.tryParseResolution(value ?? '') == null
              ? 'Formato: 1152x720 (entre ${MonitorLayout.minSide} y '
                    '${MonitorLayout.maxSide} px por lado)'
              : null,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Aceptar')),
      ],
    );
  }
}
