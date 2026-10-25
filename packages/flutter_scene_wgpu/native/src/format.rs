//! Maps the ordinals of flutter_gpu's enums (formats.dart, vertex_layout.dart)
//! onto wgpu types. Every enum crosses the ABI as its flutter_gpu index.

use crate::error::{invalid, unsupported, Result};
use wgpu::{AstcBlock, AstcChannel, TextureFormat as F};

pub fn pixel_format(v: u32) -> Result<F> {
    let astc = |block, channel| F::Astc { block, channel };
    Ok(match v {
        // a8UNormInt has no wgpu counterpart; R8Unorm holds the same bits.
        1 | 2 => F::R8Unorm,
        3 => F::Rg8Unorm,
        4 => F::Rgba8Unorm,
        5 => F::Rgba8UnormSrgb,
        6 => F::Bgra8Unorm,
        7 => F::Bgra8UnormSrgb,
        8 => F::Rgba32Float,
        9 => F::Rgba16Float,
        10 => F::R32Float,
        11 => F::Stencil8,
        12 => F::Depth24PlusStencil8,
        13 => F::Depth32FloatStencil8,
        14 => F::Bc1RgbaUnorm,
        15 => F::Bc1RgbaUnormSrgb,
        16 => F::Bc3RgbaUnorm,
        17 => F::Bc3RgbaUnormSrgb,
        18 => F::Bc5RgUnorm,
        19 => F::Bc7RgbaUnorm,
        20 => F::Bc7RgbaUnormSrgb,
        21 => F::Etc2Rgb8Unorm,
        22 => F::Etc2Rgb8UnormSrgb,
        23 => F::Etc2Rgba8Unorm,
        24 => F::Etc2Rgba8UnormSrgb,
        25 => astc(AstcBlock::B4x4, AstcChannel::Unorm),
        26 => astc(AstcBlock::B4x4, AstcChannel::UnormSrgb),
        27 => astc(AstcBlock::B8x8, AstcChannel::Unorm),
        28 => astc(AstcBlock::B8x8, AstcChannel::UnormSrgb),
        29 => astc(AstcBlock::B4x4, AstcChannel::Hdr),
        30 => astc(AstcBlock::B8x8, AstcChannel::Hdr),
        // Depth32Float is not in flutter_gpu's list; 31 exposes it for depth-only targets.
        31 => F::Depth32Float,
        _ => return Err(invalid(format!("unknown pixel format {v}"))),
    })
}

pub fn blend_factor(v: u32) -> Result<wgpu::BlendFactor> {
    use wgpu::BlendFactor::*;
    Ok(match v {
        0 => Zero,
        1 => One,
        2 => Src,
        3 => OneMinusSrc,
        4 => SrcAlpha,
        5 => OneMinusSrcAlpha,
        6 => Dst,
        7 => OneMinusDst,
        8 => DstAlpha,
        9 => OneMinusDstAlpha,
        10 => SrcAlphaSaturated,
        // wgpu has one blend constant for colour and alpha.
        11 | 13 => Constant,
        12 | 14 => OneMinusConstant,
        _ => return Err(invalid(format!("unknown blend factor {v}"))),
    })
}

pub fn blend_op(v: u32) -> Result<wgpu::BlendOperation> {
    use wgpu::BlendOperation::*;
    Ok(match v {
        0 => Add,
        1 => Subtract,
        2 => ReverseSubtract,
        _ => return Err(invalid(format!("unknown blend operation {v}"))),
    })
}

pub fn compare(v: u32) -> Result<wgpu::CompareFunction> {
    use wgpu::CompareFunction::*;
    Ok(match v {
        0 => Never,
        1 => Always,
        2 => Less,
        3 => Equal,
        4 => LessEqual,
        5 => Greater,
        6 => NotEqual,
        7 => GreaterEqual,
        _ => return Err(invalid(format!("unknown compare function {v}"))),
    })
}

pub fn stencil_op(v: u32) -> Result<wgpu::StencilOperation> {
    use wgpu::StencilOperation::*;
    Ok(match v {
        0 => Keep,
        1 => Zero,
        2 => Replace,
        3 => IncrementClamp,
        4 => DecrementClamp,
        5 => Invert,
        6 => IncrementWrap,
        7 => DecrementWrap,
        _ => return Err(invalid(format!("unknown stencil operation {v}"))),
    })
}

pub fn primitive(v: u32) -> Result<wgpu::PrimitiveTopology> {
    use wgpu::PrimitiveTopology::*;
    Ok(match v {
        0 => TriangleList,
        1 => TriangleStrip,
        2 => LineList,
        3 => LineStrip,
        4 => PointList,
        _ => return Err(invalid(format!("unknown primitive type {v}"))),
    })
}

pub fn cull(v: u32) -> Result<Option<wgpu::Face>> {
    Ok(match v {
        0 => None,
        1 => Some(wgpu::Face::Front),
        2 => Some(wgpu::Face::Back),
        _ => return Err(invalid(format!("unknown cull mode {v}"))),
    })
}

pub fn winding(v: u32) -> Result<wgpu::FrontFace> {
    Ok(match v {
        0 => wgpu::FrontFace::Cw,
        1 => wgpu::FrontFace::Ccw,
        _ => return Err(invalid(format!("unknown winding order {v}"))),
    })
}

pub fn polygon(v: u32) -> Result<wgpu::PolygonMode> {
    Ok(match v {
        0 => wgpu::PolygonMode::Fill,
        1 => wgpu::PolygonMode::Line,
        _ => return Err(invalid(format!("unknown polygon mode {v}"))),
    })
}

pub fn vertex_format(v: u32) -> Result<wgpu::VertexFormat> {
    use wgpu::VertexFormat::*;
    Ok(match v {
        0 => Float32,
        1 => Float32x2,
        2 => Float32x3,
        3 => Float32x4,
        4 => Uint32,
        5 => Uint32x2,
        6 => Uint32x3,
        7 => Uint32x4,
        8 => Sint32,
        9 => Sint32x2,
        10 => Sint32x3,
        11 => Sint32x4,
        _ => return Err(invalid(format!("unknown vertex format {v}"))),
    })
}

pub fn step_mode(v: u32) -> Result<wgpu::VertexStepMode> {
    Ok(match v {
        0 => wgpu::VertexStepMode::Vertex,
        1 => wgpu::VertexStepMode::Instance,
        _ => return Err(invalid(format!("unknown vertex step mode {v}"))),
    })
}

pub fn index_format(v: u32) -> Result<wgpu::IndexFormat> {
    Ok(match v {
        0 => wgpu::IndexFormat::Uint16,
        1 => wgpu::IndexFormat::Uint32,
        _ => return Err(invalid(format!("unknown index type {v}"))),
    })
}

pub fn filter(v: u32) -> Result<wgpu::FilterMode> {
    Ok(match v {
        0 => wgpu::FilterMode::Nearest,
        1 => wgpu::FilterMode::Linear,
        _ => return Err(invalid(format!("unknown filter {v}"))),
    })
}

pub fn mip_filter(v: u32) -> Result<wgpu::MipmapFilterMode> {
    Ok(match v {
        0 => wgpu::MipmapFilterMode::Nearest,
        1 => wgpu::MipmapFilterMode::Linear,
        _ => return Err(invalid(format!("unknown mip filter {v}"))),
    })
}

pub fn address(v: u32) -> Result<wgpu::AddressMode> {
    Ok(match v {
        0 => wgpu::AddressMode::ClampToEdge,
        1 => wgpu::AddressMode::Repeat,
        2 => wgpu::AddressMode::MirrorRepeat,
        _ => return Err(invalid(format!("unknown address mode {v}"))),
    })
}

/// flutter_gpu's LoadAction: dontCare, load, clear. `dontCare` clears, the
/// only safe wgpu equivalent.
pub fn load<V>(v: u32, clear: V) -> Result<wgpu::LoadOp<V>> {
    Ok(match v {
        0 | 2 => wgpu::LoadOp::Clear(clear),
        1 => wgpu::LoadOp::Load,
        _ => return Err(invalid(format!("unknown load action {v}"))),
    })
}

/// flutter_gpu's StoreAction: dontCare, store, multisampleResolve,
/// storeAndMultisampleResolve. Returns the store op and whether it resolves.
pub fn store(v: u32) -> Result<(wgpu::StoreOp, bool)> {
    Ok(match v {
        0 => (wgpu::StoreOp::Discard, false),
        1 => (wgpu::StoreOp::Store, false),
        2 => (wgpu::StoreOp::Discard, true),
        3 => (wgpu::StoreOp::Store, true),
        _ => return Err(invalid(format!("unknown store action {v}"))),
    })
}

/// flutter_gpu's TextureType: texture2D, texture2DMultisample, textureCube,
/// textureExternalOES.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextureKind {
    D2,
    D2Multisample,
    Cube,
}

pub fn texture_kind(v: u32) -> Result<TextureKind> {
    Ok(match v {
        0 => TextureKind::D2,
        1 => TextureKind::D2Multisample,
        2 => TextureKind::Cube,
        3 => return Err(unsupported("textureExternalOES has no wgpu counterpart")),
        _ => return Err(invalid(format!("unknown texture type {v}"))),
    })
}

pub fn backend_code(b: wgpu::Backend) -> u32 {
    match b {
        wgpu::Backend::Noop => 0,
        wgpu::Backend::Vulkan => 1,
        wgpu::Backend::Metal => 2,
        wgpu::Backend::Dx12 => 3,
        wgpu::Backend::Gl => 4,
        wgpu::Backend::BrowserWebGpu => 5,
    }
}
