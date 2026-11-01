import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/exercise_seeds.dart';
import 'package:gym_tracker/phone/exercises/figure/figure_painter.dart';
import 'package:gym_tracker/phone/exercises/figure/figure_poses.dart';
import 'package:gym_tracker/phone/exercises/figure/figure_spec.dart';

const _columns = 4;
const _cell = Size(240, 270);
const _wholeSheetPath = 'build/figure_contact_sheet.png';
const _groupSheetDir = 'build/figure_contact_sheets';

/// Renders the exercises that have a pose into PNGs, for `just contact-sheet`:
/// one sheet of everything and one per group.
void main() {
  testWidgets('contact sheet', (tester) async {
    await _loadRoboto();
    await _renderSheet(tester, figurePlacements, _wholeSheetPath);
    for (final group in figureGroups.entries) {
      await _renderSheet(tester, group.value, '$_groupSheetDir/${group.key}.png');
    }
    expect(File(_wholeSheetPath).existsSync(), isTrue);
  });
}

Future<void> _renderSheet(
  WidgetTester tester,
  Map<String, FigurePlacement> placements,
  String path,
) async {
  final posed = [
    for (final seed in exerciseSeeds)
      if (placements[seed.id] case final placement?) (name: seed.name, placement: placement),
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
                        Text(item.name, textAlign: TextAlign.center, maxLines: 2),
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
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes.buffer.asUint8List());
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
