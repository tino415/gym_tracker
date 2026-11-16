import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../privacy_policy.dart';
import '../../sync/connect_gateway.dart';

/// Where an AI assistant's sign-in lands. The MCP server sends the browser
/// here with a signed request; the user has already signed in to reach this
/// page (the web app is signed-in by construction), and decides on every
/// connect whether the assistant gets access.
class ConnectPage extends ConsumerStatefulWidget {
  const ConnectPage({super.key, required this.request});

  final String? request;

  @override
  ConsumerState<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends ConsumerState<ConnectPage> {
  bool _busy = false;
  bool _failed = false;

  Future<void> _decide(ConnectGateway gateway, ConnectDecision decision) async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final redirect = await gateway.decide(widget.request!, decision);
      if (redirect.scheme != 'https' && redirect.scheme != 'http') {
        throw ConnectRefused(0);
      }
      await ref.read(connectRedirectProvider)(redirect);
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final gateway = ref.watch(connectGatewayProvider);
    final request = widget.request;
    final client = request == null ? null : clientNameOf(request);
    final usable = gateway != null && request != null && client != null;
    return Scaffold(
      appBar: AppBar(title: const Text('GymTracker')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: usable
                ? _consent(context, gateway, client)
                : Text(
                    l10n.connectInvalidLink,
                    key: const Key('connect-invalid'),
                    textAlign: TextAlign.center,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _consent(BuildContext context, ConnectGateway gateway, String client) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.connectTitle(client), style: theme.textTheme.headlineSmall),
        const SizedBox(height: 16),
        Text(l10n.connectWhatItReads(client)),
        const SizedBox(height: 16),
        Text(
          l10n.connectWarning(client),
          key: const Key('connect-warning'),
          style: TextStyle(color: theme.colorScheme.error),
        ),
        const PrivacyPolicyLink(padding: EdgeInsets.only(top: 8)),
        if (_failed) ...[
          const SizedBox(height: 8),
          Text(
            l10n.connectFailed,
            key: const Key('connect-failed'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('connect-allow'),
          onPressed: _busy
              ? null
              : () => _decide(gateway, ConnectDecision.allow),
          child: Text(l10n.connectAllow),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const Key('connect-deny'),
          onPressed: _busy
              ? null
              : () => _decide(gateway, ConnectDecision.deny),
          child: Text(l10n.connectDeny),
        ),
      ],
    );
  }
}
