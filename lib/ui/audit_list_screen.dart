import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../data/reglas_sync.dart';
import '../models/audit.dart';
import '../models/master.dart';
import '../services/audit_sync_service.dart';
import '../services/auth_service.dart';
import '../services/evidencias_en_fila.dart';
import '../services/master_sync_service.dart';
import '../services/media_service.dart';
import '../services/template_service.dart';
import 'arbol_evaluaciones.dart';
import 'audit_edit_screen.dart';
import 'ficha_maestro.dart';
import 'login_screen.dart';
import 'tema.dart';

/// Los filtros de la lista, por estado.
enum FiltroLista { todas, agendadas, enCurso, finalizadas }

extension FiltroListaX on FiltroLista {
  String get etiqueta => switch (this) {
        FiltroLista.todas => 'Todas',
        FiltroLista.agendadas => 'Agendadas',
        FiltroLista.enCurso => 'En curso',
        FiltroLista.finalizadas => 'Finalizadas',
      };

  bool incluye(Audit a) => switch (this) {
        FiltroLista.todas => true,
        FiltroLista.agendadas => a.statusEnum == AuditStatus.scheduled,
        FiltroLista.enCurso => a.statusEnum == AuditStatus.draft,
        FiltroLista.finalizadas => a.isLocked,
      };
}

/// ¿Se puede borrar desde la tablet? Solo una Agendada que se creó aquí y nunca llegó al servidor (creada por error).
bool sePuedeBorrar(Audit a) => a.statusEnum == AuditStatus.scheduled && a.serverVersion == 0;

/// La fecha de la evaluación para la lista: la agendada o la de muestreo; una recién creada, la de creación.
DateTime fechaDe(Audit a) => a.scheduledForUtc ?? a.sampledAtUtc ?? a.createdAtUtc;

String fmtFecha(DateTime utc) {
  final d = utc.toLocal();
  return '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
}

class AuditListScreen extends StatefulWidget {
  const AuditListScreen({super.key});

  @override
  State<AuditListScreen> createState() => _AuditListScreenState();
}

/// Los tres niveles de la lista: se navega Cliente → Piscicultura → sus evaluaciones.
enum NivelLista { clientes, pisciculturas, evaluaciones }

class _AuditListScreenState extends State<AuditListScreen> {
  List<ClientRef> _clientes = [];
  List<CenterRef> _centros = [];
  List<GrupoCliente> _grupos = [];
  int _pending = 0;
  // Lo elegido al navegar: la clave del grupo y su nombre (null = todavía no se elige). Con un solo cliente no se elige:
  // se parte en sus pisciculturas.
  String? _clienteSel;
  String? _nombreClienteSel;
  String? _centroSel;
  String? _nombreCentroSel;
  bool _loading = true;
  FiltroLista _filtro = FiltroLista.todas;
  // Clientes y pisciculturas en terreno: si esta cuenta los puede crear y editar (lo dice el servidor) y cuáles tienen
  // cambios sin subir.
  bool _puedeEditar = false;
  Set<String> _maestrosPorSubir = {};
  bool _outdated = false;
  String _outdatedMsg = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  // La lista sale al tiro desde la tablet; la plantilla se refresca en segundo plano (con mala señal no se espera).
  Future<void> _init() async {
    final tpl = context.read<TemplateService>();
    final db = context.read<AppDatabase>();
    final media = context.read<MediaService>();
    await tpl.cargarLocal();
    await _reload();
    unawaited(tpl.refrescar());
    // Si Android cerró la app con la cámara abierta, la foto se recupera y vuelve a su punto.
    final recuperada = await FotoEnCurso.recuperar(db, media);
    if (recuperada != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Se recuperó la foto de «$recuperada».')));
      await _reload();
    }
    if (mounted) _sync();
    _checkVersion();
  }

  // Correlación de versión Web↔App: si el build es menor al mínimo del servidor, avisa.
  Future<void> _checkVersion() async {
    final api = context.read<AuthService>().api;
    try {
      final info = await PackageInfo.fromPlatform();
      final build = int.tryParse(info.buildNumber) ?? 0;
      final res = await api.dio.get('/api/app/version');
      final minBuild = (res.data['minBuild'] ?? 0) as int;
      if (build < minBuild && mounted) {
        setState(() {
          _outdated = true;
          _outdatedMsg = (res.data['message'] ?? 'Tu aplicación está desactualizada. Actualízala.') as String;
        });
      }
    } catch (_) {/* sin red o error: no bloquear */}
  }

  Future<void> _reload() async {
    final db = context.read<AppDatabase>();
    final media = context.read<MediaService>();
    final audits = await db.visibleAudits();
    final clientes = await db.activeClients();
    final centros = await db.activeCenters();
    final pending = await pendientesDeLaTablet(db, media); // deja lista la carpeta de las evidencias (hasLocal)
    final puedeEditar = await db.getValue(MasterSyncService.llavePermiso) == '1';
    final maestrosPorSubir = await db.idsMaestrosPendientes();
    final porSubir = {
      for (final a in audits)
        if (quedaPorSubir(a, enEstaTablet: media.hasLocal)) a.id,
    };
    if (!mounted) return;
    setState(() {
      _clientes = clientes;
      _centros = centros;
      _grupos = agruparEvaluaciones(
          evaluaciones: audits, clientes: clientes, centros: centros, porSubir: porSubir, clientesSiempre: maestrosPorSubir);
      _pending = pending;
      _puedeEditar = puedeEditar;
      _maestrosPorSubir = maestrosPorSubir;
      _loading = false;
    });
  }

  // ── Navegación: Cliente → Piscicultura → evaluaciones ──

  /// Con un solo cliente (o solo «Sin cliente») no hay nada que elegir: se parte en sus pisciculturas. Salvo para quien
  /// puede crear clientes: «Nuevo cliente» está en el nivel de los clientes.
  bool get _saltaClientes => _grupos.length == 1 && !_puedeEditar;

  /// El cliente en que se está (el elegido o el único), o null en el nivel de clientes.
  GrupoCliente? get _cliente {
    final clave = _clienteSel ?? (_saltaClientes ? _grupos.single.clave : null);
    if (clave == null) return null;
    for (final g in _grupos) {
      if (g.clave == clave) return g;
    }
    // Se fue su última evaluación (se le cambió el cliente): queda vacío, con el nombre que tenía.
    return GrupoCliente(clave == kSinAsignar ? null : clave, _nombreClienteSel ?? kSinCliente);
  }

  /// La piscicultura en que se está, o null si no se ha elegido.
  GrupoCentro? get _centro {
    final g = _cliente;
    final clave = _centroSel;
    if (g == null || clave == null) return null;
    return g.centro(clave) ?? GrupoCentro(clave == kSinAsignar ? null : clave, _nombreCentroSel ?? kSinPiscicultura);
  }

  NivelLista get _nivel => _cliente == null
      ? NivelLista.clientes
      : _centro == null
          ? NivelLista.pisciculturas
          : NivelLista.evaluaciones;

  /// ¿Se está en el primer nivel? Ahí «atrás» sale de la app; en los otros, sube un nivel.
  bool get _enRaiz => _nivel == NivelLista.clientes || (_nivel == NivelLista.pisciculturas && _clienteSel == null);

  void _elegirCliente(GrupoCliente g) => setState(() {
        _clienteSel = g.clave;
        _nombreClienteSel = g.nombre;
        _centroSel = null;
      });

  void _elegirCentro(GrupoCentro c) => setState(() {
        _centroSel = c.clave;
        _nombreCentroSel = c.nombre;
      });

  void _subir() => setState(() {
        if (_nivel == NivelLista.evaluaciones) {
          _centroSel = null;
        } else {
          _clienteSel = null;
          _centroSel = null;
        }
      });

  void _irAClientes() => setState(() {
        _clienteSel = null;
        _centroSel = null;
      });

  Future<void> _sync() async {
    await context.read<AuditSyncService>().sync();
    await _reload();
  }

  /// La sesión venció: se vuelve a entrar (con la misma cuenta) y se sincroniza. Nada local se pierde.
  Future<void> _reingresar() async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const LoginScreen(reingreso: true)));
    if (ok == true && mounted) _sync();
  }

  /// Cerrar sesión no borra nada de la tablet, pero lo que falta subir queda esperando a que vuelva a entrar la misma
  /// persona: se avisa y se ofrece sincronizar antes.
  Future<void> _cerrarSesion() async {
    final auth = context.read<AuthService>();
    final db = context.read<AppDatabase>();
    final media = context.read<MediaService>();
    final pendientes = await pendientesDeLaTablet(db, media);
    if (!mounted) return;
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cerrar sesión'),
        content: Text(pendientes == 0
            ? '¿Cerrar la sesión de ${auth.email ?? 'esta cuenta'}?'
            : 'Hay ${pendientes == 1 ? '1 evaluación' : '$pendientes evaluaciones'} sin subir. Quedan guardadas en la tablet, '
                'pero solo se suben cuando vuelvas a entrar con ${auth.email ?? 'esta cuenta'}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          if (pendientes > 0 && !auth.sesionVencida)
            TextButton(onPressed: () => Navigator.pop(ctx, 'sync'), child: const Text('Sincronizar primero')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'salir'), child: const Text('Cerrar sesión')),
        ],
      ),
    );
    if (!mounted) return;
    if (r == 'sync') {
      await _sync();
    } else if (r == 'salir') {
      await auth.logout();
    }
  }

  Future<void> _create() async {
    final db = context.read<AppDatabase>();
    final now = DateTime.now().toUtc();
    // Creada desde dentro de un cliente o de una piscicultura, nace con ellos elegidos (si siguen activos en el maestro:
    // si no, la ficha no los podría mostrar).
    final cliente = _clientes.where((c) => c.id == _cliente?.id).firstOrNull;
    final centro = _centros.where((c) => c.id == _centro?.id).firstOrNull;
    final audit = Audit(
      id: const Uuid().v4(),
      status: 3, // Agendada: el muestreo (folio/correlativos) se inicia después
      clientId: cliente?.id,
      clientName: cliente?.name,
      centerId: centro?.id,
      centerName: centro?.name ?? '(sin nombre)',
      createdAtUtc: now,
      updatedAtUtc: now,
      // createdByName lo resuelve el servidor (nombre completo del usuario) al pushear.
      // Como en la web, la visita nace sin nada activo: el evaluador marca en cada pestaña la entrevista, la
      // evaluación de terreno (RPN) o el laboratorio. Los sistemas se eligen en la pestaña Sistemas.
      document: AuditDocument.nueva(),
    );
    await db.upsertLocal(audit);
    await _open(audit.id);
  }

  /// Borrar una evaluación creada por error (Agendada, nunca subida): con confirmación. Se marca borrada y el próximo
  /// envío lo avisa al servidor, por si alcanzó a llegar.
  Future<void> _borrar(Audit a) async {
    final db = context.read<AppDatabase>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_outline, color: Colores.peligro),
        title: const Text('Borrar evaluación'),
        content: Text('¿Borrar «${a.tituloCentro} · ${fmtFecha(fechaDe(a))}» de la tablet?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colores.peligro),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await db.softDelete(a.id);
    await _reload();
    if (mounted) _sync();
  }

  // ── Clientes y pisciculturas en terreno (Administrador y Auditor) ──

  ClientRef? _clienteDelMaestro(String? id) => _clientes.where((c) => c.id == id).firstOrNull;
  CenterRef? _centroDelMaestro(String? id) => _centros.where((c) => c.id == id).firstOrNull;

  /// Crea un cliente; luego se entra en él y se ofrece su primera piscicultura (se puede dejar para después).
  Future<void> _nuevoCliente() async {
    final c = await Navigator.of(context).push<ClientRef>(MaterialPageRoute(builder: (_) => const FichaClienteScreen()));
    if (c == null || !mounted) return;
    await _reload();
    if (!mounted) return;
    setState(() {
      _clienteSel = c.id;
      _nombreClienteSel = c.name;
      _centroSel = null;
    });
    await _nuevoCentro(c.id, c.name, primera: true);
  }

  Future<void> _editarCliente(ClientRef c) async {
    final r = await Navigator.of(context).push<ClientRef>(MaterialPageRoute(builder: (_) => FichaClienteScreen(cliente: c)));
    if (r == null || !mounted) return;
    if (_clienteSel == c.id) _nombreClienteSel = r.name;
    await _reload();
    if (mounted) _sync();
  }

  /// Crea una piscicultura del cliente y entra en ella, lista para la primera evaluación («Nueva»).
  Future<void> _nuevoCentro(String clienteId, String clienteNombre, {bool primera = false}) async {
    final c = await Navigator.of(context).push<CenterRef>(MaterialPageRoute(
        builder: (_) => FichaCentroScreen(clienteId: clienteId, clienteNombre: clienteNombre, primera: primera)));
    if (!mounted) return;
    await _reload();
    if (c != null && mounted) {
      setState(() {
        _centroSel = c.id;
        _nombreCentroSel = c.name;
      });
    }
    if (mounted) _sync();
  }

  Future<void> _editarCentro(CenterRef c, String clienteNombre) async {
    final r = await Navigator.of(context).push<CenterRef>(MaterialPageRoute(
        builder: (_) => FichaCentroScreen(clienteId: c.ownerClientId ?? '', clienteNombre: clienteNombre, centro: c)));
    if (r == null || !mounted) return;
    if (_centroSel == c.id) _nombreCentroSel = r.name;
    await _reload();
    if (mounted) _sync();
  }

  /// La fila para crear, arriba de la lista.
  Widget _filaNuevo(String texto, IconData icono, VoidCallback alTocar, {required Key key}) => ListTile(
        key: key,
        leading: Container(
          width: 44,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          decoration: BoxDecoration(color: Colores.marca.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
          child: Icon(icono, color: Colores.marca, size: 20),
        ),
        title: Text(texto, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colores.marca)),
        onTap: alTocar,
      );

  /// El menú «Editar» de la fila de un cliente o una piscicultura.
  Widget _menuEditar(Key key, VoidCallback alEditar) => PopupMenuButton<String>(
        key: key,
        tooltip: 'Opciones',
        onSelected: (_) => alEditar(),
        itemBuilder: (_) => const [
          PopupMenuItem<String>(
            value: 'editar',
            child: Row(children: [Icon(Icons.edit_outlined, size: 20), SizedBox(width: 10), Text('Editar datos')]),
          ),
        ],
      );

  Future<void> _open(String id) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AuditEditScreen(auditId: id)));
    await _reload();
    _sync();
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<AuditSyncService>();
    final nivel = _nivel;
    // «Atrás» (el del AppBar o el de Android) sube un nivel; en el primero, sale como siempre.
    return PopScope(
      canPop: _enRaiz,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _subir();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _enRaiz ? null : BackButton(key: const ValueKey('subir'), onPressed: _subir),
          title: _titulo(nivel),
          actions: [
            IconButton(
              tooltip: 'Sincronizar',
              onPressed: sync.status == SyncStatus.syncing ? null : _sync,
              icon: sync.status == SyncStatus.syncing
                  ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync),
            ),
            // Cerrar sesión va en el menú, con confirmación: en terreno no se cierra por error.
            PopupMenuButton<String>(
              tooltip: 'Más opciones',
              onSelected: (v) {
                if (v == 'salir') _cerrarSesion();
              },
              itemBuilder: (_) => [
                PopupMenuItem<String>(
                  enabled: false,
                  child: Text(context.read<AuthService>().email ?? '', style: const TextStyle(fontSize: 13)),
                ),
                const PopupMenuItem<String>(
                  value: 'salir',
                  child: Row(children: [Icon(Icons.logout, size: 20), SizedBox(width: 10), Text('Cerrar sesión')]),
                ),
              ],
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(30),
            child: StatusBarSync(
                status: sync.status,
                pending: _pending,
                maestros: _maestrosPorSubir.length,
                lastError: sync.lastError,
                lastSyncAt: sync.lastSyncAt),
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _create,
          icon: const Icon(Icons.add),
          label: const Text('Nueva'),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(children: [
                if (_outdated)
                  Material(
                    color: const Color(0xFFD13438),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Row(children: [
                        const Icon(Icons.system_update, color: Colors.white, size: 20),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_outdatedMsg, style: const TextStyle(color: Colors.white, fontSize: 13))),
                      ]),
                    ),
                  ),
                if (context.watch<AuthService>().sesionVencida) _avisoVencida(),
                if (sync.avisos.isNotEmpty) _avisos(sync),
                if (!_enRaiz) _migas(nivel),
                if (nivel == NivelLista.evaluaciones && _centro!.evaluaciones.isNotEmpty) _filtros(),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _sync,
                    child: switch (nivel) {
                      NivelLista.clientes => _listaClientes(),
                      NivelLista.pisciculturas => _listaCentros(_cliente!),
                      NivelLista.evaluaciones => _body(_centro!),
                    },
                  ),
                ),
              ]),
      ),
    );
  }

  /// El título dice dónde se está: «Clientes», el cliente (con «Pisciculturas» encima) o la piscicultura (con su
  /// cliente encima).
  Widget _titulo(NivelLista nivel) {
    final (encima, nombre) = switch (nivel) {
      NivelLista.clientes => (null, 'Clientes'),
      NivelLista.pisciculturas => ('Pisciculturas', _cliente!.nombre),
      NivelLista.evaluaciones => (_cliente!.nombre, _centro!.nombre),
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (encima != null)
        Text(encima,
            key: const ValueKey('titulo-encima'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: Colores.texto2)),
      Text(nombre, key: const ValueKey('titulo'), maxLines: 1, overflow: TextOverflow.ellipsis),
    ]);
  }

  /// El camino recorrido, para volver a cualquier nivel de un toque: Clientes › Cliente › Piscicultura.
  Widget _migas(NivelLista nivel) {
    Widget paso(String texto, VoidCallback? alTocar, {Key? key}) => alTocar == null
        ? Text(texto, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colores.tinta))
        : InkWell(
            key: key,
            onTap: alTocar,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
              child: Text(texto,
                  style: const TextStyle(fontSize: 14, color: Colores.marca, decoration: TextDecoration.underline)),
            ),
          );
    const sep = Padding(
      padding: EdgeInsets.symmetric(horizontal: 4),
      child: Icon(Icons.chevron_right, size: 18, color: Colores.texto2),
    );
    final g = _cliente!;
    return Container(
      width: double.infinity,
      color: Colores.fondoSuave,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          if (_clienteSel != null) ...[
            paso('Clientes', _irAClientes, key: const ValueKey('miga-clientes')),
            sep,
          ],
          if (nivel == NivelLista.evaluaciones) ...[
            paso(g.nombre, () => setState(() => _centroSel = null), key: const ValueKey('miga-cliente')),
            sep,
            paso(_centro!.nombre, null),
          ] else
            paso(g.nombre, null),
        ]),
      ),
    );
  }

  /// Lo que no tiene nada que mostrar, al medio y con espacio para tirar hacia abajo (sincronizar).
  Widget _vacio(String texto) => ListView(children: [
        const SizedBox(height: 140),
        Center(child: Text(texto, style: const TextStyle(fontSize: 15, color: Colores.texto2))),
      ]);

  /// Una fila de cliente o de piscicultura: el nombre, lo que tiene y lo que falta subir.
  Widget _filaGrupo({
    required Key key,
    required IconData icono,
    required String nombre,
    required String detalle,
    required int porSubir,
    required bool sinAsignar,
    required VoidCallback alTocar,
    bool datosPorSubir = false,
    Widget? menu,
  }) {
    final color = sinAsignar ? Colores.pendiente : Colores.marca;
    return ListTile(
      key: key,
      minVerticalPadding: 10,
      leading: Container(
        width: 44,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
        child: Icon(sinAsignar ? Icons.help_outline : icono, color: color, size: 20),
      ),
      title: Text(nombre,
          style: TextStyle(
              fontSize: 16, fontWeight: FontWeight.w600, fontStyle: sinAsignar ? FontStyle.italic : FontStyle.normal)),
      subtitle: Text.rich(
        TextSpan(children: [
          TextSpan(text: detalle),
          if (porSubir > 0)
            TextSpan(
                text: ' · $porSubir por subir',
                style: const TextStyle(color: Colores.pendiente, fontWeight: FontWeight.w600)),
          if (datosPorSubir)
            const TextSpan(
                text: ' · datos por subir', style: TextStyle(color: Colores.pendiente, fontWeight: FontWeight.w600)),
        ]),
        style: const TextStyle(fontSize: 14, color: Colores.texto2),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (porSubir > 0 || datosPorSubir)
          const Tooltip(message: 'Falta subir', child: Icon(Icons.cloud_upload_outlined, size: 22, color: Colores.pendiente)),
        if (menu != null) menu,
        const SizedBox(width: 4),
        const Icon(Icons.chevron_right, color: Colores.texto2),
      ]),
      onTap: alTocar,
    );
  }

  Widget _listaClientes() {
    if (_grupos.isEmpty && !_puedeEditar) return _vacio('Sin evaluaciones.');
    final extra = _puedeEditar ? 1 : 0; // «Nuevo cliente», arriba
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 88), // que el botón «Nueva» no tape el último
      itemCount: _grupos.length + extra,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        if (i < extra) {
          return _filaNuevo('Nuevo cliente', Icons.add_business_outlined, _nuevoCliente, key: const ValueKey('nuevo-cliente'));
        }
        final g = _grupos[i - extra];
        final maestro = _puedeEditar ? _clienteDelMaestro(g.id) : null;
        return _filaGrupo(
          key: ValueKey('cliente-${g.clave}'),
          icono: Icons.business_outlined,
          nombre: g.nombre,
          detalle: [if (g.pisciculturas > 0) nPisciculturas(g.pisciculturas), nEvaluaciones(g.evaluaciones)].join(' · '),
          porSubir: g.porSubir,
          datosPorSubir: _maestrosPorSubir.contains(g.id),
          sinAsignar: g.id == null,
          menu: maestro == null ? null : _menuEditar(ValueKey('editar-cliente-${g.clave}'), () => _editarCliente(maestro)),
          alTocar: () => _elegirCliente(g),
        );
      },
    );
  }

  Widget _listaCentros(GrupoCliente g) {
    final centros = g.centros;
    // «Nueva piscicultura» solo dentro de un cliente del maestro (no en «Sin cliente»).
    final puedeCrear = _puedeEditar && _clienteDelMaestro(g.id) != null;
    if (centros.isEmpty && !puedeCrear) return _vacio('Sin evaluaciones.');
    final extra = puedeCrear ? 1 : 0;
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: centros.length + extra,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        if (i < extra) {
          return _filaNuevo('Nueva piscicultura', Icons.add_location_alt_outlined, () => _nuevoCentro(g.id!, g.nombre),
              key: const ValueKey('nuevo-centro'));
        }
        final c = centros[i - extra];
        final maestro = _puedeEditar ? _centroDelMaestro(c.id) : null;
        return _filaGrupo(
          key: ValueKey('centro-${c.clave}'),
          icono: Icons.water_outlined,
          nombre: c.nombre,
          detalle: nEvaluaciones(c.evaluaciones.length),
          porSubir: c.porSubir,
          datosPorSubir: _maestrosPorSubir.contains(c.id),
          sinAsignar: c.id == null,
          menu: maestro == null ? null : _menuEditar(ValueKey('editar-centro-${c.clave}'), () => _editarCentro(maestro, g.nombre)),
          alTocar: () => _elegirCentro(c),
        );
      },
    );
  }

  Widget _avisoVencida() => Material(
        color: const Color(0xFFFFF4E5),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Row(children: [
            const Icon(Icons.lock_clock, color: Color(0xFFB7791F), size: 22),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Tu sesión venció. Lo anotado sigue en la tablet; entra de nuevo para sincronizar.',
                  style: TextStyle(fontSize: 14, color: Color(0xFF5C3D00))),
            ),
            FilledButton(onPressed: _reingresar, child: const Text('Entrar')),
          ]),
        ),
      );

  // Los avisos del servidor quedan a la vista hasta que el evaluador los cierra (con mala señal, un aviso de 3 s se
  // pierde). Cada uno ya nombra la evaluación (centro y folio).
  Widget _avisos(AuditSyncService sync) => Material(
        color: const Color(0xFFFFF4E5),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.warning_amber_rounded, color: Color(0xFFB7791F), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    sync.avisos.length == 1 ? 'Aviso del servidor' : 'Avisos del servidor (${sync.avisos.length})',
                    style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF8A5A00))),
              ),
              TextButton(onPressed: sync.cerrarAvisos, child: const Text('Entendido')),
            ]),
            for (final a in sync.avisos)
              Padding(
                padding: const EdgeInsets.only(left: 28, right: 8, bottom: 4),
                child: Text('• $a', style: const TextStyle(fontSize: 13, color: Color(0xFF5C3D00))),
              ),
          ]),
        ),
      );

  Widget _filtros() => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(children: [
          for (final f in FiltroLista.values) ...[
            ChoiceChip(
              key: ValueKey('filtro-${f.name}'),
              label: Text('${f.etiqueta} (${_centro!.evaluaciones.where(f.incluye).length})',
                  style: const TextStyle(fontSize: 14)),
              selected: _filtro == f,
              onSelected: (_) => setState(() => _filtro = f),
            ),
            const SizedBox(width: 8),
          ],
        ]),
      );

  /// Las evaluaciones de una piscicultura (lo que antes era la lista entera), con el filtro por estado.
  Widget _body(GrupoCentro c) {
    final lista = c.evaluaciones.where(_filtro.incluye).toList();
    if (lista.isEmpty) {
      return _vacio(c.evaluaciones.isEmpty ? 'Sin evaluaciones.' : 'Ninguna ${_filtro.etiqueta.toLowerCase()}.');
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 88), // que el botón «Nueva» no tape la última
      itemCount: lista.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) => _fila(lista[i]),
    );
  }

  Widget _fila(Audit a) {
    final detalle = [
      if (a.folio != null) 'Folio ${a.folio}', // el cliente y la piscicultura ya están en el título de la pantalla
      a.auditor ?? 'sin evaluador',
      a.typeEnum.label,
    ].join(' · ');
    return ListTile(
      key: ValueKey('ev-${a.id}'),
      minVerticalPadding: 10,
      leading: _StatusChip(a.statusEnum),
      title: Text('${a.tituloCentro} · ${fmtFecha(fechaDe(a))}',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      subtitle: Text('${a.statusEnum.label} · $detalle', style: const TextStyle(fontSize: 14, color: Colores.texto2)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        a.dirty
            ? const Tooltip(message: 'Falta subir', child: Icon(Icons.cloud_upload_outlined, size: 22, color: Colores.pendiente))
            : const Tooltip(message: 'En el servidor', child: Icon(Icons.cloud_done_outlined, size: 22, color: Colores.ok)),
        if (sePuedeBorrar(a))
          PopupMenuButton<String>(
            key: ValueKey('menu-${a.id}'),
            tooltip: 'Opciones',
            onSelected: (_) => _borrar(a),
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'borrar',
                child: Row(children: [
                  Icon(Icons.delete_outline, size: 20, color: Colores.peligro),
                  SizedBox(width: 10),
                  Text('Borrar'),
                ]),
              ),
            ],
          ),
      ]),
      onTap: () => _open(a.id),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final AuditStatus status;
  const _StatusChip(this.status);

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      AuditStatus.scheduled => const Color(0xFF1D4ED8),
      AuditStatus.draft => const Color(0xFFB45309),
      AuditStatus.submitted => Colores.ok,
      AuditStatus.reviewed => const Color(0xFF0F766E),
    };
    return Container(
      width: 44,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(
        switch (status) {
          AuditStatus.scheduled => Icons.event,
          AuditStatus.draft => Icons.edit_note,
          AuditStatus.submitted => Icons.lock_outline,
          AuditStatus.reviewed => Icons.verified_outlined,
        },
        color: color,
        size: 20,
      ),
    );
  }
}

/// La barra del estado de la sincronización, en palabras del evaluador. Si algo falló, tocarla muestra por qué.
class StatusBarSync extends StatelessWidget {
  final SyncStatus status;
  final int pending;

  /// Clientes y pisciculturas creados o editados en la tablet que faltan por subir.
  final int maestros;
  final String? lastError;
  final DateTime? lastSyncAt;
  const StatusBarSync(
      {super.key, required this.status, required this.pending, this.maestros = 0, this.lastError, this.lastSyncAt});

  static String porSubir(int n) => n == 1 ? '1 evaluación por subir' : '$n evaluaciones por subir';

  /// Lo que falta subir en palabras: las evaluaciones como siempre, y los clientes o pisciculturas si hay.
  String get _porSubir {
    if (maestros == 0) return porSubir(pending);
    final m = maestros == 1 ? '1 cliente o piscicultura' : '$maestros clientes o pisciculturas';
    if (pending == 0) return '$m por subir';
    return '${pending == 1 ? '1 evaluación' : '$pending evaluaciones'} y $m por subir';
  }

  int get _total => pending + maestros;

  static String hora(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  /// El texto y el color de la barra.
  (String, Color) get estado => switch (status) {
        SyncStatus.syncing => ('Sincronizando…', const Color(0xFF1D4ED8)),
        SyncStatus.offline => (
            _total == 0 ? 'Sin señal' : 'Sin señal · $_porSubir: quedan guardadas en la tablet',
            Colores.texto2
          ),
        SyncStatus.error => (
            lastError == AuditSyncService.kSesionVencida
                ? 'Sesión vencida: entra de nuevo para sincronizar'
                : 'No se pudo sincronizar todo${_total > 0 ? ' · $_porSubir' : ''} · toca para ver por qué',
            Colores.peligro
          ),
        SyncStatus.idle => (
            _total == 0
                ? 'Todo sincronizado${lastSyncAt == null ? '' : ' · ${hora(lastSyncAt!)}'}'
                : _porSubir,
            _total == 0 ? Colores.ok : Colores.pendiente
          ),
      };

  @override
  Widget build(BuildContext context) {
    final hasError = status == SyncStatus.error && lastError != AuditSyncService.kSesionVencida;
    final (text, color) = estado;
    final motivos = (lastError ?? '').split(' · ').where((x) => x.trim().isNotEmpty).toList();
    return InkWell(
      onTap: hasError
          ? () => showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Por qué no se sincronizó'),
                  content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      for (final m in motivos.isEmpty ? ['Sin detalle.'] : motivos)
                        Padding(padding: const EdgeInsets.only(bottom: 8), child: SelectableText('• $m')),
                      const Text('Lo anotado sigue guardado en la tablet.', style: TextStyle(color: Colores.texto2)),
                    ]),
                  ),
                  actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar'))],
                ),
              )
          : null,
      child: Container(
        width: double.infinity,
        color: color.withValues(alpha: 0.10),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(text,
                  key: const ValueKey('estado-sync'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            if (hasError) Icon(Icons.info_outline, size: 18, color: color),
          ],
        ),
      ),
    );
  }
}
