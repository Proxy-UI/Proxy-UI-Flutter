import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_language.dart';
import '../services/app_brand.dart';
import 'store_demo_screen.dart';

/// The application builder cannot create native services until disclosure.
class StorePrivacyGate extends StatefulWidget {
  const StorePrivacyGate({super.key, required this.applicationBuilder});

  static const acknowledgementKey = 'store_privacy_acknowledgement';
  static const policyVersion = 1;
  final Widget Function() applicationBuilder;

  @override
  State<StorePrivacyGate> createState() => _StorePrivacyGateState();
}

class _StorePrivacyGateState extends State<StorePrivacyGate> {
  bool _loading = true;
  bool _accepted = false;
  bool _saving = false;
  bool _failed = false;
  Widget? _application;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var accepted = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      accepted =
          prefs.getInt(StorePrivacyGate.acknowledgementKey) ==
          StorePrivacyGate.policyVersion;
    } catch (_) {
      // Failure must keep the disclosure visible, not open the application.
    }
    if (mounted) {
      setState(() {
        _accepted = accepted;
        _loading = false;
      });
    }
  }

  Future<void> _accept() async {
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = await prefs.setInt(
        StorePrivacyGate.acknowledgementKey,
        StorePrivacyGate.policyVersion,
      );
      if (!saved) throw StateError('Privacy acknowledgement was not saved.');
      if (mounted) setState(() => _accepted = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_accepted) return _application ??= widget.applicationBuilder();
    return ListenableBuilder(
      listenable: AppLanguage.instance,
      builder: (context, _) => MaterialApp(
        title: AppBrand.name,
        debugShowCheckedModeBanner: false,
        locale: AppLanguage.instance.locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
        home: _loading
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : StorePrivacyScreen(
                onContinue: _accept,
                saving: _saving,
                failed: _failed,
              ),
      ),
    );
  }
}

class StorePrivacyButton extends StatelessWidget {
  const StorePrivacyButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: context.l10n.storePrivacyTitle,
    icon: const Icon(Icons.privacy_tip_outlined),
    onPressed: () => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const StorePrivacyScreen())),
  );
}

class StorePrivacyScreen extends StatelessWidget {
  const StorePrivacyScreen({
    super.key,
    this.onContinue,
    this.saving = false,
    this.failed = false,
  });
  final Future<void> Function()? onContinue;
  final bool saving;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final strings = context.l10n;
    final sections = [
      (strings.storePrivacyLocalTitle, strings.storePrivacyLocal),
      (strings.storePrivacyNetworkTitle, strings.storePrivacyNetwork),
      (strings.storePrivacyProtectionTitle, strings.storePrivacyProtection),
      (strings.storePrivacyControlTitle, strings.storePrivacyControl),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.storePrivacyTitle),
        actions: const [LanguageMenuButton()],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: ListView(
            padding: const EdgeInsets.all(32),
            children: [
              Text(
                AppBrand.name,
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 12),
              Text(
                strings.storePrivacyIntro,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (onContinue != null) ...[
                const SizedBox(height: 16),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: StoreDemoButton(),
                ),
              ],
              const SizedBox(height: 24),
              for (final section in sections) ...[
                Text(
                  section.$1,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                SelectableText(section.$2),
                const SizedBox(height: 20),
              ],
              SelectableText(strings.storePrivacyContact),
              if (failed) ...[
                const SizedBox(height: 16),
                Text(
                  strings.storePrivacySaveError,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (onContinue != null) ...[
                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: saving ? null : onContinue,
                    child: Text(strings.storePrivacyContinue),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
