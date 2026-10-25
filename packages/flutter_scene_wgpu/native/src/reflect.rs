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
    Sampler { comparison: bool, filtering: bool },
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
                    filtering: true,
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
            ResourceKind::Sampler { comparison, filtering } => {
                wgpu::BindingType::Sampler(if comparison {
                    wgpu::SamplerBindingType::Comparison
                } else if filtering {
                    wgpu::SamplerBindingType::Filtering
                } else {
                    wgpu::SamplerBindingType::NonFiltering
                })
            }
        }
    }
}

impl ResourceKind {
    /// This kind with a texture's sample type or a sampler's binding type
    /// replaced by [code]: textures take 0 filterable float, 1 unfilterable
    /// float, 2 depth, 3 sint, 4 uint; samplers take 16 filtering, 17
    /// non-filtering, 18 comparison.
    ///
    /// Only a float texture and a non-comparison sampler change: a depth or
    /// integer texture, or a comparison sampler, is already what the shader
    /// declares it to be.
    pub fn overridden(self, code: u32) -> Result<Self> {
        Ok(match (self, code) {
            (
                ResourceKind::Texture {
                    sample_type:
                        wgpu::TextureSampleType::Depth
                        | wgpu::TextureSampleType::Sint
                        | wgpu::TextureSampleType::Uint,
                    ..
                },
                0..=4,
            )
            | (ResourceKind::Sampler { comparison: true, .. }, 16..=18) => self,
            (ResourceKind::Texture { view_dimension, multisampled, .. }, 0..=4) => ResourceKind::Texture {
                sample_type: match code {
                    0 => wgpu::TextureSampleType::Float { filterable: true },
                    1 => wgpu::TextureSampleType::Float { filterable: false },
                    2 => wgpu::TextureSampleType::Depth,
                    3 => wgpu::TextureSampleType::Sint,
                    _ => wgpu::TextureSampleType::Uint,
                },
                view_dimension,
                multisampled,
            },
            (ResourceKind::Sampler { .. }, 16..=18) => ResourceKind::Sampler {
                comparison: code == 18,
                filtering: code == 16,
            },
            _ => return Err(crate::error::invalid(format!(
                "binding override {code} does not fit a {self:?} binding"
            ))),
        })
    }
}
