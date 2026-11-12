// Clientes y pisciculturas creados y editados en terreno, de punta a punta contra un servidor LOCAL (una copia de la
// base, nunca prod ni TEST), con la base SQLite de verdad de la app (sqflite en el PC), la cola, la sincronización y el
// servidor nuevo. «Sin señal» se simula en la red de la app y en la conectividad.
//
//   AOLAB_CONTRATO_URL=http://127.0.0.1:5097 AOLAB_E2E_TOKEN=<archivo con el JWT de un Auditor> \
//   [AOLAB_E2E_TOKEN_SIN_PERMISO=<archivo con el JWT de una cuenta interna sin Administrador ni Auditor>] \
//     flutter test integration_local/maestros_terreno_test.dart
//
// Los tokens van por archivo (nunca en la línea de comandos ni en la salida). Escribe en esa copia: deja clientes y
// pisciculturas de prueba con «E2E» y el número de la corrida en el nombre.
import 'dart:ffi';
import 'dart:io';

import 'package:aolab_android/data/app_database.dart';
import 'package:aolab_android/models/audit.dart';
import 'package:aolab_android/models/maestro_terreno.dart';
import 'package:aolab_android/models/master.dart';
import 'package:aolab_android/services/audit_sync_service.dart';
import 'package:aolab_android/services/auth_service.dart';
import 'package:aolab_android/services/master_sync_service.dart';
import 'package:aolab_android/services/media_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// ignore: depend_on_referenced_packages
import 'package:sqlite3/open.dart' as sqlite3;
import 'package:uuid/uuid.dart';

class _Memoria implements AlmacenSesion {
  final Map<String, String> d = {};
  @override
  Future<String?> leer(String llave) async => d[llave];
  @override
  Future<void> escribir(String llave, String valor) async => d[llave] = valor;
  @override
  Future<void> borrar(String llave) async => d.remove(llave);
}

class _Senal extends Interceptor {
  bool sinRed = false;
  @override
  void onRequest(RequestOptions o, RequestInterceptorHandler h) {
    if (sinRed) {
      h.reject(DioException(requestOptions: o, type: DioExceptionType.connectionError, error: 'sin señal (simulada)'));
      return;
    }
    h.next(o);
  }
}

void _abrirSqlite() {
  sqlite3.open.overrideFor(sqlite3.OperatingSystem.linux, () {
    try {
      return DynamicLibrary.open('libsqlite3.so');
    } catch (_) {
      return DynamicLibrary.open('libsqlite3.so.0');
    }
  });
}

String? _leerToken(String variable) {
  final ruta = Platform.environment[variable] ?? '';
  if (ruta.isEmpty || !File(ruta).existsSync()) return null;
  final t = File(ruta).readAsStringSync().trim();
  return t.isEmpty ? null : t;
}

void main() {
  final url = Platform.environment['AOLAB_CONTRATO_URL'] ?? '';
  final token = _leerToken('AOLAB_E2E_TOKEN');
  final tokenSinPermiso = _leerToken('AOLAB_E2E_TOKEN_SIN_PERMISO');
  final local = RegExp(r'^http://(127\.0\.0\.1|localhost):\d+$').hasMatch(url);
  final omitir = !local || token == null
      ? 'Solo contra un servidor local (AOLAB_CONTRATO_URL=http://127.0.0.1:<puerto>) con AOLAB_E2E_TOKEN.'
      : null;

  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  var red = 'wifi';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/connectivity'), (_) async => [red]);

  final corrida = DateTime.now().millisecondsSinceEpoch.toString().substring(5, 13);
  final carpeta = Directory.systemTemp.createTempSync('aolab-e2e-maestros');
  final senal = _Senal();
  late AppDatabase db;
  late AuthService auth;
  late AuditSyncService sync;
  late Dio oficina; // la misma cuenta desde otro equipo, sin el corte de señal

  final idCliente = const Uuid().v4();
  final idDuplicado = const Uuid().v4();
  final idDuplicadoRut = const Uuid().v4();
  final idCentro = const Uuid().v4();
  final idEval = const Uuid().v4();
  final nombreCliente = 'E2E Salmones Terreno $corrida';
  final rutCliente = '99.${corrida.substring(0, 3)}.${corrida.substring(3, 6)}-K';
  late ClientRef existente; // uno que ya existe en la copia: un duplicado repite su nombre

  Future<Map<String, dynamic>?> delPull(Dio d, String ruta, String llave, String id) async {
    var cursor = 0;
    var mas = true;
    Map<String, dynamic>? r;
    while (mas) {
      final res = await d.get(ruta, queryParameters: {'cursor': cursor, 'pageSize': 500});
      for (final x in (res.data[llave] as List).cast<Map<String, dynamic>>()) {
        if ((x['id'] as String).toLowerCase() == id.toLowerCase()) r = x;
      }
      cursor = res.data['cursor'] as int;
      mas = res.data['hasMore'] as bool;
    }
    return r;
  }

  var roto = false;
  void paso(String nombre, Future<void> Function() cuerpo) => test(nombre, () async {
        if (roto) fail('Falló un paso anterior.');
        try {
          await cuerpo();
        } catch (_) {
          roto = true;
          rethrow;
        }
      }, skip: omitir);

  setUpAll(() async {
    if (omitir != null) return;
    databaseFactory = createDatabaseFactoryFfi(ffiInit: _abrirSqlite);
    await databaseFactory.setDatabasesPath('${carpeta.path}/db');
    final dio = Dio(BaseOptions(baseUrl: url, headers: {'Content-Type': 'application/json'}));
    dio.interceptors.add(senal);
    db = AppDatabase();
    final almacen = _Memoria()..d['aolab_jwt'] = token!;
    auth = AuthService(almacen: almacen, dio: dio, conGoogle: false);
    await auth.loadSession();
    final media = MediaService(api: auth.api, carpeta: (Directory('${carpeta.path}/media')..createSync()).path);
    sync = AuditSyncService(db: db, api: auth.api, masters: MasterSyncService(db: db, api: auth.api), media: media);
    oficina = Dio(BaseOptions(baseUrl: url, headers: {'Authorization': 'Bearer $token'}));
  });

  tearDownAll(() {
    try {
      carpeta.deleteSync(recursive: true);
    } catch (_) {}
  });

  paso('1. Con señal: baja los maestros y el servidor anuncia que esta cuenta puede crear', () async {
    await sync.sync();
    expect(sync.lastError, isNull);
    expect(await db.getValue(MasterSyncService.llavePermiso), '1');
    final clientes = await db.activeClients();
    expect(clientes, isNotEmpty);
    existente = clientes.first;
  });

  paso('2. Sin señal: cliente nuevo, su primera piscicultura y una evaluación en ella; nada sale', () async {
    red = 'none';
    senal.sinRed = true;
    await db.guardarClienteLocal(ClientRef(id: idCliente, name: nombreCliente, legalId: rutCliente), nuevo: true);
    await db.guardarCentroLocal(
        CenterRef(id: idCentro, name: 'E2E Piscicultura $corrida', code: 'E2E-$corrida', latitude: -41.4693, longitude: -72.9424,
            ownerClientId: idCliente),
        nuevo: true);
    // Uno sin RUT con el nombre de uno que ya existe (escrito distinto), y otro con el RUT del nuevo (escrito distinto).
    await db.guardarClienteLocal(ClientRef(id: idDuplicado, name: '  ${existente.name.toUpperCase()}. '), nuevo: true);
    await db.guardarClienteLocal(
        ClientRef(id: idDuplicadoRut, name: 'E2E Otro nombre $corrida', legalId: rutCliente.replaceAll('.', '').toLowerCase()),
        nuevo: true);
    final now = DateTime.now().toUtc();
    await db.upsertLocal(Audit(
      id: idEval,
      status: 3,
      clientId: idCliente,
      clientName: nombreCliente,
      centerId: idCentro,
      centerName: 'E2E Piscicultura $corrida',
      createdAtUtc: now,
      updatedAtUtc: now,
      document: AuditDocument.nueva(),
    ));
    await sync.sync();
    expect(sync.status, SyncStatus.offline);
    expect(await db.maestrosPendientesCount(), 4);
    // La copia local de la base sobrevive a un reinicio de la app (la cola está en SQLite).
    final otra = AppDatabase();
    expect((await otra.maestrosPendientes()).map((p) => (p.tipo, p.nuevo)),
        [(kTipoCliente, true), (kTipoCliente, true), (kTipoCliente, true), (kTipoCentro, true)]);
  });

  paso('3. Vuelve la señal: sube cliente y piscicultura antes que la evaluación, sin duplicar; el duplicado se avisa', () async {
    red = 'wifi';
    senal.sinRed = false;
    await sync.sync();
    expect(sync.lastError, isNull);
    expect(await db.maestrosPendientesCount(), 0);
    // Los dos posibles duplicados quedan creados y se avisan (AOLAB los revisa en la web).
    expect(sync.avisos.where((a) => a.contains('el mismo nombre') && a.contains('«${existente.name}»')), hasLength(1));
    expect(sync.avisos.where((a) => a.contains('el mismo RUT') && a.contains('«$nombreCliente»')), hasLength(1));
    expect((await db.activeClients()).where((x) => x.id == idDuplicado || x.id == idDuplicadoRut), hasLength(2));

    final c = await delPull(oficina, '/api/masters/clients/pull', 'clients', idCliente);
    expect((c!['name'], c['legalId'], c['isActive']), (nombreCliente, rutCliente, true));
    final p = await delPull(oficina, '/api/masters/centers/pull', 'centers', idCentro);
    expect((p!['ownerClientId'] as String).toLowerCase(), idCliente);
    expect((p['code'], p['latitude'], p['longitude']), ('E2E-$corrida', -41.4693, -72.9424));
    final a = await delPull(oficina, '/api/audits/pull', 'audits', idEval);
    expect(((a!['clientId'] as String).toLowerCase(), (a['centerId'] as String).toLowerCase()), (idCliente, idCentro));
    // En la tablet, uno de cada uno, con la versión del servidor.
    expect((await db.activeClients()).where((x) => x.id == idCliente).single.serverVersion, greaterThan(0));
    expect((await db.activeCenters()).where((x) => x.id == idCentro).single.serverVersion, greaterThan(0));
    await sync.cerrarAvisos();
  });

  paso('4. Reenviar lo mismo (la respuesta se perdió) no duplica', () async {
    final res = await oficina.post('/api/masters/push', data: {
      'clientes': [{'id': idCliente, 'nuevo': true, 'nombre': nombreCliente, 'rut': rutCliente}],
      'centros': [{'id': idCentro, 'nuevo': true, 'clienteId': idCliente, 'nombre': 'E2E Piscicultura $corrida',
                   'codigo': 'E2E-$corrida', 'latitud': -41.4693, 'longitud': -72.9424}],
    });
    expect([for (final r in res.data['resultados'] as List) r['estado']], ['aplicado', 'aplicado']);
    final todos = <Map<String, dynamic>>[];
    var cursor = 0;
    var mas = true;
    while (mas) {
      final r = await oficina.get('/api/masters/clients/pull', queryParameters: {'cursor': cursor, 'pageSize': 500});
      todos.addAll((r.data['clients'] as List).cast<Map<String, dynamic>>());
      cursor = r.data['cursor'] as int;
      mas = r.data['hasMore'] as bool;
    }
    expect(todos.where((x) => x['name'] == nombreCliente), hasLength(1));
  });

  paso('5. Editar sin señal; lo que otro cambió entretanto se respeta y se avisa', () async {
    red = 'none';
    senal.sinRed = true;
    final c = (await db.activeClients()).singleWhere((x) => x.id == idCliente);
    await db.guardarClienteLocal(ClientRef(id: c.id, name: '$nombreCliente (tablet)', legalId: c.legalId), nuevo: false);
    final p = (await db.activeCenters()).singleWhere((x) => x.id == idCentro);
    await db.guardarCentroLocal(
        CenterRef(id: p.id, name: p.name, code: p.code, latitude: -41.5, longitude: p.longitude, ownerClientId: p.ownerClientId),
        nuevo: false);
    // Entretanto, desde otro equipo alguien cambia el nombre del cliente.
    final otro = await oficina.post('/api/masters/push', data: {
      'clientes': [{'id': idCliente, 'nuevo': false, 'nombre': '$nombreCliente (oficina)', 'rut': rutCliente,
                    'base': {'nombre': nombreCliente, 'rut': rutCliente}}],
    });
    expect(otro.data['resultados'][0]['estado'], 'aplicado');

    red = 'wifi';
    senal.sinRed = false;
    await sync.sync();
    expect(await db.maestrosPendientesCount(), 0);
    expect(sync.avisos.single, contains('el nombre no se cambió porque alguien lo cambió en la web'));
    expect((await db.activeClients()).singleWhere((x) => x.id == idCliente).name, '$nombreCliente (oficina)');
    expect((await db.activeCenters()).singleWhere((x) => x.id == idCentro).latitude, -41.5);
    final s = await delPull(oficina, '/api/masters/centers/pull', 'centers', idCentro);
    expect(s!['latitude'], -41.5);
    await sync.cerrarAvisos();
  });

  paso('6. Una cuenta interna sin Administrador ni Auditor no puede subir, y el servidor se lo dice a la app', () async {
    if (tokenSinPermiso == null) {
      markTestSkipped('Sin AOLAB_E2E_TOKEN_SIN_PERMISO');
      return;
    }
    final d = Dio(BaseOptions(baseUrl: url, headers: {'Authorization': 'Bearer $tokenSinPermiso'}, validateStatus: (_) => true));
    final me = await d.get('/api/masters/me');
    expect(me.data['puedeEditarMaestros'], isFalse);
    final r = await d.post('/api/masters/push', data: {
      'clientes': [{'id': const Uuid().v4(), 'nuevo': true, 'nombre': 'E2E Sin Permiso $corrida'}],
    });
    expect(r.statusCode, 403);
  });

  paso('7. Una tablet recién instalada baja el cliente y su piscicultura una sola vez', () async {
    await databaseFactory.setDatabasesPath('${carpeta.path}/db2');
    final db2 = AppDatabase();
    await MasterSyncService(db: db2, api: auth.api).pull();
    expect((await db2.activeClients()).where((x) => x.id == idCliente), hasLength(1));
    final centro = (await db2.activeCenters()).singleWhere((x) => x.id == idCentro);
    expect(centro.ownerClientId, idCliente);
    expect(await db2.maestrosPendientesCount(), 0);
  });

  test('8. Una tablet con la app anterior (base versión 10) se actualiza sin perder sus datos', () async {
    final dir = Directory.systemTemp.createTempSync('aolab-v10');
    databaseFactory = createDatabaseFactoryFfi(ffiInit: _abrirSqlite);
    await databaseFactory.setDatabasesPath(dir.path);
    // Una base como la deja la 1.0.8: sin la cola (se arma la de hoy y se le quita).
    final vieja = AppDatabase();
    await vieja.applyClientFromServer(ClientRef(id: 'k-viejo', name: 'Cliente de antes', serverVersion: 9));
    final raw = await vieja.database;
    await raw.execute('DROP TABLE maestros_pendientes');
    await raw.setVersion(10);
    await raw.close();
    final nueva = AppDatabase();
    expect(await nueva.maestrosPendientesCount(), 0);
    expect((await nueva.activeClients()).single.name, 'Cliente de antes');
    await nueva.guardarClienteLocal(ClientRef(id: 'k-viejo', name: 'Cliente de antes editado'), nuevo: false);
    expect((await nueva.maestrosPendientes()).single.base, {'nombre': 'Cliente de antes', 'rut': null});
    expect(await (await nueva.database).getVersion(), 11);
    await (await nueva.database).close();
    dir.deleteSync(recursive: true);
  }, skip: Platform.isLinux ? null : 'Solo en el PC (Linux)');
}
