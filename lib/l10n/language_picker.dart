import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'l10n.dart';
import 'locale_controller.dart';

class LanguagePicker extends ConsumerWidget {
  const LanguagePicker({super.key, this.enabled = true});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(localeProvider)?.languageCode;
    return DropdownButton<String?>(
      value: selected,
      isExpanded: true,
      onChanged: enabled
          ? (code) => ref
                .read(localeProvider.notifier)
                .set(code == null ? null : Locale(code))
          : null,
      items: [
        DropdownMenuItem(value: null, child: Text(context.l10n.languageDevice)),
        const DropdownMenuItem(value: 'en', child: Text('English')),
        const DropdownMenuItem(value: 'sk', child: Text('Slovenčina')),
      ],
    );
  }
}
