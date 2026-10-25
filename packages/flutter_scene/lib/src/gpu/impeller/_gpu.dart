/// The native GPU shim: flutter_gpu's API over the backend chosen at start-up,
/// Flutter GPU (Impeller) by default or wgpu (see [selectGpuBackend]).
///
/// The resource classes are final wrappers that hold either a flutter_gpu
/// object or a wgpu handle, and forward each member to it with a direct call.
/// Enums and the value types that hold no resource are flutter_gpu's own.
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
import 'package:vector_math/vector_math.dart' as vm;

import '../shared/gpu_capabilities.dart';
import '../wgpu/wgpu_device.dart';

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
part 'context.dart';
part 'encoded_image.dart';
part 'host.dart';
part 'image_surface.dart';
part 'present.dart';
part 'render_pass.dart';
part 'shader.dart';
part 'shader_library_inline.dart';
part 'shader_names.dart';
part 'surface.dart';
part 'texture.dart';
