import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../models/maestro_terreno.dart';
import '../models/master.dart';
import 'tema.dart';

/// El aviso de que queda en la tablet hasta la próxima sincronización.
const String kQuedaEnLaTablet = 'Se guarda en la tablet y se sube con la próxima sincronización. '
    'Contactos, productos, modelo y usuarios se completan después en la web.';

/// Crear o editar un cliente en terreno: nombre y RUT. Devuelve el cliente guardado (o null si se canceló).
class FichaClienteScreen extends StatefulWidget {
  /// Null = uno nuevo.
  final ClientRef? cliente;
  const FichaClienteScreen({super.key, this.cliente});

  @override
  State<FichaClienteScreen> createState() => _FichaClienteScreenState();
}

class _FichaClienteScreenState extends State<FichaClienteScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _nombre = TextEditingController(text: widget.cliente?.name ?? '');
  late final TextEditingController _rut = TextEditingController(text: widget.cliente?.legalId ?? '');
  bool _guardando = false;

  bool get _nuevo => widget.cliente == null;

  @override
  void dispose() {
    _nombre.dispose();
    _rut.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    if (_guardando || !(_form.currentState?.validate() ?? false)) return;
    final db = context.read<AppDatabase>();
    final nombre = textoONulo(_nombre.text)!;
    final rut = textoONulo(_rut.text);
    setState(() => _guardando = true);
    try {
      // El mismo RUT (o, sin RUT, el mismo nombre) que otro de la tablet: se pregunta antes. Si se crea igual, el
      // servidor lo marca para que AOLAB lo revise en la web.
      final otros = (await db.activeClients()).where((c) => c.id != widget.cliente?.id);
      final parecido = otros.where((c) => parecenElMismo(nombre, rut, c.name, c.legalId)).firstOrNull;
      if (parecido != null && mounted) {
        final seguir = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.content_copy, color: Colores.avisoIcono),
            title: const Text('¿Es el mismo cliente?'),
            content: Text('Ya existe «${parecido.name}»${parecido.legalId == null ? '' : ' (RUT ${parecido.legalId})'}. '
                'Si es el mismo, cancela y búscalo en la lista. Si lo guardas igual, AOLAB lo revisará en la web.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar igual')),
            ],
          ),
        );
        if (seguir != true) return;
      }
      final c = ClientRef(id: widget.cliente?.id ?? const Uuid().v4(), name: nombre, legalId: rut);
      await db.guardarClienteLocal(c, nuevo: _nuevo);
      if (mounted) Navigator.of(context).pop(c);
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Ficha(
        titulo: _nuevo ? 'Nuevo cliente' : 'Editar cliente',
        form: _form,
        guardando: _guardando,
        alGuardar: _guardar,
        campos: [
          TextFormField(
            key: const ValueKey('campo-nombre'),
            controller: _nombre,
            autofocus: _nuevo,
            textCapitalization: TextCapitalization.words,
            maxLength: 300,
            decoration: const InputDecoration(labelText: 'Nombre del cliente *', border: OutlineInputBorder()),
            validator: (v) => textoONulo(v) == null ? 'Escribe el nombre' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('campo-rut'),
            controller: _rut,
            maxLength: 20,
            decoration: const InputDecoration(labelText: 'RUT', hintText: '76.123.456-K', border: OutlineInputBorder()),
          ),
        ],
      );
}

/// Crear o editar una piscicultura (centro) de un cliente: nombre, código y coordenadas. Devuelve la piscicultura
/// guardada (o null si se canceló). El cliente dueño se fija al crearla; cambiarlo es de la web.
class FichaCentroScreen extends StatefulWidget {
  final String clienteId;
  final String clienteNombre;

  /// Null = una nueva.
  final CenterRef? centro;

  /// La primera del cliente recién creado: se dice, y se puede dejar para después.
  final bool primera;

  const FichaCentroScreen({
    super.key,
    required this.clienteId,
    required this.clienteNombre,
    this.centro,
    this.primera = false,
  });

  @override
  State<FichaCentroScreen> createState() => _FichaCentroScreenState();
}

class _FichaCentroScreenState extends State<FichaCentroScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _nombre = TextEditingController(text: widget.centro?.name ?? '');
  late final TextEditingController _codigo = TextEditingController(text: widget.centro?.code ?? '');
  late final TextEditingController _lat = TextEditingController(text: _num(widget.centro?.latitude));
  late final TextEditingController _lon = TextEditingController(text: _num(widget.centro?.longitude));
  bool _guardando = false;

  bool get _nuevo => widget.centro == null;

  static String _num(double? v) => v == null ? '' : v.toString();

  @override
  void dispose() {
    for (final c in [_nombre, _codigo, _lat, _lon]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _guardar() async {
    if (_guardando || !(_form.currentState?.validate() ?? false)) return;
    final db = context.read<AppDatabase>();
    setState(() => _guardando = true);
    try {
      final antes = widget.centro;
      final c = CenterRef(
        id: antes?.id ?? const Uuid().v4(),
        name: textoONulo(_nombre.text)!,
        code: textoONulo(_codigo.text),
        latitude: coordenada(_lat.text),
        longitude: coordenada(_lon.text),
        ownerClientId: antes?.ownerClientId ?? widget.clienteId,
        // Lo que no se edita aquí queda como estaba.
        operatorName: antes?.operatorName,
        afluenteMode: antes?.afluenteMode ?? 'single',
        afluente: antes?.afluente,
        sistemas: antes?.sistemas,
        modeloVersion: antes?.modeloVersion ?? 1,
        serverVersion: antes?.serverVersion ?? 0,
      );
      await db.guardarCentroLocal(c, nuevo: _nuevo);
      if (mounted) Navigator.of(context).pop(c);
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Ficha(
        titulo: _nuevo ? (widget.primera ? 'Su primera piscicultura' : 'Nueva piscicultura') : 'Editar piscicultura',
        subtitulo: widget.clienteNombre,
        form: _form,
        guardando: _guardando,
        alGuardar: _guardar,
        textoCancelar: widget.primera ? 'Después' : 'Cancelar',
        campos: [
          TextFormField(
            key: const ValueKey('campo-nombre'),
            controller: _nombre,
            autofocus: _nuevo,
            textCapitalization: TextCapitalization.words,
            maxLength: 300,
            decoration: const InputDecoration(labelText: 'Nombre de la piscicultura *', border: OutlineInputBorder()),
            validator: (v) => textoONulo(v) == null ? 'Escribe el nombre' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('campo-codigo'),
            controller: _codigo,
            maxLength: 50,
            decoration: const InputDecoration(
                labelText: 'Código del centro', hintText: 'Sernapesca o interno', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          const Text('Ubicación (grados decimales, WGS84)', style: TextStyle(fontSize: 14, color: Colores.texto2)),
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextFormField(
                key: const ValueKey('campo-latitud'),
                controller: _lat,
                keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                decoration: const InputDecoration(labelText: 'Latitud', hintText: '-41.4693', border: OutlineInputBorder()),
                validator: (v) => errorCoordenada(v, latitud: true),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                key: const ValueKey('campo-longitud'),
                controller: _lon,
                keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                decoration: const InputDecoration(labelText: 'Longitud', hintText: '-72.9424', border: OutlineInputBorder()),
                validator: (v) => errorCoordenada(v, latitud: false),
              ),
            ),
          ]),
        ],
      );
}

/// El armazón común de las dos fichas.
class _Ficha extends StatelessWidget {
  final String titulo;
  final String? subtitulo;
  final GlobalKey<FormState> form;
  final List<Widget> campos;
  final bool guardando;
  final VoidCallback alGuardar;
  final String textoCancelar;

  const _Ficha({
    required this.titulo,
    this.subtitulo,
    required this.form,
    required this.campos,
    required this.guardando,
    required this.alGuardar,
    this.textoCancelar = 'Cancelar',
  });

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (subtitulo != null)
              Text(subtitulo!, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: Colores.texto2)),
            Text(titulo, key: const ValueKey('titulo-ficha')),
          ]),
        ),
        body: Form(
          key: form,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            ...campos,
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colores.infoFondo, borderRadius: BorderRadius.circular(8)),
              child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.cloud_upload_outlined, size: 20, color: Colores.texto2),
                SizedBox(width: 8),
                Expanded(child: Text(kQuedaEnLaTablet, style: TextStyle(fontSize: 13, color: Colores.texto2))),
              ]),
            ),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                  key: const ValueKey('cancelar-ficha'),
                  onPressed: guardando ? null : () => Navigator.of(context).pop(),
                  child: Text(textoCancelar)),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const ValueKey('guardar-ficha'),
                onPressed: guardando ? null : alGuardar,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Guardar'),
              ),
            ]),
          ]),
        ),
      );
}
