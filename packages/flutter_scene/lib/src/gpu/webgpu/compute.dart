part of 'webgpu_backend.dart';

/// What a compute bind group entry takes, as its WGSL declaration states.
enum _ComputeKind { buffer, texture, storageTexture, sampler }

/// One entry of a compute bind group layout.
typedef _ComputeEntry = ({int binding, _ComputeKind kind, String? dimension});

/// The layout of one bind group of a [_WebGpuComputePipeline].
typedef _ComputeGroup = ({
  GPUBindGroupLayout layout,
  List<_ComputeEntry> entries,
});

/// A compute pipeline over one entry point of a WGSL module, with explicit
/// bind group layouts built from every resource the module declares, as the
/// native wgpu backend builds them. A dispatch therefore binds the same
/// resources whichever entry point of the module it runs.
final class _WebGpuComputePipeline extends ComputePipeline {
  _WebGpuComputePipeline(_WebGpuContext context, String source, String entry) {
    final device = context.device.device;
    final byGroup = <int, Map<int, WgslDeclaration>>{};
    for (final d in parseWgslDeclarations(source)) {
      (byGroup[d.group] ??= {})[d.binding] = d;
    }
    final groupCount = byGroup.isEmpty
        ? 0
        : byGroup.keys.reduce((a, b) => a > b ? a : b) + 1;
    groups = [
      for (var g = 0; g < groupCount; g++) _group(device, byGroup[g] ?? {}),
    ];
    pipeline = device.createComputePipeline(
      _obj({
        'layout': device.createPipelineLayout(
          _obj({
            'bindGroupLayouts': [for (final g in groups) g.layout],
          }),
        ),
        'compute': {
          'module': device.createShaderModule(_obj({'code': source})),
          if (entry.isNotEmpty) 'entryPoint': entry,
        },
      }),
    );
  }

  late final GPUComputePipeline pipeline;
  late final List<_ComputeGroup> groups;

  static _ComputeGroup _group(
    GPUDevice device,
    Map<int, WgslDeclaration> declared,
  ) {
    final bindings = declared.keys.toList()..sort();
    final layouts = <Map<String, Object?>>[];
    final entries = <_ComputeEntry>[];
    for (final binding in bindings) {
      final (layout, entry) = _entry(declared[binding]!);
      layouts.add({
        'binding': binding,
        'visibility': GPUShaderStage.compute,
        ...layout,
      });
      entries.add(entry);
    }
    return (
      layout: device.createBindGroupLayout(_obj({'entries': layouts})),
      entries: entries,
    );
  }

  static (Map<String, Object?>, _ComputeEntry) _entry(WgslDeclaration d) {
    final space = d.addressSpace.replaceAll(' ', '');
    final type = d.type.replaceAll(' ', '');
    if (space.startsWith('uniform') || space.startsWith('storage')) {
      final buffer = space.startsWith('uniform')
          ? 'uniform'
          : space.endsWith(',read_write')
          ? 'storage'
          : 'read-only-storage';
      return (
        {
          'buffer': {'type': buffer},
        },
        (binding: d.binding, kind: _ComputeKind.buffer, dimension: null),
      );
    }
    if (d.kind == WgslDeclarationKind.sampler) {
      return (
        {
          'sampler': {
            'type': type == 'sampler_comparison'
                ? 'comparison'
                : 'non-filtering',
          },
        },
        (binding: d.binding, kind: _ComputeKind.sampler, dimension: null),
      );
    }
    final dimension = _dimensionOf(type);
    final arguments = type.contains('<')
        ? type
              .substring(type.indexOf('<') + 1, type.lastIndexOf('>'))
              .split(',')
        : const <String>[];
    if (type.startsWith('texture_storage_')) {
      return (
        {
          'storageTexture': {
            'format': arguments[0],
            'access': switch (arguments[1]) {
              'read' => 'read-only',
              'read_write' => 'read-write',
              _ => 'write-only',
            },
            'viewDimension': dimension,
          },
        },
        (
          binding: d.binding,
          kind: _ComputeKind.storageTexture,
          dimension: dimension,
        ),
      );
    }
    return (
      {
        'texture': {
          'sampleType': type.startsWith('texture_depth_')
              ? 'depth'
              : switch (arguments.firstOrNull) {
                  'u32' => 'uint',
                  'i32' => 'sint',
                  _ => 'unfilterable-float',
                },
          'viewDimension': dimension,
          'multisampled': type.contains('multisampled'),
        },
      },
      (binding: d.binding, kind: _ComputeKind.texture, dimension: dimension),
    );
  }

  /// The view dimension a WGSL texture type such as `texture_2d_array<f32>`
  /// or `texture_storage_3d<r32float, write>` takes.
  static String _dimensionOf(String type) {
    final end = type.indexOf('<');
    final name = end < 0 ? type : type.substring(0, end);
    final shape = name
        .replaceFirst('texture_', '')
        .replaceFirst('storage_', '')
        .replaceFirst('depth_', '')
        .replaceFirst('multisampled_', '');
    return shape.replaceAll('_', '-');
  }
}

/// A resource bound to a compute pass slot.
sealed class _ComputeBound {}

final class _BoundBuffer extends _ComputeBound {
  _BoundBuffer(this.buffer, this.offset, this.length);

  final _WebGpuDeviceBuffer buffer;
  final int offset;
  final int length;
}

final class _BoundTextureView extends _ComputeBound {
  _BoundTextureView(this.texture, {this.storageMip});

  final _WebGpuTexture texture;

  /// The mip level bound as a storage texture, or null for a sampled one.
  final int? storageMip;
}

/// A `GPUComputePassEncoder` that binds by group and binding, and builds
/// each bind group the next dispatch needs from what is bound.
final class _WebGpuComputePass extends ComputePass {
  _WebGpuComputePass(this._context, GPUCommandEncoder encoder)
    : _encoder = encoder.beginComputePass();

  final _WebGpuContext _context;
  final GPUComputePassEncoder _encoder;
  final Map<(int, int), _ComputeBound> _bound = {};
  _WebGpuComputePipeline? _pipeline;
  bool _dirty = true;
  bool _ended = false;

  void _end() {
    if (_ended) return;
    _ended = true;
    _encoder.end();
  }

  void _checkOpen() {
    if (_ended) {
      throw StateError(
        'This compute pass has ended; a command buffer ends a pass when it '
        'starts the next one or is submitted.',
      );
    }
  }

  @override
  void bindPipeline(ComputePipeline pipeline) {
    _checkOpen();
    final compute = pipeline as _WebGpuComputePipeline;
    _encoder.setPipeline(compute.pipeline);
    _pipeline = compute;
    _dirty = true;
  }

  @override
  void bindBuffer(int group, int binding, BufferView view) {
    _bound[(group, binding)] = _BoundBuffer(
      view.buffer as _WebGpuDeviceBuffer,
      view.offsetInBytes,
      view.lengthInBytes,
    );
    _dirty = true;
  }

  @override
  void bindTexture(int group, int binding, Texture texture) {
    _bound[(group, binding)] = _BoundTextureView(texture as _WebGpuTexture);
    _dirty = true;
  }

  @override
  void bindStorageTexture(
    int group,
    int binding,
    Texture texture, {
    int mipLevel = 0,
  }) {
    _bound[(group, binding)] = _BoundTextureView(
      texture as _WebGpuTexture,
      storageMip: mipLevel,
    );
    _dirty = true;
  }

  @override
  void dispatch(int x, [int y = 1, int z = 1]) {
    _flush();
    _encoder.dispatchWorkgroups(x, y, z);
  }

  @override
  void dispatchIndirect(BufferView arguments) {
    _flush();
    _encoder.dispatchWorkgroupsIndirect(
      (arguments.buffer as _WebGpuDeviceBuffer).buffer,
      arguments.offsetInBytes,
    );
  }

  /// Sets the bind groups of the bound pipeline. A slot bound to nothing,
  /// or to a resource of another kind, takes a placeholder, as on the native
  /// wgpu backend.
  void _flush() {
    _checkOpen();
    final pipeline =
        _pipeline ?? (throw StateError('dispatch called before bindPipeline'));
    if (!_dirty) return;
    final device = _context.device.device;
    for (final (index, group) in pipeline.groups.indexed) {
      final entries = [
        for (final entry in group.entries)
          {
            'binding': entry.binding,
            'resource': _resource(entry, _bound[(index, entry.binding)]),
          },
      ];
      _encoder.setBindGroup(
        index,
        device.createBindGroup(
          _obj({'layout': group.layout, 'entries': entries}),
        ),
      );
    }
    _dirty = false;
  }

  Object _resource(_ComputeEntry entry, _ComputeBound? bound) {
    switch ((entry.kind, bound)) {
      case (
        _ComputeKind.buffer,
        _BoundBuffer(:final buffer, :final offset, :final length),
      ):
        return {'buffer': buffer.buffer, 'offset': offset, 'size': length};
      case (_ComputeKind.buffer, _):
        return {'buffer': _context.computePlaceholderBuffer.buffer};
      case (
        _ComputeKind.texture,
        _BoundTextureView(:final texture, storageMip: null),
      ):
        return texture.sampledView;
      case (_ComputeKind.texture, _):
        return _context.blankTexture(entry.dimension!).sampledView;
      case (
        _ComputeKind.storageTexture,
        _BoundTextureView(:final texture, :final storageMip?),
      ):
        return texture.attachmentView(storageMip, 0);
      case (_ComputeKind.storageTexture, _):
        throw StateError(
          'A dispatch has no storage texture bound at binding '
          '${entry.binding}; bind one with bindStorageTexture.',
        );
      case (_ComputeKind.sampler, _):
        return _context.samplers.get(_nearest, nonFiltering: true);
    }
  }

  static final SamplerOptions _nearest = SamplerOptions();
}
