/// Clientes y pisciculturas creados o editados en terreno (12-11-2026): lo que queda en la tablet hasta que se sube con
/// la próxima sincronización (`POST /api/masters/push`). Solo los datos básicos; el resto se completa en la web.
library;

import 'dart:convert';

import 'master.dart';

const String kTipoCliente = 'cliente';
const String kTipoCentro = 'centro';

/// Lo que el servidor anuncia en `/api/app/version` → `capacidades` cuando recibe clientes y pisciculturas de la app.
const String kCapacidadMaestros = 'maestros-terreno';

/// Un cliente o una piscicultura con cambios por subir.
///
/// [datos] es cómo quedó en la tablet; [base], cómo lo vio la tablet la última vez que lo bajó del servidor (null en uno
/// creado aquí que el servidor todavía no confirma). El servidor cambia solo lo que difiere de [base], y si alguien
/// cambió ese mismo dato en la web, se queda lo de la web. [rev] cuenta las ediciones: si se editó mientras el envío iba
/// y volvía, sigue pendiente.
class MaestroPendiente {
  final String tipo;
  final String id;
  bool nuevo;
  Map<String, dynamic> datos;
  Map<String, dynamic>? base;
  int rev;

  MaestroPendiente({
    required this.tipo,
    required this.id,
    required this.nuevo,
    required this.datos,
    this.base,
    this.rev = 1,
  });

  bool get esCliente => tipo == kTipoCliente;

  /// El nombre, para los avisos.
  String get nombre => (datos['nombre'] as String?) ?? '';

  Map<String, Object?> toRow() => {
        'tipo': tipo,
        'id': id,
        'nuevo': nuevo ? 1 : 0,
        'datos': jsonEncode(datos),
        'base': base == null ? null : jsonEncode(base),
        'rev': rev,
      };

  factory MaestroPendiente.fromRow(Map<String, Object?> r) => MaestroPendiente(
        tipo: r['tipo'] as String,
        id: r['id'] as String,
        nuevo: (r['nuevo'] as int? ?? 0) == 1,
        datos: (jsonDecode(r['datos'] as String) as Map).cast<String, dynamic>(),
        base: r['base'] == null ? null : (jsonDecode(r['base'] as String) as Map).cast<String, dynamic>(),
        rev: (r['rev'] as int?) ?? 1,
      );

  /// Como lo recibe el servidor (`ClienteTerrenoDto` / `CentroTerrenoDto`).
  Map<String, dynamic> toDto() => {'id': id, 'nuevo': nuevo, ...datos, 'base': nuevo ? null : base};
}

/// Los datos de un cliente que se manejan desde la app.
Map<String, dynamic> datosCliente(ClientRef c) => {'nombre': c.name, 'rut': c.legalId};

/// Los datos de una piscicultura que se manejan desde la app (el cliente solo cuenta al crearla).
Map<String, dynamic> datosCentro(CenterRef c) => {
      'nombre': c.name,
      'codigo': c.code,
      'latitud': c.latitude,
      'longitud': c.longitude,
      'clienteId': c.ownerClientId,
    };

/// Lo que se escribe en el formulario: sin espacios de más y, vacío, como «sin dato».
String? textoONulo(String? s) {
  final t = s?.trim() ?? '';
  return t.isEmpty ? null : t;
}

/// Una coordenada escrita a mano: acepta coma o punto decimal («-41,4693»). Null si está vacía; lanza [FormatException]
/// si no es un número.
double? coordenada(String? s) {
  final t = textoONulo(s);
  if (t == null) return null;
  final v = double.tryParse(t.replaceAll(',', '.'));
  if (v == null || v.isNaN || v.isInfinite) throw const FormatException('No es un número');
  return v;
}

/// El error de una coordenada para el formulario, o null si está bien (vacía también está bien).
String? errorCoordenada(String? s, {required bool latitud}) {
  final double? v;
  try {
    v = coordenada(s);
  } on FormatException {
    return 'Escribe un número, por ejemplo ${latitud ? '-41.4693' : '-72.9424'}';
  }
  if (v == null) return null;
  final max = latitud ? 90 : 180;
  if (v < -max || v > max) return 'Tiene que estar entre -$max y $max';
  return null;
}

// ── ¿Parecen el mismo cliente? La misma regla que el servidor (`DuplicadosCliente`) ──

/// El RUT sin puntos, guiones ni espacios, en mayúsculas y sin ceros a la izquierda. Null si no queda nada.
String? rutNormal(String? rut) {
  if (rut == null) return null;
  final s = rut.replaceAll(RegExp(r'[^0-9A-Za-z]'), '').toUpperCase().replaceFirst(RegExp(r'^0+'), '');
  return s.isEmpty ? null : s;
}

const Map<String, String> _sinTilde = {
  'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e', 'í': 'i', 'ì': 'i', 'ï': 'i', //
  'î': 'i', 'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o', 'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u', 'ñ': 'n', 'ç': 'c',
};

/// El nombre en minúsculas, sin tildes y con un solo espacio entre palabras (lo que no es letra ni número cuenta como
/// espacio). Null si no queda nada.
String? nombreNormal(String? nombre) {
  if (nombre == null) return null;
  final b = StringBuffer();
  for (final ch in nombre.toLowerCase().split('')) {
    final c = _sinTilde[ch] ?? ch;
    b.write(RegExp(r'[0-9a-z]').hasMatch(c) ? c : ' ');
  }
  final s = b.toString().split(' ').where((x) => x.isNotEmpty).join(' ');
  return s.isEmpty ? null : s;
}

/// ¿Parecen el mismo cliente? Con RUT los dos, si el RUT es el mismo; si a alguno le falta, si el nombre normalizado es
/// el mismo.
bool parecenElMismo(String? nombreA, String? rutA, String? nombreB, String? rutB) {
  final ra = rutNormal(rutA), rb = rutNormal(rutB);
  if (ra != null && rb != null) return ra == rb;
  final na = nombreNormal(nombreA);
  return na != null && na == nombreNormal(nombreB);
}
