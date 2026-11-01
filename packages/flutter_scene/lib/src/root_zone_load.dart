import 'dart:async';

/// A load every caller of a process shares.
///
/// It runs in the root zone, so it settles for a caller in any zone, also
/// after the zone of the first caller stops running, such as a finished
/// widget test's. Each caller reads the outcome in its own zone, since an
/// error reaches no listener across an error zone.
final class RootZoneLoad<T> {
  RootZoneLoad(Future<T> Function() load)
    : _outcome = Zone.root.run(
        () => load().then<(T?, Object?, StackTrace?)>(
          (value) => (value, null, null),
          onError: (Object error, StackTrace stack) => (null, error, stack),
        ),
      ) {
    settled = Zone.root.run(() => _outcome.then<void>((_) {}));
  }

  final Future<(T?, Object?, StackTrace?)> _outcome;

  /// Completes once the load settles, successfully or not. Never fails.
  late final Future<void> settled;

  /// The outcome of the load, for a caller in the current zone.
  Future<T> get future => _outcome.then((outcome) {
    final (value, error, stack) = outcome;
    if (error != null) Error.throwWithStackTrace(error, stack!);
    return value as T;
  });
}
