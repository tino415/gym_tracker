import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'l10n/l10n.dart';

/// Where the published privacy policy lives.
///
/// Served as a static file from the app's Firebase Hosting site
/// (`web/privacy.html`), so it is reachable without signing in.
///
/// **Mirrored in `android/app/src/main/res/values/strings.xml` as
/// `privacy_policy_url`** — that copy is what the Health Connect rationale
/// screen opens, and it is native code that cannot read this constant. Change
/// both, and keep them the policy published in Play Console or the Health
/// Connect review will bounce.
const String privacyPolicyUrl =
    'https://gym-tracker-44a5f.web.app/privacy.html';

/// Open the privacy policy, telling the user where to find it if nothing can.
///
/// Best-effort by design: this is reached from a consent control, and failing
/// to open a browser must never block or undo the decision the user came to
/// make. On web this opens a new tab; on Android it hands off to the browser
/// (which needs the `<queries>` entry in the manifest to be visible at all).
Future<void> openPrivacyPolicy(BuildContext context) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final l10n = context.l10n;
  var opened = false;
  try {
    opened = await launchUrl(
      Uri.parse(privacyPolicyUrl),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    opened = false;
  }
  if (opened) return;
  messenger?.showSnackBar(
    SnackBar(
      content: Text(l10n.privacyPolicyFallback(privacyPolicyUrl)),
      duration: const Duration(seconds: 8),
    ),
  );
}

/// The link shown next to a consent control.
///
/// Deliberately a plain text button rather than a dialog: the policy is a page,
/// and burying it behind another tap makes it less likely to be read.
class PrivacyPolicyLink extends StatelessWidget {
  const PrivacyPolicyLink({super.key, this.padding = EdgeInsets.zero});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: () => openPrivacyPolicy(context),
          child: Text(context.l10n.privacyReadPolicy),
        ),
      ),
    );
  }
}
