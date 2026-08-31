import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `web/flutter_bootstrap.js` is load-bearing and easy to lose: delete it and
/// Flutter silently generates a default bootstrap with no `config`, which puts
/// CanvasKit back on the GPU and brings back the Safari WebGL-context leak that
/// made the app unusable. Nothing else would fail — not the build, not a test,
/// not a smoke check on Chrome — so the regression is invisible until someone
/// opens Safari.
void main() {
  final bootstrap = File('web/flutter_bootstrap.js');

  test('web bootstrap exists, so Flutter does not generate a default one', () {
    expect(bootstrap.existsSync(), isTrue);
  });

  test('web bootstrap keeps CanvasKit off the GPU by default', () {
    final source = bootstrap.readAsStringSync();

    expect(source, contains('canvasKitForceCpuOnly'));
    // The default arm, not merely one of the `renderer` overrides: a build
    // serves no query string.
    expect(source, contains(RegExp(r'\?\?\s*\{\s*canvasKitForceCpuOnly:\s*true')));
  });

  test('web bootstrap keeps the template tokens the build substitutes', () {
    final source = bootstrap.readAsStringSync();

    // Dropping these yields a bootstrap that loads nothing: flutter.js is
    // inlined here, and the service worker version is what invalidates it.
    expect(source, contains('{{flutter_js}}'));
    expect(source, contains('{{flutter_build_config}}'));
    expect(source, contains('{{flutter_service_worker_version}}'));
  });
}
