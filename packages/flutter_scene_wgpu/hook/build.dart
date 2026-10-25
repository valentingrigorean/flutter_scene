// Build hook for flutter_scene_wgpu.
//
// Invoked by the Flutter SDK before a build to materialize the
// flutter_scene_wgpu_native dynamic library and register it as a code
// asset so it gets bundled with the app and loaded at runtime by the FFI
// bindings.
//
// The library is built from source with `cargo build --release` for the
// target's triple, so a Rust toolchain is required.
//
// The same dynamic-loading code asset is emitted for every platform: the
// SDK does not yet support static linking of code assets, so even iOS
// ships the cdylib (bundled into a framework by the SDK).

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const _nativeLibraryName = 'flutter_scene_wgpu_native';

Future<void> main(List<String> args) async {
  await build(args, _build);
}

Future<void> _build(BuildInput input, BuildOutputBuilder output) async {
  if (!input.config.buildCodeAssets) return;

  final code = input.config.code;
  final triple = _rustTriple(code);
  if (triple == null) {
    throw UnimplementedError(
      'No Rust target triple is wired up for '
      '${code.targetOS}/${code.targetArchitecture}. Add it to '
      '_rustTriple in hook/build.dart.',
    );
  }

  final libUri = await _resolveLibrary(input, code, triple, output);

  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: _nativeLibraryName,
      linkMode: DynamicLoadingBundled(),
      file: libUri,
    ),
  );
}

// Returns the URI of the library to bundle, built from source, and records
// the hook's dependencies so it re-runs when its inputs change.
Future<Uri> _resolveLibrary(
  BuildInput input,
  CodeConfig code,
  String triple,
  BuildOutputBuilder output,
) async {
  // Source build only: depend on the native sources so edits trigger a
  // rebuild.
  final nativeDir = Directory.fromUri(input.packageRoot.resolve('native/'));
  output.dependencies.addAll([
    input.packageRoot.resolve('native/Cargo.toml'),
    input.packageRoot.resolve('native/Cargo.lock'),
    for (final entity in Directory.fromUri(
      nativeDir.uri.resolve('src/'),
    ).listSync(recursive: true))
      if (entity is File) entity.uri,
  ]);
  return _buildFromSource(input, code, triple);
}

// ---------------------------------------------------------------------------
// Source build
// ---------------------------------------------------------------------------

Future<Uri> _buildFromSource(
  BuildInput input,
  CodeConfig code,
  String triple,
) async {
  await _ensureRustTarget(triple);

  final nativeDir = Directory.fromUri(input.packageRoot.resolve('native/'));
  final environment = _cargoEnvironment(code, triple);
  await _runCargo(nativeDir, triple, environment);

  final libFileName = code.targetOS.dylibFileName(_nativeLibraryName);
  final libUri = input.packageRoot.resolve(
    'native/target/$triple/release/$libFileName',
  );
  final libFile = File.fromUri(libUri);
  if (!libFile.existsSync()) {
    throw Exception(
      'cargo build succeeded but ${libFile.path} is missing. Check that '
      'native/Cargo.toml lists "cdylib" in [lib].crate-type.',
    );
  }
  return libUri;
}

Future<void> _runCargo(
  Directory nativeDir,
  String targetTriple,
  Map<String, String> environment,
) async {
  final result = await Process.run(
    'cargo',
    ['build', '--release', '--target', targetTriple],
    workingDirectory: nativeDir.path,
    environment: environment,
  );
  if (result.exitCode != 0) {
    throw Exception(
      'cargo build --target $targetTriple failed (${result.exitCode}) in '
      '${nativeDir.path}:\n${result.stdout}\n${result.stderr}',
    );
  }
}

// Makes sure the Rust standard library for [triple] is installed. The
// build fails with a clear "can't find crate for `std`" otherwise. This
// is a no-op (and instant) when the target is already present. Tolerates
// a missing rustup: if rustup is not on PATH the target may still be
// installed through another channel, so let the cargo build surface the
// real error instead of failing here.
Future<void> _ensureRustTarget(String triple) async {
  try {
    final installed = await Process.run('rustup', [
      'target',
      'list',
      '--installed',
    ]);
    if (installed.exitCode == 0 &&
        (installed.stdout as String).split('\n').contains(triple)) {
      return;
    }
    await Process.run('rustup', ['target', 'add', triple]);
  } on ProcessException {
    // rustup is not available; assume the target is provided some other
    // way and let `cargo build` report a precise error if it is not.
  }
}

// Builds the extra environment variables cargo needs for the target.
// The parent environment is inherited; these entries are layered on top.
Map<String, String> _cargoEnvironment(CodeConfig code, String triple) {
  final environment = <String, String>{};

  if (code.targetOS == OS.iOS) {
    // rustc selects the iphoneos / iphonesimulator SDK from the triple
    // and resolves clang through xcrun; only the deployment target needs
    // to be forwarded.
    environment['IPHONEOS_DEPLOYMENT_TARGET'] = '${code.iOS.targetVersion}';
  } else if (code.targetOS == OS.macOS) {
    environment['MACOSX_DEPLOYMENT_TARGET'] = '${code.macOS.targetVersion}';
  } else if (code.targetOS == OS.android) {
    // Link with the NDK's clang driver (it locates its own sysroot), and
    // tell it the ABI and API level through the clang target triple. The
    // SDK supplies the NDK toolchain paths in code.cCompiler.
    final compiler = code.cCompiler?.compiler;
    if (compiler == null) {
      throw Exception(
        'Building flutter_scene_wgpu_native for Android requires an NDK '
        'C compiler in the build config (code.cCompiler), but none was '
        'provided.',
      );
    }
    final api = code.android.targetNdkApi;
    final cargoTriple = triple.toUpperCase().replaceAll('-', '_');
    environment['CARGO_TARGET_${cargoTriple}_LINKER'] = compiler.toFilePath();
    // Align ELF load segments to 16 KB so the library loads on devices with
    // 16 KB memory pages (Android 15+; required on Pixel 8 and newer, and
    // for Play uploads). The Rust/NDK default is 4 KB, which the loader
    // rejects on those devices ("ELF alignment check failed").
    environment['CARGO_TARGET_${cargoTriple}_RUSTFLAGS'] =
        '-Clink-arg=--target=${_androidClangTarget(triple)}$api '
        '-Clink-arg=-Wl,-z,max-page-size=16384';
    // TODO(android-cc-crate): wgpu and its dependencies are pure Rust
    // today, so only the final link needs the NDK. If a dependency ever
    // pulls in a C build (a build.rs using the cc crate), also set
    // CC_$triple / AR_$triple / CXX_$triple to the NDK clang / llvm-ar so
    // those compile steps target Android too.
  }

  return environment;
}

// The clang `--target` ABI string for an Android Rust triple. It matches
// the Rust triple except for 32-bit ARM, where clang spells it
// `armv7a-linux-androideabi`.
String _androidClangTarget(String rustTriple) {
  if (rustTriple == 'armv7-linux-androideabi') {
    return 'armv7a-linux-androideabi';
  }
  return rustTriple;
}

// Maps the target (OS, architecture, and for iOS the device/simulator
// SDK) to its Rust target triple, or null when the combination is not
// supported.
String? _rustTriple(CodeConfig code) {
  final arch = code.targetArchitecture;
  if (code.targetOS == OS.macOS) {
    if (arch == Architecture.arm64) return 'aarch64-apple-darwin';
    if (arch == Architecture.x64) return 'x86_64-apple-darwin';
  }
  if (code.targetOS == OS.iOS) {
    if (code.iOS.targetSdk == IOSSdk.iPhoneOS) {
      // Devices are always arm64.
      return 'aarch64-apple-ios';
    }
    // Simulator.
    if (arch == Architecture.arm64) return 'aarch64-apple-ios-sim';
    if (arch == Architecture.x64) return 'x86_64-apple-ios';
  }
  if (code.targetOS == OS.android) {
    if (arch == Architecture.arm64) return 'aarch64-linux-android';
    if (arch == Architecture.arm) return 'armv7-linux-androideabi';
    if (arch == Architecture.x64) return 'x86_64-linux-android';
    if (arch == Architecture.ia32) return 'i686-linux-android';
  }
  if (code.targetOS == OS.linux) {
    if (arch == Architecture.x64) return 'x86_64-unknown-linux-gnu';
    if (arch == Architecture.arm64) return 'aarch64-unknown-linux-gnu';
  }
  if (code.targetOS == OS.windows) {
    if (arch == Architecture.x64) return 'x86_64-pc-windows-msvc';
    if (arch == Architecture.arm64) return 'aarch64-pc-windows-msvc';
  }
  return null;
}
