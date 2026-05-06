import 'dart:developer' as developer;

/// Verbosity for [UwbLog]. Lower-priority levels are skipped when the
/// configured level is higher.
///
/// Ordering (least to most severe):
/// `debug` < `info` < `warn` < `error` < `off`.
///
/// `off` is a sentinel — it suppresses every log line, including
/// `error`, and is the default in release builds.
enum UwbLogLevel {
  /// Verbose tracing — wire-level codec dumps, BLE notifications, every
  /// state transition. Only useful when reproducing a specific bug.
  debug,

  /// Lifecycle and one-shot events — discovery start, peer found,
  /// session start/stop. Safe to leave on during development.
  info,

  /// Recoverable problems — a peer dropped mid-session, a vendor profile
  /// failed to register, a single GATT write timed out and was retried.
  warn,

  /// Unrecoverable failures — the active session ended, a permission was
  /// missing, a platform call returned a fatal error code.
  error,

  /// Suppress every log line. Default for production.
  off,
}

/// Lightweight logger with level filtering and an optional redirect
/// hook.
///
/// Silent by default — apps in release should not see any flutter_uwb
/// log output unless they opt in. Wire it up like this in your app's
/// `main()`:
///
/// ```dart
/// import 'package:flutter_uwb/flutter_uwb.dart';
///
/// void main() {
///   if (kDebugMode) UwbLog.setLevel(UwbLogLevel.debug);
///   UwbLog.setHandler((level, msg) {
///     // Pipe to your crash-reporting tool, e.g.:
///     // FirebaseCrashlytics.instance.log('[uwb] [$level] $msg');
///   });
///   runApp(const MyApp());
/// }
/// ```
///
/// When no handler is installed, log lines are forwarded to
/// `dart:developer`'s `log()` so they appear in the IDE / DevTools
/// timeline at the matching severity.
class UwbLog {
  UwbLog._();

  static UwbLogLevel _level = UwbLogLevel.off;
  static void Function(UwbLogLevel level, String message)? _handler;

  /// The current minimum level. Anything strictly less severe is dropped.
  static UwbLogLevel get level => _level;

  /// Set the minimum level. Pass [UwbLogLevel.off] to silence the
  /// logger entirely.
  static void setLevel(UwbLogLevel level) {
    _level = level;
  }

  /// Redirect every emitted line to [handler] instead of
  /// `dart:developer`'s `log()`. Pass `null` to restore the default
  /// behaviour.
  static void setHandler(
    void Function(UwbLogLevel level, String message)? handler,
  ) {
    _handler = handler;
  }

  /// Emit at [UwbLogLevel.debug]. No-op when [level] is higher.
  static void debug(String message) => _emit(UwbLogLevel.debug, message);

  /// Emit at [UwbLogLevel.info]. No-op when [level] is higher.
  static void info(String message) => _emit(UwbLogLevel.info, message);

  /// Emit at [UwbLogLevel.warn]. No-op when [level] is higher.
  static void warn(String message) => _emit(UwbLogLevel.warn, message);

  /// Emit at [UwbLogLevel.error]. No-op when [level] is
  /// [UwbLogLevel.off].
  static void error(String message) => _emit(UwbLogLevel.error, message);

  static void _emit(UwbLogLevel l, String message) {
    if (l.index < _level.index) return;
    final handler = _handler;
    if (handler != null) {
      handler(l, message);
      return;
    }
    developer.log(
      message,
      name: 'flutter_uwb',
      level: _devLevel(l),
    );
  }

  /// Map our level to `dart:developer.log`'s int convention (higher is
  /// more severe). The exact numbers match Dart's `Level` constants
  /// from `package:logging` so DevTools renders them with the right
  /// colours.
  static int _devLevel(UwbLogLevel l) {
    switch (l) {
      case UwbLogLevel.debug:
        return 500; // FINE
      case UwbLogLevel.info:
        return 800; // INFO
      case UwbLogLevel.warn:
        return 900; // WARNING
      case UwbLogLevel.error:
        return 1000; // SEVERE
      case UwbLogLevel.off:
        return 2000; // unreachable; _emit guards against it
    }
  }
}
