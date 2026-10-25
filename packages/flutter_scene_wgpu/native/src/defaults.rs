//! Placeholder resources for bind group slots a draw leaves unbound.
//!
//! flutter_gpu lets a draw skip a uniform or texture the shader declares;
//! Metal and Vulkan read zeros there. wgpu needs every layout entry filled,
//! so the decoder fills the gaps with a zeroed buffer, a 1×1 zeroed texture
//! of the slot's shape, or a nearest sampler, made once per device.

use std::collections::HashMap;
use std::sync::Mutex;

/// Bytes in the zeroed placeholder buffer: the largest uniform block a
/// draw may read from it.
const BUFFER_SIZE: u64 = 64 * 1024;

#[derive(Default)]
pub struct Defaults {
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    buffer: Option<wgpu::Buffer>,
    textures: HashMap<(u8, wgpu::TextureViewDimension, bool), wgpu::TextureView>,
    sampler: Option<wgpu::Sampler>,
    comparison: Option<wgpu::Sampler>,
}

impl Defaults {
    pub fn buffer(&self, device: &wgpu::Device) -> wgpu::Buffer {
        let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        inner
            .buffer
            .get_or_insert_with(|| {
                device.create_buffer(&wgpu::BufferDescriptor {
                    label: Some("flutter_scene_wgpu zero buffer"),
                    size: BUFFER_SIZE,
                    usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::STORAGE,
                    mapped_at_creation: false,
                })
            })
            .clone()
    }

    pub fn sampler(&self, device: &wgpu::Device, comparison: bool) -> wgpu::Sampler {
        let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        let slot = if comparison {
            &mut inner.comparison
        } else {
            &mut inner.sampler
        };
        slot.get_or_insert_with(|| {
            device.create_sampler(&wgpu::SamplerDescriptor {
                compare: comparison.then_some(wgpu::CompareFunction::LessEqual),
                ..Default::default()
            })
        })
        .clone()
    }

    pub fn texture(
        &self,
        device: &wgpu::Device,
        sample_type: wgpu::TextureSampleType,
        view_dimension: wgpu::TextureViewDimension,
        multisampled: bool,
    ) -> wgpu::TextureView {
        let (code, format) = match sample_type {
            wgpu::TextureSampleType::Float { .. } => (0, wgpu::TextureFormat::Rgba8Unorm),
            wgpu::TextureSampleType::Depth => (1, wgpu::TextureFormat::Depth32Float),
            wgpu::TextureSampleType::Sint => (2, wgpu::TextureFormat::R32Sint),
            wgpu::TextureSampleType::Uint => (3, wgpu::TextureFormat::R32Uint),
        };
        let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        inner
            .textures
            .entry((code, view_dimension, multisampled))
            .or_insert_with(|| {
                let (dimension, layers) = match view_dimension {
                    wgpu::TextureViewDimension::Cube | wgpu::TextureViewDimension::CubeArray => {
                        (wgpu::TextureDimension::D2, 6)
                    }
                    wgpu::TextureViewDimension::D3 => (wgpu::TextureDimension::D3, 1),
                    wgpu::TextureViewDimension::D1 => (wgpu::TextureDimension::D1, 1),
                    _ => (wgpu::TextureDimension::D2, 1),
                };
                let mut usage = wgpu::TextureUsages::TEXTURE_BINDING;
                if multisampled {
                    usage |= wgpu::TextureUsages::RENDER_ATTACHMENT;
                }
                let texture = device.create_texture(&wgpu::TextureDescriptor {
                    label: Some("flutter_scene_wgpu placeholder texture"),
                    size: wgpu::Extent3d {
                        width: 1,
                        height: 1,
                        depth_or_array_layers: layers,
                    },
                    mip_level_count: 1,
                    sample_count: if multisampled { 4 } else { 1 },
                    dimension,
                    format,
                    usage,
                    view_formats: &[],
                });
                texture.create_view(&wgpu::TextureViewDescriptor {
                    dimension: Some(view_dimension),
                    ..Default::default()
                })
            })
            .clone()
    }
}
