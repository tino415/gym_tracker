import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/exercise_seeds.dart';
import 'package:gym_tracker/phone/exercises/figure/figure_painter.dart';
import 'package:gym_tracker/phone/exercises/figure/figure_poses.dart';

const _columns = 5;
const _cell = Size(240, 260);
const _outputPath = 'build/figure_contact_sheet.png';

/// Renders every exercise that has a pose into one PNG, for `just contact-sheet`.
void main() {
  testWidgets('contact sheet', (tester) async {
    await _loadRoboto();
    final posed = [
      for (final seed in exerciseSeeds)
        if (figureFor(seed.id) != null) (name: seed.name, placement: figureFor(seed.id)!),
    ];
    final rows = (posed.length / _columns).ceil();
    tester.view.physicalSize = Size(_cell.width * _columns, _cell.height * rows);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sheetKey = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.teal, fontFamily: 'Roboto'),
        home: Scaffold(
          body: RepaintBoundary(
            key: sheetKey,
            child: ColoredBox(
              color: Colors.white,
              child: Wrap(
                children: [
                  for (final item in posed)
                    SizedBox.fromSize(
                      size: _cell,
                      child: Column(
                        children: [
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: ExerciseFigure(placement: item.placement),
                            ),
                          ),
                          Text(item.name, textAlign: TextAlign.center),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.runAsync(() async {
      final boundary = sheetKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      File(_outputPath)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes.buffer.asUint8List());
    });
    expect(File(_outputPath).existsSync(), isTrue);
  });
}

Future<void> _loadRoboto() async {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot == null) return;
  final font = File('$flutterRoot/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf');
  if (!font.existsSync()) return;
  final loader = FontLoader('Roboto')
    ..addFont(Future.value(ByteData.sublistView(Uint8List.fromList(font.readAsBytesSync()))));
  await loader.load();
}
