//! Draws a registry texture into a presenter target with one fullscreen
//! triangle, scaling to the target size and converting the colour format.
//!
//! An sRGB or float source samples as linear light and is sRGB-encoded for
//! a non-sRGB target; an 8-bit UNorm source holds display-encoded values
//! and is copied as stored (decoded for an sRGB target).

use std::collections::HashMap;

const SHADER: &str = r#"
override MODE: u32 = 0u;

@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var smp: sampler;

struct VOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs(@builtin(vertex_index) v: u32) -> VOut {
    let x = f32((v << 1u) & 2u) * 2.0 - 1.0;
    let y = f32(v & 2u) * 2.0 - 1.0;
    var o: VOut;
    o.pos = vec4<f32>(x, y, 0.0, 1.0);
    o.uv = vec2<f32>(x * 0.5 + 0.5, 0.5 - y * 0.5);
    return o;
}

fn encode(c: vec3<f32>) -> vec3<f32> {
    let c1 = clamp(c, vec3<f32>(0.0), vec3<f32>(1.0));
    return select(1.055 * pow(c1, vec3<f32>(1.0 / 2.4)) - 0.055, c1 * 12.92, c1 <= vec3<f32>(0.0031308));
}

fn decode(c: vec3<f32>) -> vec3<f32> {
    return select(pow((c + 0.055) / 1.055, vec3<f32>(2.4)), c / 12.92, c <= vec3<f32>(0.04045));
}

@fragment
fn fs(i: VOut) -> @location(0) vec4<f32> {
    let c = textureSample(src, smp, i.uv);
    if (MODE == 1u) { return vec4<f32>(encode(c.rgb), c.a); }
    if (MODE == 2u) { return vec4<f32>(decode(c.rgb), c.a); }
    return c;
}
"#;

const PASS: u32 = 0;
const ENCODE: u32 = 1;
const DECODE: u32 = 2;

pub struct Blitter {
    module: wgpu::ShaderModule,
    layout: wgpu::BindGroupLayout,
    pipeline_layout: wgpu::PipelineLayout,
    sampler: wgpu::Sampler,
    pipelines: HashMap<(wgpu::TextureFormat, u32), wgpu::RenderPipeline>,
    // A sampleable copy for a source created without shader-read usage.
    staging: Option<wgpu::Texture>,
}

fn is_linear(format: wgpu::TextureFormat) -> bool {
    use wgpu::TextureFormat as F;
    format.is_srgb() || matches!(format, F::Rgba16Float | F::Rgba32Float | F::R32Float | F::R16Float | F::Rg16Float | F::Rg11b10Ufloat)
}

impl Blitter {
    pub fn new(device: &wgpu::Device) -> Blitter {
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("present blit"),
            source: wgpu::ShaderSource::Wgsl(SHADER.into()),
        });
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("present blit"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("present blit"),
            bind_group_layouts: &[Some(&layout)],
            immediate_size: 0,
        });
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("present blit"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });
        Blitter {
            module,
            layout,
            pipeline_layout,
            sampler,
            pipelines: HashMap::new(),
            staging: None,
        }
    }

    fn pipeline(&mut self, device: &wgpu::Device, target: wgpu::TextureFormat, mode: u32) -> &wgpu::RenderPipeline {
        let (module, layout) = (&self.module, &self.pipeline_layout);
        self.pipelines.entry((target, mode)).or_insert_with(|| {
            let constants = [("MODE", mode as f64)];
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("present blit"),
                layout: Some(layout),
                vertex: wgpu::VertexState {
                    module,
                    entry_point: Some("vs"),
                    compilation_options: Default::default(),
                    buffers: &[],
                },
                fragment: Some(wgpu::FragmentState {
                    module,
                    entry_point: Some("fs"),
                    compilation_options: wgpu::PipelineCompilationOptions {
                        constants: &constants,
                        ..Default::default()
                    },
                    targets: &[Some(wgpu::ColorTargetState {
                        format: target,
                        blend: None,
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                }),
                primitive: Default::default(),
                depth_stencil: None,
                multisample: Default::default(),
                multiview_mask: None,
                cache: None,
            })
        })
    }

    /// Records `source` drawn over all of `target` (a `target_format` view).
    pub fn encode(
        &mut self,
        device: &wgpu::Device,
        source: &wgpu::Texture,
        target: &wgpu::TextureView,
        target_format: wgpu::TextureFormat,
    ) -> Result<wgpu::CommandBuffer, String> {
        let format = source.format();
        if source.sample_count() != 1 {
            return Err("a multisampled texture cannot be presented; present its resolve texture".into());
        }
        if source.dimension() != wgpu::TextureDimension::D2 || source.depth_or_array_layers() != 1 {
            return Err("only a 2D texture can be presented".into());
        }
        if format.is_depth_stencil_format()
            || !matches!(
                format.sample_type(None, Some(device.features())),
                Some(wgpu::TextureSampleType::Float { filterable: true })
            )
        {
            return Err(format!("a {format:?} texture cannot be presented; it is not a filterable colour format"));
        }
        let mode = match (is_linear(format), target_format.is_srgb()) {
            (true, false) => ENCODE,
            (false, true) => DECODE,
            _ => PASS,
        };

        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("present texture"),
        });
        let sampled = if source.usage().contains(wgpu::TextureUsages::TEXTURE_BINDING) {
            source.clone()
        } else {
            if !source.usage().contains(wgpu::TextureUsages::COPY_SRC) {
                return Err("the texture can neither be sampled nor copied".into());
            }
            let size = source.size();
            let fits = matches!(&self.staging, Some(t) if t.format() == format && t.size() == size);
            if !fits {
                self.staging = Some(device.create_texture(&wgpu::TextureDescriptor {
                    label: Some("present staging"),
                    size,
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension: wgpu::TextureDimension::D2,
                    format,
                    usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                    view_formats: &[],
                }));
            }
            let staging = self.staging.clone().unwrap();
            encoder.copy_texture_to_texture(source.as_image_copy(), staging.as_image_copy(), size);
            staging
        };
        let view = sampled.create_view(&wgpu::TextureViewDescriptor {
            base_mip_level: 0,
            mip_level_count: Some(1),
            ..Default::default()
        });
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("present blit"),
            layout: &self.layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&view),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Sampler(&self.sampler),
                },
            ],
        });
        let pipeline = self.pipeline(device, target_format, mode).clone();
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("present texture"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: target,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            pass.set_pipeline(&pipeline);
            pass.set_bind_group(0, &bind_group, &[]);
            pass.draw(0..3, 0..1);
        }
        Ok(encoder.finish())
    }
}
