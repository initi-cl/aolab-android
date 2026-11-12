// La lista por niveles, como la pidió Alberto: primero el cliente, luego la piscicultura y luego sus evaluaciones. Lo que
// no tiene cliente o piscicultura no se pierde: queda en «Sin cliente» / «Sin piscicultura».
import 'package:aolab_android/models/audit.dart';
import 'package:aolab_android/models/master.dart';
import 'package:aolab_android/ui/arbol_evaluaciones.dart';
import 'package:aolab_android/ui/audit_edit_screen.dart';
import 'package:aolab_android/ui/audit_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apoyo/base_falsa.dart';
import 'apoyo/servidor_falso.dart';

const _demo = 'c0000000-0000-0000-0000-000000000001'; // el centro de evaluacion()

void main() {
  final acme = ClientRef(id: 'k1', name: 'Acme');
  final beta = ClientRef(id: 'k2', name: 'Beta');
  final sinNada = ClientRef(id: 'k9', name: 'Cliente sin nada');
  CenterRef centro(String id, String nombre, String? dueno) => CenterRef(id: id, name: nombre, ownerClientId: dueno);
  final centros = [
    centro(_demo, 'Centro Demo', 'k1'),
    centro('c2', 'Centro Dos', 'k1'),
    centro('c3', 'Río Tres', 'k2'),
    centro('c4', 'Centro sin dueño', null),
  ];

  Audit ev(String id, {String? cliente, String? clienteNombre, String? centro = _demo, String? centroNombre, int status = 0, bool porSubir = false}) {
    final a = evaluacion(id: id, status: status)
      ..clientId = cliente
      ..clientName = clienteNombre
      ..centerId = centro
      ..dirty = porSubir;
    if (centro == null) a.centerName = '(sin nombre)';
    if (centroNombre != null) a.centerName = centroNombre;
    return a;
  }

  /// Dos clientes con sus pisciculturas, y evaluaciones sin cliente y sin piscicultura.
  List<Audit> evaluaciones() => [
        ev('a1', cliente: 'k1', porSubir: true),
        ev('a2', cliente: 'k1', status: 1),
        ev('a3', cliente: 'k1', status: 3, porSubir: true),
        ev('b1', cliente: 'k2', centro: 'c3'),
        ev('s1', centro: _demo),
        ev('s2', centro: null, porSubir: true),
      ];

  group('Agrupar Cliente → Piscicultura', () {
    List<GrupoCliente> agrupar(List<Audit> l) => agruparEvaluaciones(
        evaluaciones: l,
        clientes: [acme, beta, sinNada],
        centros: centros,
        porSubir: {for (final a in l) if (a.dirty) a.id});

    test('por cliente mandante y centro; lo sin asignar al final', () {
      final g = agrupar(evaluaciones());
      expect(g.map((x) => x.nombre), ['Acme', 'Beta', kSinCliente]); // «Cliente sin nada» no aparece
      final acmeG = g[0];
      expect(acmeG.centros.map((c) => c.nombre), ['Centro Demo', 'Centro Dos']); // Centro Dos sin evaluaciones
      expect(acmeG.evaluaciones, 3);
      expect(acmeG.porSubir, 2);
      expect(acmeG.pisciculturas, 2);
      expect(acmeG.centro(_demo)!.evaluaciones.map((a) => a.id), ['a1', 'a2', 'a3']);
      expect(acmeG.centro('c2')!.evaluaciones, isEmpty);
      final sin = g[2];
      expect(sin.id, isNull);
      expect(sin.centros.map((c) => c.nombre), ['Centro Demo', kSinPiscicultura]);
      expect(sin.centro(kSinAsignar)!.evaluaciones.single.id, 's2');
      expect(sin.porSubir, 1);
      // Todas las evaluaciones quedan en algún lado.
      expect(g.fold<int>(0, (n, x) => n + x.evaluaciones), 6);
    });

    test('un cliente o centro que ya no está activo se nombra con lo que guardó la evaluación', () {
      final g = agrupar([ev('x', cliente: 'k-viejo', clienteNombre: 'Cliente Antiguo', centro: 'c-viejo', centroNombre: 'Piscicultura Vieja')]);
      expect(g.map((x) => x.nombre), ['Acme', 'Beta', 'Cliente Antiguo']);
      expect(g.last.centros.single.nombre, 'Piscicultura Vieja');
    });

    test('un centro sin dueño solo aparece si tiene evaluaciones', () {
      expect(agrupar([]).expand((g) => g.centros).map((c) => c.nombre), isNot(contains('Centro sin dueño')));
      final g = agrupar([ev('x', centro: 'c4')]);
      expect(g.last.nombre, kSinCliente);
      expect(g.last.centros.single.nombre, 'Centro sin dueño');
    });
  });

  group('La pantalla por niveles', () {
    setUp(sinPlugins);

    Future<BaseEnMemoria> abrir(WidgetTester t, List<Audit> audits, {List<ClientRef>? clientes}) async {
      final db = BaseEnMemoria(centros, clientes: clientes ?? [acme, beta, sinNada]);
      for (final a in audits) {
        db.audits[a.id] = a;
      }
      final app = AppDePrueba(db, ServidorFalso());
      t.view.physicalSize = const Size(900, 1600);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(app.montar(const AuditListScreen()));
      await t.pumpAndSettle();
      return db;
    }

    Future<void> tocar(WidgetTester t, String clave) async {
      await t.tap(find.byKey(ValueKey(clave)));
      await t.pumpAndSettle();
    }

    String titulo(WidgetTester t) => t.widget<Text>(find.byKey(const ValueKey('titulo'))).data!;

    testWidgets('Clientes → Piscicultura → evaluaciones, con contadores, y de vuelta', (t) async {
      await abrir(t, evaluaciones());
      // 1. Clientes
      expect(titulo(t), 'Clientes');
      expect(find.byType(BackButton), findsNothing);
      expect(find.text('2 pisciculturas · 3 evaluaciones · 2 por subir'), findsOneWidget); // Acme
      expect(find.text('1 piscicultura · 1 evaluación'), findsOneWidget); // Beta
      expect(find.text('1 piscicultura · 2 evaluaciones · 1 por subir'), findsOneWidget); // Sin cliente: Centro Demo y «Sin piscicultura»
      expect(find.byKey(const ValueKey('ev-a1')), findsNothing);
      expect(find.byKey(const ValueKey('filtro-todas')), findsNothing); // el filtro es de las evaluaciones

      // 2. Pisciculturas de Acme
      await tocar(t, 'cliente-k1');
      expect(titulo(t), 'Acme');
      expect(find.text('3 evaluaciones · 2 por subir'), findsOneWidget);
      expect(find.text('Sin evaluaciones.'), findsNothing);
      expect(find.byKey(const ValueKey('centro-c2')), findsOneWidget);
      expect(find.text('0 evaluaciones'), findsOneWidget);

      // 3. Evaluaciones de Centro Demo de Acme (no las de otro cliente en el mismo centro)
      await tocar(t, 'centro-$_demo');
      expect(titulo(t), 'Centro Demo');
      expect(find.byKey(const ValueKey('ev-a1')), findsOneWidget);
      expect(find.byKey(const ValueKey('ev-s1')), findsNothing);
      expect(find.text('Todas (3)'), findsOneWidget);
      await tocar(t, 'filtro-finalizadas');
      expect(find.byKey(const ValueKey('ev-a2')), findsOneWidget);
      expect(find.byKey(const ValueKey('ev-a1')), findsNothing);

      // Atrás (el botón de Android) sube un nivel; las migas vuelven directo a Clientes.
      expect(await t.binding.handlePopRoute(), isTrue);
      await t.pumpAndSettle();
      expect(titulo(t), 'Acme');
      await tocar(t, 'centro-c2');
      expect(find.text('Sin evaluaciones.'), findsOneWidget);
      await tocar(t, 'miga-cliente');
      expect(titulo(t), 'Acme');
      await t.tap(find.byType(BackButton));
      await t.pumpAndSettle();
      expect(titulo(t), 'Clientes');
    });

    testWidgets('lo sin cliente y sin piscicultura se encuentra', (t) async {
      await abrir(t, evaluaciones());
      await tocar(t, 'cliente-');
      expect(titulo(t), kSinCliente);
      await tocar(t, 'centro-');
      expect(titulo(t), kSinPiscicultura);
      expect(find.byKey(const ValueKey('ev-s2')), findsOneWidget);
      await tocar(t, 'miga-clientes');
      expect(titulo(t), 'Clientes');
    });

    testWidgets('con un solo cliente se parte en sus pisciculturas, sin «atrás»', (t) async {
      await abrir(t, [ev('a1', cliente: 'k1')], clientes: [acme]);
      expect(titulo(t), 'Acme');
      expect(find.text('Pisciculturas'), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
      expect(find.byKey(const ValueKey('miga-clientes')), findsNothing);
      await tocar(t, 'centro-$_demo');
      expect(find.byKey(const ValueKey('ev-a1')), findsOneWidget);
      await t.tap(find.byType(BackButton));
      await t.pumpAndSettle();
      expect(titulo(t), 'Acme');
      expect(find.byType(BackButton), findsNothing);
    });

    testWidgets('una tablet vacía lo dice', (t) async {
      await abrir(t, [], clientes: []);
      expect(titulo(t), 'Clientes');
      expect(find.text('Sin evaluaciones.'), findsOneWidget);
    });

    testWidgets('«Nueva» dentro de una piscicultura nace con su cliente y su centro', (t) async {
      final db = await abrir(t, evaluaciones());
      await tocar(t, 'cliente-k1');
      await tocar(t, 'centro-c2');
      await t.tap(find.text('Nueva'));
      await t.pumpAndSettle();
      expect(find.byType(AuditEditScreen), findsOneWidget);
      final nueva = db.audits.values.singleWhere((a) => !evaluaciones().any((x) => x.id == a.id));
      expect((nueva.clientId, nueva.clientName, nueva.centerId, nueva.centerName), ('k1', 'Acme', 'c2', 'Centro Dos'));
      expect(nueva.statusEnum, AuditStatus.scheduled);
      // De vuelta en la lista, aparece en esa piscicultura.
      await t.pageBack();
      await t.pumpAndSettle();
      expect(titulo(t), 'Centro Dos');
      expect(find.byKey(ValueKey('ev-${nueva.id}')), findsOneWidget);
    });

    testWidgets('«Nueva» en las pisciculturas de un cliente lleva solo el cliente; en «Sin…», nada', (t) async {
      final db = await abrir(t, evaluaciones());
      await tocar(t, 'cliente-k2');
      await t.tap(find.text('Nueva'));
      await t.pumpAndSettle();
      final n1 = db.audits.values.singleWhere((a) => !evaluaciones().any((x) => x.id == a.id));
      expect((n1.clientId, n1.centerId), ('k2', null));
      await t.pageBack();
      await t.pumpAndSettle();
      await tocar(t, 'miga-clientes');
      await tocar(t, 'cliente-');
      await tocar(t, 'centro-');
      await t.tap(find.text('Nueva'));
      await t.pumpAndSettle();
      final n2 = db.audits.values.singleWhere((a) => a.id != n1.id && !evaluaciones().any((x) => x.id == a.id));
      expect((n2.clientId, n2.centerId, n2.tituloCentro), (null, null, 'Evaluación nueva'));
    });
  });
}
