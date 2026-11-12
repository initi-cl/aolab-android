import '../models/audit.dart';
import '../models/master.dart';

/// La clave del grupo de lo que no tiene cliente (o piscicultura): ningún id del servidor es vacío.
const String kSinAsignar = '';

const String kSinCliente = 'Sin cliente';
const String kSinPiscicultura = 'Sin piscicultura';

/// Una piscicultura (centro) dentro de un cliente, con sus evaluaciones. [id] es null en «Sin piscicultura».
class GrupoCentro {
  final String? id;
  final String nombre;
  final List<Audit> evaluaciones = [];

  /// Cuántas de sus evaluaciones quedan por subir desde esta tablet.
  int porSubir = 0;

  GrupoCentro(this.id, this.nombre);

  String get clave => id ?? kSinAsignar;
}

/// Un cliente con sus pisciculturas. [id] es null en «Sin cliente».
class GrupoCliente {
  final String? id;
  final String nombre;
  final Map<String, GrupoCentro> _centros = {};

  GrupoCliente(this.id, this.nombre);

  String get clave => id ?? kSinAsignar;

  /// Las pisciculturas por nombre; «Sin piscicultura» al final.
  List<GrupoCentro> get centros => _centros.values.toList()
    ..sort((a, b) {
      if ((a.id == null) != (b.id == null)) return a.id == null ? 1 : -1;
      return a.nombre.toLowerCase().compareTo(b.nombre.toLowerCase());
    });

  GrupoCentro? centro(String clave) => _centros[clave];

  int get evaluaciones => _centros.values.fold(0, (n, c) => n + c.evaluaciones.length);
  int get porSubir => _centros.values.fold(0, (n, c) => n + c.porSubir);

  /// Cuántas pisciculturas de verdad (sin contar «Sin piscicultura»).
  int get pisciculturas => _centros.values.where((c) => c.id != null).length;
}

/// Ordena lo de la tablet en Cliente → Piscicultura → evaluaciones, para navegar en ese orden.
///
/// - El cliente de una evaluación es su cliente mandante (`clientId`); sin él, va a «Sin cliente» (no se deduce del dueño
///   del centro: lo que el evaluador no eligió no se inventa).
/// - La piscicultura es su centro (`centerId`); sin él, va a «Sin piscicultura».
/// - Los nombres salen del maestro; si el cliente o el centro ya no está activo, del nombre que guardó la evaluación.
/// - Las pisciculturas activas del maestro aparecen bajo su cliente dueño aunque no tengan evaluaciones (para crear una
///   desde ahí). Un cliente sin pisciculturas ni evaluaciones no aparece; un centro sin dueño, solo si tiene evaluaciones.
/// - [porSubir] son los ids de las evaluaciones que esta tablet tiene por subir.
/// - Los clientes de [clientesSiempre] (los creados o editados en la tablet que faltan por subir) aparecen aunque todavía
///   no tengan pisciculturas: recién creado, de ahí se le crea la primera.
List<GrupoCliente> agruparEvaluaciones({
  required List<Audit> evaluaciones,
  required List<ClientRef> clientes,
  required List<CenterRef> centros,
  Set<String> porSubir = const {},
  Set<String> clientesSiempre = const {},
}) {
  final clientePorId = {for (final c in clientes) c.id: c};
  final centroPorId = {for (final c in centros) c.id: c};
  final grupos = <String, GrupoCliente>{};

  GrupoCliente cliente(String? id, String? nombreGuardado) => grupos.putIfAbsent(id ?? kSinAsignar, () {
        if (id == null) return GrupoCliente(null, kSinCliente);
        final n = clientePorId[id]?.name.trim() ?? nombreGuardado?.trim() ?? '';
        return GrupoCliente(id, n.isEmpty ? 'Cliente sin nombre' : n);
      });

  GrupoCentro centro(GrupoCliente g, String? id, String nombreGuardado) =>
      g._centros.putIfAbsent(id ?? kSinAsignar, () {
        if (id == null) return GrupoCentro(null, kSinPiscicultura);
        final n = centroPorId[id]?.name.trim() ?? '';
        return GrupoCentro(id, n.isEmpty ? nombreGuardado : n);
      });

  for (final c in clientes) {
    if (clientesSiempre.contains(c.id)) cliente(c.id, null);
  }
  for (final c in centros) {
    final dueno = c.ownerClientId;
    if (dueno != null && clientePorId.containsKey(dueno)) centro(cliente(dueno, null), c.id, c.name);
  }
  for (final a in evaluaciones) {
    final g = cliente(a.clientId, a.clientName);
    final c = centro(g, a.centerId, a.tituloCentro);
    c.evaluaciones.add(a);
    if (porSubir.contains(a.id)) c.porSubir++;
  }

  return grupos.values.toList()
    ..sort((a, b) {
      if ((a.id == null) != (b.id == null)) return a.id == null ? 1 : -1;
      return a.nombre.toLowerCase().compareTo(b.nombre.toLowerCase());
    });
}

/// «1 evaluación», «3 evaluaciones».
String nEvaluaciones(int n) => n == 1 ? '1 evaluación' : '$n evaluaciones';

/// «1 piscicultura», «2 pisciculturas».
String nPisciculturas(int n) => n == 1 ? '1 piscicultura' : '$n pisciculturas';
