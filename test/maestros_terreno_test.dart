// Crear en terreno un cliente nuevo y su primera piscicultura, sin señal, y editar los datos básicos de los que existen
// (12-11-2026). Solo Administrador y Auditor, y solo si el servidor lo anuncia: quedan en la tablet y se suben con la
// próxima sincronización, antes que las evaluaciones.
import 'package:aolab_android/models/maestro_terreno.dart';
import 'package:aolab_android/models/master.dart';
import 'package:aolab_android/services/audit_sync_service.dart';
import 'package:aolab_android/services/master_sync_service.dart';
import 'package:aolab_android/ui/audit_list_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apoyo/base_falsa.dart';
import 'apoyo/servidor_falso.dart';

const _idCliente = '11111111-1111-4111-8111-111111111111';
const _idCentro = '22222222-2222-4222-8222-222222222222';

ClientRef _acme() => ClientRef(id: 'k1', name: 'Acme', legalId: '76.123.456-K', serverVersion: 5);
CenterRef _rio() => CenterRef(id: 'c1', name: 'Río Uno', code: 'R1', latitude: -41.0, longitude: -73.0, ownerClientId: 'k1', serverVersion: 6);

/// El servidor de hoy: anuncia la capacidad, dice que la cuenta puede, y responde la sincronización vacía.
ServidorFalso _servidor({bool capacidad = true, bool puede = true}) {
  final srv = ServidorFalso();
  srv.responder('GET /api/app/version', 200, {
    'minBuild': 0,
    'entradas': ['integrado'],
    if (capacidad) 'capacidades': [kCapacidadMaestros],
  });
  srv.responder('GET /api/masters/me', 200, {'id': 'u', 'email': 'evaluador@aolab.cl', 'puedeEditarMaestros': puede});
  srv.responder('GET /api/audits/pull', 200, {'audits': [], 'cursor': 0, 'hasMore': false});
  srv.responder('GET /api/masters/clients/pull', 200, {'clients': [], 'cursor': 0, 'hasMore': false});
  srv.responder('GET /api/masters/centers/pull', 200, {'centers': [], 'cursor': 0, 'hasMore': false});
  srv.responder('GET /api/masters/users', 200, []);
  srv.responder('GET /api/masters/catalogs', 200, {});
  return srv;
}

/// Lo que mandó la tablet en el push de maestros.
Map<String, dynamic> _enviado(ServidorFalso srv) =>
    (srv.pedidos.lastWhere((p) => p.path == '/api/masters/push').data as Map).cast<String, dynamic>();

Map<String, dynamic> _aplicado(String tipo, String id, {int version = 50, String? mensaje, List<String> conflictos = const []}) =>
    {'tipo': tipo, 'id': id, 'estado': 'aplicado', 'serverVersion': version, 'mensaje': mensaje, 'conflictos': conflictos};

void main() {
  group('La cola y la sincronización', () {
    late BaseEnMemoria db;
    late ServidorFalso srv;
    late AppDePrueba app;

    void montar({bool capacidad = true, bool puede = true}) {
      db = BaseEnMemoria([_rio()], clientes: [_acme()]);
      srv = _servidor(capacidad: capacidad, puede: puede);
      app = AppDePrueba(db, srv);
    }

    Future<void> crearClienteYCentro() async {
      await db.guardarClienteLocal(ClientRef(id: _idCliente, name: 'Salmones Nuevos', legalId: '77.777.777-7'), nuevo: true);
      await db.guardarCentroLocal(
          CenterRef(id: _idCentro, name: 'Piscicultura Nueva', code: 'PN-1', latitude: -41.47, longitude: -72.94, ownerClientId: _idCliente),
          nuevo: true);
    }

    test('creado sin señal: queda en la cola y nada sale de la tablet', () async {
      sinPlugins(red: 'none');
      montar();
      await crearClienteYCentro();
      await app.sync.sync();
      expect(app.sync.status, SyncStatus.offline);
      expect(srv.pedidos, isEmpty);
      expect(await db.maestrosPendientesCount(), 2);
      // Ya se puede usar en la tablet: está en los selectores.
      expect((await db.activeClients()).map((c) => c.name), contains('Salmones Nuevos'));
      expect((await db.activeCenters()).singleWhere((c) => c.id == _idCentro).ownerClientId, _idCliente);
    });

    test('con señal: sube clientes primero, antes que las evaluaciones, y al bajar no se duplica', () async {
      sinPlugins(red: 'wifi');
      montar();
      await crearClienteYCentro();
      db.audits['e1'] = evaluacion(id: 'e1', serverVersion: 0)
        ..clientId = _idCliente
        ..centerId = _idCentro
        ..dirty = true;
      srv.responder('POST /api/audits/push', 200, {'results': []});
      srv.responder('POST /api/masters/push', 200, {
        'resultados': [_aplicado('cliente', _idCliente), _aplicado('centro', _idCentro, version: 51)],
      });
      // El pull trae lo que quedó en el servidor (con su versión).
      srv.responder('GET /api/masters/clients/pull', 200, {
        'clients': [{'id': _idCliente, 'name': 'Salmones Nuevos', 'legalId': '77.777.777-7', 'isActive': true, 'serverVersion': 50}],
        'cursor': 50, 'hasMore': false,
      });
      srv.responder('GET /api/masters/centers/pull', 200, {
        'centers': [{'id': _idCentro, 'name': 'Piscicultura Nueva', 'code': 'PN-1', 'ownerClientId': _idCliente, 'isActive': true, 'serverVersion': 51}],
        'cursor': 51, 'hasMore': false,
      });

      await app.sync.sync();

      final rutas = srv.pedidos.map((p) => '${p.method} ${p.path}').toList();
      expect(rutas.indexOf('POST /api/masters/push'), lessThan(rutas.indexOf('POST /api/audits/push')));
      final env = _enviado(srv);
      expect(env['clientes'], [
        {'id': _idCliente, 'nuevo': true, 'nombre': 'Salmones Nuevos', 'rut': '77.777.777-7', 'base': null},
      ]);
      expect(env['centros'], [
        {'id': _idCentro, 'nuevo': true, 'nombre': 'Piscicultura Nueva', 'codigo': 'PN-1', 'latitud': -41.47, 'longitud': -72.94,
         'clienteId': _idCliente, 'base': null},
      ]);
      expect(await db.maestrosPendientesCount(), 0);
      expect(db.clientes.where((c) => c.id == _idCliente).single.serverVersion, 50);
      expect(db.centros.where((c) => c.id == _idCentro).single.serverVersion, 51);
      expect(app.sync.lastError, isNull);
      // La siguiente sincronización no vuelve a mandar nada.
      srv.pedidos.clear();
      await app.sync.sync();
      expect(srv.pedidos.where((p) => p.path == '/api/masters/push'), isEmpty);
    });

    test('editar uno que existe manda lo que vio la tablet; lo que la web cambió entretanto se avisa', () async {
      sinPlugins(red: 'wifi');
      montar();
      await db.guardarClienteLocal(ClientRef(id: 'k1', name: 'Acme Chile', legalId: '76.123.456-K'), nuevo: false);
      final p = (await db.maestrosPendientes()).single;
      expect((p.nuevo, p.datos['nombre']), (false, 'Acme Chile'));
      expect(p.base, {'nombre': 'Acme', 'rut': '76.123.456-K'});
      // Una segunda edición antes de subir conserva la base del primer cambio.
      await db.guardarClienteLocal(ClientRef(id: 'k1', name: 'Acme Chile SpA', legalId: '76.123.456-K'), nuevo: false);
      expect((await db.maestrosPendientes()).single.base, {'nombre': 'Acme', 'rut': '76.123.456-K'});

      const aviso = '«Acme Web»: el nombre no se cambió porque alguien lo cambió en la web mientras tanto. Quedó lo de la web.';
      srv.responder('POST /api/masters/push', 200, {
        'resultados': [_aplicado('cliente', 'k1', mensaje: aviso, conflictos: ['nombre'])],
      });
      srv.responder('GET /api/masters/clients/pull', 200, {
        'clients': [{'id': 'k1', 'name': 'Acme Web', 'legalId': '76.123.456-K', 'isActive': true, 'serverVersion': 60}],
        'cursor': 60, 'hasMore': false,
      });
      await app.sync.sync();
      expect(_enviado(srv)['clientes'], [
        {'id': 'k1', 'nuevo': false, 'nombre': 'Acme Chile SpA', 'rut': '76.123.456-K', 'base': {'nombre': 'Acme', 'rut': '76.123.456-K'}},
      ]);
      expect(app.sync.avisos, [aviso]);
      expect(await db.maestrosPendientesCount(), 0);
      expect(db.clientes.single.name, 'Acme Web'); // quedó lo de la web
    });

    test('lo editado mientras el envío iba y volvía sigue pendiente, con lo enviado como base', () async {
      sinPlugins(red: 'wifi');
      montar();
      await db.guardarCentroLocal(
          CenterRef(id: 'c1', name: 'Río Uno', code: 'R1', latitude: -41.2, longitude: -73.0, ownerClientId: 'k1'), nuevo: false);
      srv.rutas['POST /api/masters/push'] = (o) {
        // Mala señal: mientras tanto, el evaluador corrige la longitud.
        db.guardarCentroLocal(
            CenterRef(id: 'c1', name: 'Río Uno', code: 'R1', latitude: -41.2, longitude: -73.1, ownerClientId: 'k1'), nuevo: false);
        return (status: 200, body: {'resultados': [_aplicado('centro', 'c1')]});
      };
      await app.sync.sync();
      final p = (await db.maestrosPendientes()).single;
      expect(p.datos['longitud'], -73.1);
      expect(p.base!['latitud'], -41.2); // lo que ya está en el servidor
      expect(p.base!['longitud'], -73.0);
      // El pull no pisa lo que falta subir.
      expect(db.centros.single.longitude, -73.1);
    });

    test('un posible duplicado se crea igual y se avisa: AOLAB lo revisa en la web', () async {
      sinPlugins(red: 'wifi');
      montar();
      await crearClienteYCentro();
      const aviso = '«Salmones Nuevos» quedó guardado, pero ya existía un cliente con el mismo RUT («Acme»). AOLAB lo revisará en la web; '
          'mientras tanto puedes seguir trabajando con él.';
      srv.responder('POST /api/masters/push', 200, {
        'resultados': [
          {..._aplicado('cliente', _idCliente, mensaje: aviso), 'posibleDuplicadoDe': 'k1'},
          _aplicado('centro', _idCentro),
        ],
      });
      await app.sync.sync();
      expect(app.sync.avisos, [aviso]);
      expect(await db.maestrosPendientesCount(), 0);
      expect(db.clientes.map((c) => c.id), containsAll(['k1', _idCliente])); // no se unió ni se perdió
    });

    test('lo rechazado sale de la cola y se avisa; uno creado aquí se quita de la tablet', () async {
      sinPlugins(red: 'wifi');
      montar();
      await crearClienteYCentro();
      srv.responder('POST /api/masters/push', 200, {
        'resultados': [
          _aplicado('cliente', _idCliente),
          {'tipo': 'centro', 'id': _idCentro, 'estado': 'rechazado', 'serverVersion': 0,
           'mensaje': '«Piscicultura Nueva»: su cliente ya no existe en el servidor, así que la piscicultura no se creó.'},
        ],
      });
      await app.sync.sync();
      expect(app.sync.avisos.single, contains('la piscicultura no se creó'));
      expect(await db.maestrosPendientesCount(), 0);
      expect(db.centros.map((c) => c.id), isNot(contains(_idCentro)));
    });

    test('un servidor anterior (sin el endpoint) lo dice claro y la cola se queda', () async {
      sinPlugins(red: 'wifi');
      montar(capacidad: false);
      await crearClienteYCentro();
      srv.responder('POST /api/masters/push', 404, null);
      await app.sync.sync();
      expect(app.sync.status, SyncStatus.error);
      expect(app.sync.lastError, contains('este servidor todavía no los recibe desde la app'));
      expect(await db.maestrosPendientesCount(), 2);
      // Y la opción ya no se ofrece.
      expect(await MasterSyncService(db: db, api: app.auth.api).puedeEditar(), isFalse);
    });

    test('sin permiso (403): se dice, la opción se apaga y la cola se queda', () async {
      sinPlugins(red: 'wifi');
      montar();
      await db.setValue(MasterSyncService.llavePermiso, '1');
      await crearClienteYCentro();
      srv.responder('POST /api/masters/push', 403, {'message': 'Tu cuenta no puede crear ni editar clientes o pisciculturas desde la app.'});
      srv.responder('GET /api/masters/me', 200, {'id': 'u', 'email': 'x@aolab.cl', 'puedeEditarMaestros': false});
      await app.sync.sync();
      expect(app.sync.lastError, contains('tu cuenta ya no puede crearlos ni editarlos'));
      expect(await db.maestrosPendientesCount(), 2);
      expect(db.kv[MasterSyncService.llavePermiso], '0');
    });

    test('el permiso: lo anuncia el servidor y lo dice la cuenta; sin red queda lo último', () async {
      sinPlugins(red: 'wifi');
      Future<String?> permiso({required bool capacidad, required bool puede}) async {
        montar(capacidad: capacidad, puede: puede);
        await app.sync.sync();
        return db.kv[MasterSyncService.llavePermiso];
      }

      expect(await permiso(capacidad: true, puede: true), '1');
      expect(await permiso(capacidad: true, puede: false), '0');
      expect(await permiso(capacidad: false, puede: true), '0'); // servidor anterior: /me ni se pregunta
      // Sin red: lo último que se supo.
      montar();
      db.kv[MasterSyncService.llavePermiso] = '1';
      srv.fallar('GET /api/app/version', DioExceptionType.connectionError);
      await MasterSyncService(db: db, api: app.auth.api).pull();
      expect(db.kv[MasterSyncService.llavePermiso], '1');
    });
  });

  group('Coordenadas y duplicados en la tablet', () {
    test('las coordenadas aceptan coma o punto y se revisan', () {
      expect(coordenada('-41,4693'), -41.4693);
      expect(coordenada(' -72.9424 '), -72.9424);
      expect(coordenada(''), isNull);
      expect(errorCoordenada('abc', latitud: true), startsWith('Escribe un número'));
      expect(errorCoordenada('-95', latitud: true), 'Tiene que estar entre -90 y 90');
      expect(errorCoordenada('-179.5', latitud: false), isNull);
      expect(errorCoordenada('181', latitud: false), 'Tiene que estar entre -180 y 180');
    });

    test('la misma regla que el servidor: el mismo RUT o, sin RUT, el mismo nombre', () {
      expect(rutNormal('076.123.456-k'), '76123456K');
      expect(nombreNormal('Salmones  Río-Negro S.A.'), 'salmones rio negro s a');
      expect(parecenElMismo('Otro', '76.123.456-k', 'Acme', '76123456-K'), isTrue);
      expect(parecenElMismo('Acme', '1-9', 'Acme', '2-7'), isFalse);
      expect(parecenElMismo('ACME', null, 'Acme', '1-9'), isTrue);
    });
  });

  group('La pantalla', () {
    late BaseEnMemoria db;
    late AppDePrueba app;

    setUp(sinPlugins); // sin señal: todo queda en la tablet

    Future<void> abrir(WidgetTester t, {bool puede = true}) async {
      db = BaseEnMemoria([_rio()], clientes: [_acme(), ClientRef(id: 'k2', name: 'Beta')]);
      if (puede) db.kv[MasterSyncService.llavePermiso] = '1';
      app = AppDePrueba(db, ServidorFalso());
      t.view.physicalSize = const Size(900, 1600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(app.montar(const AuditListScreen()));
      await t.pumpAndSettle();
    }

    Future<void> tocar(WidgetTester t, String clave) async {
      await t.tap(find.byKey(ValueKey(clave)));
      await t.pumpAndSettle();
    }

    Future<void> escribir(WidgetTester t, String clave, String texto) async {
      await t.enterText(find.byKey(ValueKey(clave)), texto);
      await t.pump();
    }

    String titulo(WidgetTester t) => t.widget<Text>(find.byKey(const ValueKey('titulo'))).data!;

    Future<void> editar(WidgetTester t, String clave) async {
      await tocar(t, clave);
      await t.tap(find.text('Editar datos'));
      await t.pumpAndSettle();
    }

    testWidgets('sin el permiso no se ofrece ni crear ni editar', (t) async {
      await abrir(t, puede: false);
      expect(find.byKey(const ValueKey('nuevo-cliente')), findsNothing);
      expect(find.byKey(const ValueKey('editar-cliente-k1')), findsNothing);
      // Con un solo cliente en la lista se sigue partiendo en sus pisciculturas, como antes.
      expect(titulo(t), 'Acme');
      expect(find.byKey(const ValueKey('nuevo-centro')), findsNothing);
      expect(find.byKey(const ValueKey('editar-centro-c1')), findsNothing);
    });

    testWidgets('cliente nuevo y su primera piscicultura, sin señal, y de ahí la primera evaluación', (t) async {
      await abrir(t);
      expect(titulo(t), 'Clientes');
      await tocar(t, 'nuevo-cliente');
      expect(t.widget<Text>(find.byKey(const ValueKey('titulo-ficha'))).data, 'Nuevo cliente');
      // Sin nombre no se guarda.
      await tocar(t, 'guardar-ficha');
      expect(find.text('Escribe el nombre'), findsOneWidget);
      await escribir(t, 'campo-nombre', '  Salmones del Fiordo ');
      await escribir(t, 'campo-rut', '77.111.222-3');
      await tocar(t, 'guardar-ficha');

      // Sigue su primera piscicultura (se puede dejar para «Después»).
      expect(t.widget<Text>(find.byKey(const ValueKey('titulo-ficha'))).data, 'Su primera piscicultura');
      expect(find.text('Salmones del Fiordo'), findsWidgets);
      await escribir(t, 'campo-nombre', 'Piscicultura Estero');
      await escribir(t, 'campo-codigo', 'PE-01');
      await escribir(t, 'campo-latitud', 'abc');
      await escribir(t, 'campo-longitud', '-200');
      await tocar(t, 'guardar-ficha');
      expect(find.textContaining('Escribe un número'), findsOneWidget);
      expect(find.text('Tiene que estar entre -180 y 180'), findsOneWidget);
      await escribir(t, 'campo-latitud', '-41,8');
      await escribir(t, 'campo-longitud', '-73,05');
      await tocar(t, 'guardar-ficha');

      // Quedó dentro de la piscicultura nueva, lista para evaluar.
      expect(titulo(t), 'Piscicultura Estero');
      expect(t.widget<Text>(find.byKey(const ValueKey('titulo-encima'))).data, 'Salmones del Fiordo');
      final cola = await db.maestrosPendientes();
      expect(cola.map((p) => (p.tipo, p.nuevo)), [('cliente', true), ('centro', true)]);
      final cliente = db.clientes.singleWhere((c) => c.name == 'Salmones del Fiordo');
      expect(cliente.legalId, '77.111.222-3');
      final centro = db.centros.singleWhere((c) => c.name == 'Piscicultura Estero');
      expect((centro.ownerClientId, centro.code, centro.latitude, centro.longitude), (cliente.id, 'PE-01', -41.8, -73.05));
      expect(find.textContaining('2 clientes o pisciculturas por subir'), findsOneWidget);

      // «Nueva» desde ahí nace con ese cliente y esa piscicultura.
      await t.tap(find.text('Nueva'));
      await t.pumpAndSettle();
      final ev = db.audits.values.single;
      expect((ev.clientId, ev.centerId, ev.clientName), (cliente.id, centro.id, 'Salmones del Fiordo'));
    });

    testWidgets('«Después»: el cliente nuevo queda en la lista, sin piscicultura, para crearla luego', (t) async {
      await abrir(t);
      await tocar(t, 'nuevo-cliente');
      await escribir(t, 'campo-nombre', 'Cliente Solo');
      await tocar(t, 'guardar-ficha');
      await tocar(t, 'cancelar-ficha');
      expect(titulo(t), 'Cliente Solo');
      expect(find.byKey(const ValueKey('nuevo-centro')), findsOneWidget);
      await tocar(t, 'miga-clientes');
      final id = db.clientes.singleWhere((c) => c.name == 'Cliente Solo').id;
      expect(find.byKey(ValueKey('cliente-$id')), findsOneWidget);
      expect(find.text('0 evaluaciones · datos por subir'), findsOneWidget);
    });

    testWidgets('el mismo RUT que otro de la tablet: se pregunta antes de crearlo', (t) async {
      await abrir(t);
      await tocar(t, 'nuevo-cliente');
      await escribir(t, 'campo-nombre', 'Acme Sur');
      await escribir(t, 'campo-rut', '76123456-k');
      await tocar(t, 'guardar-ficha');
      expect(find.text('¿Es el mismo cliente?'), findsOneWidget);
      expect(find.textContaining('Ya existe «Acme» (RUT 76.123.456-K)'), findsOneWidget);
      await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Cancelar')));
      await t.pumpAndSettle();
      expect(db.pendientes, isEmpty); // nada se guardó; el formulario sigue abierto
      expect(find.byKey(const ValueKey('titulo-ficha')), findsOneWidget);
      await tocar(t, 'guardar-ficha');
      await t.tap(find.text('Guardar igual'));
      await t.pumpAndSettle();
      expect(db.clientes.where((c) => c.name == 'Acme Sur'), hasLength(1));
    });

    testWidgets('editar los datos de un cliente y de una piscicultura que existen', (t) async {
      await abrir(t);
      await editar(t, 'editar-cliente-k1');
      expect(t.widget<Text>(find.byKey(const ValueKey('titulo-ficha'))).data, 'Editar cliente');
      expect(find.text('Acme'), findsWidgets);
      await escribir(t, 'campo-nombre', 'Acme Chile');
      await tocar(t, 'guardar-ficha');
      expect(find.byKey(const ValueKey('cliente-k1')), findsOneWidget);
      expect(find.text('Acme Chile'), findsOneWidget);
      expect((await db.maestrosPendientes()).single.base, {'nombre': 'Acme', 'rut': '76.123.456-K'});

      await tocar(t, 'cliente-k1');
      await editar(t, 'editar-centro-c1');
      expect(t.widget<Text>(find.byKey(const ValueKey('titulo-ficha'))).data, 'Editar piscicultura');
      await escribir(t, 'campo-latitud', '-41.25');
      await tocar(t, 'guardar-ficha');
      final p = (await db.maestrosPendientes()).singleWhere((x) => x.tipo == kTipoCentro);
      expect((p.nuevo, p.datos['latitud'], p.base!['latitud'], p.datos['clienteId']), (false, -41.25, -41.0, 'k1'));
      expect(find.text('0 evaluaciones · datos por subir'), findsOneWidget);
    });

    testWidgets('«Sin cliente» no ofrece crear piscicultura ni editar', (t) async {
      db = BaseEnMemoria([_rio()], clientes: [_acme()]);
      db.kv[MasterSyncService.llavePermiso] = '1';
      db.audits['s'] = evaluacion(id: 's')..centerId = null;
      app = AppDePrueba(db, ServidorFalso());
      t.view.physicalSize = const Size(900, 1600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(app.montar(const AuditListScreen()));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('editar-cliente-')), findsNothing);
      await tocar(t, 'cliente-');
      expect(find.byKey(const ValueKey('nuevo-centro')), findsNothing);
    });
  });
}
