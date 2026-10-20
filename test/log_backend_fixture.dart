import 'package:proxy_ui/src/ffi/proxy_service.dart';
import 'package:proxy_ui/src/services/desktop_log_service.dart';

class RecordingLogBackend implements DesktopLogBackend {
  final entries = <LogEntry>[];
  String? directory;
  int flushes = 0;
  @override
  Future<void> configure(String path) async {
    directory = path;
  }

  @override
  void write(LogEntry entry) {
    entries.add(entry);
  }

  @override
  Future<void> flush() async {
    flushes++;
  }
}
