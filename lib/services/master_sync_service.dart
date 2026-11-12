import 'package:dio/dio.dart';

import '../data/app_database.dart';
import '../models/maestro_terreno.dart';
import '../models/master.dart';
import 'api_client.dart';

/// Un problema de la sincronización que ya viene en palabras del evaluador.
class AvisoSync implements Exception {
  final String mensaje;
  const AvisoSync(this.mensaje);
  @override
  String toString() => mensaje;
}

/// Maestros (clientes/centros): se bajan por cursor global de ServerVersion (igual patrón que las auditorías). Desde el
/// 12-11-2026, Administrador y Auditor pueden además crear un cliente y su piscicultura en terreno, y editar sus datos
/// básicos: quedan en la tablet ([AppDatabase.maestrosPendientes]) y se suben con [push]. Todo lo demás, en la web.
class MasterSyncService {
  final AppDatabase db;
  final ApiClient api;

  MasterSyncService({required this.db, required this.api});

  /// Una vez por versión de la app: se vuelven a bajar los centros completos. Un centro que no cambió desde la última
  /// sincronización no vuelve a llegar por el cursor, y su copia podía ser de antes de la posición por nivel (19-10-2026).
  /// Sin cambiar el esquema de la base: la versión anterior de la app la sigue abriendo.
  static const String _llaveModelo = 'centros_modelo';
  static const String _modeloVigente = 'niveles-20261020';

  /// En la tablet: si esta cuenta puede crear y editar clientes y pisciculturas desde la app (lo dice el servidor; sin
  /// red, lo último que dijo).
  static const String llavePermiso = 'maestros_terreno';

  Future<bool> puedeEditar() async => await db.getValue(llavePermiso) == '1';

  /// Sube los clientes y pisciculturas creados o editados en la tablet. Devuelve los avisos del servidor (un posible
  /// duplicado, un dato que no se cambió porque la web lo había cambiado, algo que no se pudo aplicar).
  Future<List<String>> push() async {
    final pendientes = await db.maestrosPendientes();
    if (pendientes.isEmpty) return const [];
    final Response<dynamic> res;
    try {
      res = await api.dio.post('/api/masters/push', data: {
        'clientes': [for (final p in pendientes) if (p.esCliente) p.toDto()],
        'centros': [for (final p in pendientes) if (!p.esCliente) p.toDto()],
      });
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404 || code == 405) {
        throw const AvisoSync('Clientes y pisciculturas: este servidor todavía no los recibe desde la app. '
            'Quedan guardados en la tablet y se suben cuando el servidor se actualice.');
      }
      if (code == 403) {
        await db.setValue(llavePermiso, '0');
        throw const AvisoSync('Clientes y pisciculturas: tu cuenta ya no puede crearlos ni editarlos desde la app. '
            'Quedan guardados en la tablet; pídele a AOLAB que revise tu rol.');
      }
      rethrow;
    }
    final porId = {for (final p in pendientes) '${p.tipo}:${p.id.toLowerCase()}': p};
    final avisos = <String>[];
    for (final r in ((res.data as Map)['resultados'] as List).cast<Map<String, dynamic>>()) {
      final p = porId['${r['tipo']}:${(r['id'] as String).toLowerCase()}'];
      final msg = r['mensaje'];
      if (msg is String && msg.trim().isNotEmpty) avisos.add(msg);
      if (p == null) continue;
      if (r['estado'] == 'aplicado') {
        await db.maestroSubido(p);
      } else if (r['estado'] == 'rechazado') {
        await db.maestroRechazado(p);
      }
    }
    return avisos;
  }

  /// Si el servidor recibe clientes y pisciculturas de la app ([kCapacidadMaestros] en /api/app/version) y si esta
  /// cuenta puede (/api/masters/me). Un servidor anterior no dice ninguna de las dos: la opción no se ofrece. Sin red,
  /// queda lo último que se supo.
  Future<void> _pullPermiso() async {
    try {
      final v = await api.dio.get('/api/app/version');
      final caps = v.data is Map && (v.data as Map)['capacidades'] is List
          ? [for (final x in (v.data as Map)['capacidades'] as List) x.toString()]
          : const <String>[];
      var puede = false;
      if (caps.contains(kCapacidadMaestros)) {
        final me = await api.dio.get('/api/masters/me');
        puede = me.data is Map && (me.data as Map)['puedeEditarMaestros'] == true;
      }
      await db.setValue(llavePermiso, puede ? '1' : '0');
    } catch (_) {/* sin red: se queda con lo último que se supo */}
  }

  Future<void> pull() async {
    if (await db.getValue(_llaveModelo) != _modeloVigente) {
      await db.setCenterCursor(0);
      await db.setValue(_llaveModelo, _modeloVigente);
    }
    await _pullClients();
    await _pullCenters();
    await _pullUsers();
    await _pullCatalogs();
    await _pullPermiso();
  }

  // Catálogos (tipos de punto/sistema, afluentes): lista chica, se reemplaza completa.
  Future<void> _pullCatalogs() async {
    final res = await api.dio.get('/api/masters/catalogs');
    if (res.data is Map) await db.setCatalogs((res.data as Map).cast<String, dynamic>());
  }

  // Usuarios: lista chica, se reemplaza completa (sin cursor).
  Future<void> _pullUsers() async {
    final res = await api.dio.get('/api/masters/users');
    final list = (res.data as List).cast<Map<String, dynamic>>();
    await db.replaceUsers(list.map(UserRef.fromDto).toList());
  }

  Future<void> _pullClients() async {
    var cursor = await db.getClientCursor();
    var hasMore = true;
    while (hasMore) {
      final res = await api.dio.get('/api/masters/clients/pull',
          queryParameters: {'cursor': cursor, 'pageSize': 200});
      final list = (res.data['clients'] as List).cast<Map<String, dynamic>>();
      for (final d in list) {
        await db.applyClientFromServer(ClientRef.fromDto(d));
      }
      cursor = (res.data['cursor'] ?? cursor) as int;
      hasMore = (res.data['hasMore'] ?? false) as bool;
      await db.setClientCursor(cursor);
    }
  }

  Future<void> _pullCenters() async {
    var cursor = await db.getCenterCursor();
    var hasMore = true;
    while (hasMore) {
      final res = await api.dio.get('/api/masters/centers/pull',
          queryParameters: {'cursor': cursor, 'pageSize': 200});
      final list = (res.data['centers'] as List).cast<Map<String, dynamic>>();
      for (final d in list) {
        await db.applyCenterFromServer(CenterRef.fromDto(d));
      }
      cursor = (res.data['cursor'] ?? cursor) as int;
      hasMore = (res.data['hasMore'] ?? false) as bool;
      await db.setCenterCursor(cursor);
    }
  }
}
