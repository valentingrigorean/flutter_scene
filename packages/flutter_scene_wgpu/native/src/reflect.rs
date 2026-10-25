//! Reads the resource bindings a shader module declares, so a pipeline can
//! build explicit bind group layouts and the command stream can fill them
//! by (group, binding) slot.

use wgpu::naga;

use crate::error::{unsupported, Result};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResourceKind {
    UniformBuffer,
    StorageBuffer { read_only: bool },
    Texture {
        sample_type: wgpu::TextureSampleType,
        view_dimension: wgpu::TextureViewDimension,
        multisampled: bool,
    },
    Sampler { comparison: bool },
}

#[derive(Clone, Copy, Debug)]
pub struct Resource {
    pub group: u32,
    pub binding: u32,
    pub kind: ResourceKind,
}

pub fn resources(module: &naga::Module) -> Result<Vec<Resource>> {
    let mut out = Vec::new();
    for (_, var) in module.global_variables.iter() {
        let Some(binding) = &var.binding else { continue };
        let kind = match var.space {
            naga::AddressSpace::Uniform => ResourceKind::UniformBuffer,
            naga::AddressSpace::Storage { access } => ResourceKind::StorageBuffer {
                read_only: !access.contains(naga::StorageAccess::STORE),
            },
            naga::AddressSpace::Handle => match &module.types[var.ty].inner {
                naga::TypeInner::Sampler { comparison } => ResourceKind::Sampler {
                    comparison: *comparison,
                },
                naga::TypeInner::Image { dim, arrayed, class } => {
                    let view_dimension = match (dim, arrayed) {
                        (naga::ImageDimension::D2, false) => wgpu::TextureViewDimension::D2,
                        (naga::ImageDimension::D2, true) => wgpu::TextureViewDimension::D2Array,
                        (naga::ImageDimension::Cube, false) => wgpu::TextureViewDimension::Cube,
                        (naga::ImageDimension::Cube, true) => {
                            wgpu::TextureViewDimension::CubeArray
                        }
                        (naga::ImageDimension::D3, _) => wgpu::TextureViewDimension::D3,
                        (naga::ImageDimension::D1, _) => wgpu::TextureViewDimension::D1,
                    };
                    let (sample_type, multisampled) = match class {
                        naga::ImageClass::Sampled { kind, multi } => (
                            match kind {
                                naga::ScalarKind::Sint => wgpu::TextureSampleType::Sint,
                                naga::ScalarKind::Uint => wgpu::TextureSampleType::Uint,
                                _ => wgpu::TextureSampleType::Float { filterable: !multi },
                            },
                            *multi,
                        ),
                        naga::ImageClass::Depth { multi } => {
                            (wgpu::TextureSampleType::Depth, *multi)
                        }
                        _ => {
                            return Err(unsupported(format!(
                                "binding @group({}) @binding({}): storage and external \
                                 textures are not supported",
                                binding.group, binding.binding
                            )))
                        }
                    };
                    ResourceKind::Texture {
                        sample_type,
                        view_dimension,
                        multisampled,
                    }
                }
                _ => continue,
            },
            _ => continue,
        };
        out.push(Resource {
            group: binding.group,
            binding: binding.binding,
            kind,
        });
    }
    Ok(out)
}

impl ResourceKind {
    pub fn binding_type(self) -> wgpu::BindingType {
        match self {
            ResourceKind::UniformBuffer => wgpu::BindingType::Buffer {
                ty: wgpu::BufferBindingType::Uniform,
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            ResourceKind::StorageBuffer { read_only } => wgpu::BindingType::Buffer {
                ty: wgpu::BufferBindingType::Storage { read_only },
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            ResourceKind::Texture {
                sample_type,
                view_dimension,
                multisampled,
            } => wgpu::BindingType::Texture {
                sample_type,
                view_dimension,
                multisampled,
            },
            ResourceKind::Sampler { comparison } => wgpu::BindingType::Sampler(if comparison {
                wgpu::SamplerBindingType::Comparison
            } else {
                wgpu::SamplerBindingType::Filtering
            }),
        }
    }
}
