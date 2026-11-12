import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// El ingreso con Microsoft fallaba siempre en la tablet («Issuer mismatch» de AppAuth): el documento de descubrimiento de
// «organizations» publica el emisor como «…/{tenantid}/v2.0» y AppAuth lo compara con el emisor real del idToken.
// Sin documento de descubrimiento (puntos de entrada dados a mano) AppAuth no hace esa comparación.
void main() {
  test('Microsoft entra sin documento de descubrimiento', () {
    final codigo = File('lib/services/auth_service.dart').readAsStringSync();
    final inicio = codigo.substring(codigo.indexOf('class InicioMicrosoft'), codigo.indexOf('abstract class DatosLocales'));
    expect(inicio.contains('discoveryUrl:'), isFalse);
    expect(inicio.contains('serviceConfiguration: const AuthorizationServiceConfiguration('), isTrue);
    final config = File('lib/config.dart').readAsStringSync();
    expect(config.contains('.well-known/openid-configuration'), isFalse);
    expect(config.contains("'https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize'"), isTrue);
  });
}
