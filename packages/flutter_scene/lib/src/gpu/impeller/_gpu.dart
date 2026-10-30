/// The native GPU shim: flutter_gpu's API over the backend chosen at start-up,
/// Flutter GPU (Impeller) by default or a backend the app registers (see
/// [registerGpuBackend] and [selectGpuBackend]).
///
/// The resource classes are final wrappers that hold either a flutter_gpu
/// object, which each member calls directly, or an object of the registered
/// backend's contract (`package:flutter_scene/gpu_backend.dart`), which each
/// member calls through its interface. Enums and the value types that hold no
/// resource are flutter_gpu's own.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as fg;
import 'package:flutter_gpu/gpu.dart'
    show
        CompletionCallback,
        CompareFunction,
        ColorBlendEquation,
        CullMode,
        GpuPresentStatus,
        IndexType,
        LoadAction,
        PixelFormat,
        PolygonMode,
        PrimitiveType,
        SamplerOptions,
        Scissor,
        ShaderStage,
        StencilConfig,
        StencilFace,
        StorageMode,
        StoreAction,
        TextureCompressionFamily,
        TextureType,
        VertexLayout,
        Viewport,
        WindingOrder;
import 'package:flutter_scene/src/gpu/shared/encoded_image_types.dart';
import 'package:flutter_scene/src/gpu/shared/shader_library_sources.dart';
import 'package:meta/meta.dart' show experimental;
import 'package:vector_math/vector_math.dart' as vm;

import '../shared/gpu_capabilities.dart';
import '../shared/gpu_labels.dart';
import '../shared/item_instances.dart';
import '../shared/item_sort.dart';
import '../backend/gpu_backend.dart';

export 'package:flutter_gpu/gpu.dart'
    show
        BlendFactor,
        BlendOperation,
        ColorBlendEquation,
        CompareFunction,
        CompletionCallback,
        CullMode,
        DepthRange,
        GpuPresentStatus,
        IndexType,
        LoadAction,
        MinMagFilter,
        MipFilter,
        PixelFormat,
        PixelFormatProperties,
        PolygonMode,
        PrimitiveType,
        SamplerAddressMode,
        SamplerOptions,
        Scissor,
        ShaderStage,
        StencilConfig,
        StencilFace,
        StencilOperation,
        StorageMode,
        StoreAction,
        TextureCompressionFamily,
        TextureType,
        VertexAttribute,
        VertexBuffer,
        VertexFormat,
        VertexLayout,
        VertexStepMode,
        Viewport,
        WindingOrder;

part 'backend_selection.dart';
part 'buffer.dart';
part 'command_buffer.dart';
part 'compute.dart';
part 'context.dart';
part 'encoded_image.dart';
part 'host.dart';
part 'image_surface.dart';
part 'item_set.dart';
part 'item_set_impeller.dart';
part 'present.dart';
part 'render_pass.dart';
part 'shader.dart';
part 'shader_library_inline.dart';
part 'shader_names.dart';
part 'surface.dart';
part 'texture.dart';
