import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'generated/app_localizations.dart';

export 'generated/app_localizations.dart';

/// The selected language belongs to the application, including native menus.
class AppLanguage extends ChangeNotifier {
  AppLanguage();

  static final instance = AppLanguage();
  static const preferenceKey = 'app_language';
  String _selection = 'system';
  Locale _systemLocale = const Locale('en');

  String get selection => _selection;
  Locale get locale => Locale(
    _selection == 'system'
        ? (_systemLocale.languageCode == 'zh' ? 'zh' : 'en')
        : _selection,
  );
  AppLocalizations get strings => lookupAppLocalizations(locale);

  Future<void> load({Locale? systemLocale}) async {
    _systemLocale =
        systemLocale ?? WidgetsBinding.instance.platformDispatcher.locale;
    try {
      final saved = (await SharedPreferences.getInstance()).getString(
        preferenceKey,
      );
      _selection = ['system', 'zh', 'en'].contains(saved) ? saved! : 'system';
    } catch (_) {
      // Language preferences must not prevent the proxy from starting.
    }
    notifyListeners();
  }

  void systemLocaleChanged(Locale locale) {
    _systemLocale = locale;
    if (_selection == 'system') notifyListeners();
  }

  Future<void> select(String value) async {
    if (!['system', 'zh', 'en'].contains(value)) return;
    _selection = value;
    notifyListeners();
    final saved = await (await SharedPreferences.getInstance()).setString(
      preferenceKey,
      value,
    );
    if (!saved) throw StateError('Could not persist language');
  }
}

AppLocalizations get appStrings => AppLanguage.instance.strings;

extension LocalizedContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this) ?? appStrings;
}

class LanguageMenuButton extends StatelessWidget {
  const LanguageMenuButton({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppLanguage.instance,
    builder: (context, _) => PopupMenuButton<String>(
      tooltip: context.l10n.language,
      icon: const Icon(Icons.translate),
      initialValue: AppLanguage.instance.selection,
      onSelected: (value) async {
        try {
          await AppLanguage.instance.select(value);
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(content: Text(context.l10n.languageChangeFailed)),
            );
          }
        }
      },
      itemBuilder: (context) => [
        CheckedPopupMenuItem(
          value: 'system',
          checked: AppLanguage.instance.selection == 'system',
          child: Text(context.l10n.systemLanguage),
        ),
        CheckedPopupMenuItem(
          value: 'zh',
          checked: AppLanguage.instance.selection == 'zh',
          child: const Text('简体中文'),
        ),
        CheckedPopupMenuItem(
          value: 'en',
          checked: AppLanguage.instance.selection == 'en',
          child: const Text('English'),
        ),
      ],
    ),
  );
}
