import 'package:flutter/foundation.dart';

import '../ffi/proxy_service.dart';
import '../models/website_rule.dart';

/// Why native code refused a rule change, as the local API names it.
enum WebsiteRuleError {
  /// The site does not parse.
  invalidRule,

  /// The rules file could not be read or written, or is full.
  storage;

  static WebsiteRuleError fromKind(Object? kind) =>
      kind == 'invalid_rule' ? invalidRule : storage;
}

/// The profile's website rules as the native store last reported them.
///
/// Native code owns validation, matching and the file; this keeps the list
/// the rules page draws. The local API's edits arrive through [replace].
class WebsiteRules extends ChangeNotifier {
  WebsiteRules(this._service);

  final ProxyService _service;
  List<WebsiteRule> _rules = const [];
  bool _loaded = false;
  bool _busy = false;
  WebsiteRuleError? _loadError;
  bool _disposed = false;

  List<WebsiteRule> get rules => _rules;
  bool get isLoaded => _loaded;
  bool get isBusy => _busy;

  /// Set when the last load failed; the list is then the previous one.
  WebsiteRuleError? get loadError => _loadError;

  Future<void> load() async {
    _loadError = await _apply({'action': 'list'});
    _notify();
  }

  /// Add or replace the rule for [site]. Returns null once saved.
  Future<WebsiteRuleError?> save(String site, RuleTarget target) =>
      _apply({'action': 'set', 'site': site, 'target': target.toJson()});

  Future<WebsiteRuleError?> remove(String site) =>
      _apply({'action': 'remove', 'site': site});

  /// Rules another writer just saved, in the store's own shape.
  void replace(Map<dynamic, dynamic> json) {
    _rules = WebsiteRule.listFromJson(json);
    _loaded = true;
    _loadError = null;
    _notify();
  }

  Future<WebsiteRuleError?> _apply(Map<String, Object?> change) async {
    _busy = true;
    _notify();
    try {
      final result = await _service.websiteRules(change);
      if (result['Ok'] case final Map rules) {
        replace(rules);
        return null;
      }
      return WebsiteRuleError.fromKind(result['Err']);
    } catch (error, stack) {
      debugPrint('Website rule operation failed: $error\n$stack');
      return WebsiteRuleError.storage;
    } finally {
      _busy = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
