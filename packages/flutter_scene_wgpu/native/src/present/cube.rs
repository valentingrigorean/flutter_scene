//! The example's content: a lit cube, plus a strip of blocks that encodes
//! the frame index so a capture shows which frame the texture holds.

use bytemuck::{Pod, Zeroable};
use wgpu::util::DeviceExt;

/// What Dart passes for one frame.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct FswPresentFrame {
    pub view_proj: [f32; 16],
    pub model: [f32; 16],
    pub frame_index: u32,
    /// Top-left corner of the frame-index strip, in pixels.
    pub marker_x: u32,
    pub marker_y: u32,
    /// Side of one strip block, in pixels.
    pub marker_block: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct Uniforms {
    mvp: [f32; 16],
    model: [f32; 16],
    // marker x, marker y, block size, 1.0 when the shader must encode sRGB.
    marker: [f32; 4],
    frame: [u32; 4],
}

const SHADER: &str = r#"
struct U {
    mvp: mat4x4<f32>,
    model: mat4x4<f32>,
    marker: vec4<f32>,
    frame: vec4<u32>,
};
@group(0) @binding(0) var<uniform> u: U;

struct VOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) normal: vec3<f32>,
    @location(1) color: vec3<f32>,
};

fn encode(c: vec3<f32>) -> vec3<f32> {
    if (u.marker.w > 0.5) { return pow(c, vec3<f32>(1.0 / 2.2)); }
    return c;
}

@vertex
fn vs_cube(@location(0) p: vec3<f32>, @location(1) n: vec3<f32>, @location(2) c: vec3<f32>) -> VOut {
    var o: VOut;
    o.pos = u.mvp * vec4<f32>(p, 1.0);
    o.normal = (u.model * vec4<f32>(n, 0.0)).xyz;
    o.color = c;
    return o;
}

@fragment
fn fs_cube(i: VOut) -> @location(0) vec4<f32> {
    let l = normalize(vec3<f32>(0.4, 0.8, 0.5));
    let d = max(dot(normalize(i.normal), l), 0.0);
    return vec4<f32>(encode(i.color * (0.2 + 0.8 * d)), 1.0);
}

@vertex
fn vs_marker(@builtin(vertex_index) v: u32) -> @builtin(position) vec4<f32> {
    let x = f32((v << 1u) & 2u) * 2.0 - 1.0;
    let y = f32(v & 2u) * 2.0 - 1.0;
    return vec4<f32>(x, y, 0.0, 1.0);
}

// Block 0 is a magenta anchor; blocks 1..16 are the frame index, most
// significant bit first, white for 1 and black for 0.
@fragment
fn fs_marker(@builtin(position) p: vec4<f32>) -> @location(0) vec4<f32> {
    let b = u.marker.z;
    let bx = floor((p.x - u.marker.x) / b);
    let by = floor((p.y - u.marker.y) / b);
    if (by != 0.0 || bx < 0.0 || bx > 16.0) { discard; }
    if (bx == 0.0) { return vec4<f32>(1.0, 0.0, 1.0, 1.0); }
    let bit = (u.frame.x >> (16u - u32(bx))) & 1u;
    return vec4<f32>(vec3<f32>(f32(bit)), 1.0);
}
"#;

const DEPTH: wgpu::TextureFormat = wgpu::TextureFormat::Depth32Float;

pub struct CubeRenderer {
    format: wgpu::TextureFormat,
    cube: wgpu::RenderPipeline,
    marker: wgpu::RenderPipeline,
    vertices: wgpu::Buffer,
    indices: wgpu::Buffer,
    index_count: u32,
    uniforms: wgpu::Buffer,
    bind_group: wgpu::BindGroup,
    depth: Option<(u32, u32, wgpu::TextureView)>,
}

fn cube_mesh() -> (Vec<[f32; 9]>, Vec<u16>) {
    let faces: [([f32; 3], [f32; 3], [f32; 3], [f32; 3]); 6] = [
        ([1., 0., 0.], [0., 1., 0.], [0., 0., 1.], [0.9, 0.3, 0.3]),
        ([-1., 0., 0.], [0., 1., 0.], [0., 0., -1.], [0.3, 0.9, 0.3]),
        ([0., 1., 0.], [0., 0., 1.], [1., 0., 0.], [0.3, 0.4, 0.95]),
        ([0., -1., 0.], [0., 0., 1.], [-1., 0., 0.], [0.95, 0.85, 0.3]),
        ([0., 0., 1.], [0., 1., 0.], [-1., 0., 0.], [0.85, 0.4, 0.9]),
        ([0., 0., -1.], [0., 1., 0.], [1., 0., 0.], [0.3, 0.9, 0.9]),
    ];
    let mut v = Vec::new();
    let mut i = Vec::new();
    for (n, up, right, c) in faces {
        let base = v.len() as u16;
        for (su, sr) in [(-1., -1.), (-1., 1.), (1., 1.), (1., -1.)] {
            let p = [
                (n[0] + up[0] * su + right[0] * sr) * 0.5,
                (n[1] + up[1] * su + right[1] * sr) * 0.5,
                (n[2] + up[2] * su + right[2] * sr) * 0.5,
            ];
            v.push([p[0], p[1], p[2], n[0], n[1], n[2], c[0], c[1], c[2]]);
        }
        i.extend_from_slice(&[base, base + 1, base + 2, base, base + 2, base + 3]);
    }
    (v, i)
}

impl CubeRenderer {
    pub fn new(device: &wgpu::Device, format: wgpu::TextureFormat) -> CubeRenderer {
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("present cube"),
            source: wgpu::ShaderSource::Wgsl(SHADER.into()),
        });
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: None,
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: None,
            bind_group_layouts: &[Some(&layout)],
            immediate_size: 0,
        });
        let target = [Some(wgpu::ColorTargetState {
            format,
            blend: None,
            write_mask: wgpu::ColorWrites::ALL,
        })];
        let depth_state = |write: bool, compare| {
            Some(wgpu::DepthStencilState {
                format: DEPTH,
                depth_write_enabled: Some(write),
                depth_compare: Some(compare),
                stencil: Default::default(),
                bias: Default::default(),
            })
        };
        let cube = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("present cube"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &module,
                entry_point: Some("vs_cube"),
                compilation_options: Default::default(),
                buffers: &[Some(wgpu::VertexBufferLayout {
                    array_stride: 36,
                    step_mode: wgpu::VertexStepMode::Vertex,
                    attributes: &wgpu::vertex_attr_array![0 => Float32x3, 1 => Float32x3, 2 => Float32x3],
                })],
            },
            fragment: Some(wgpu::FragmentState {
                module: &module,
                entry_point: Some("fs_cube"),
                compilation_options: Default::default(),
                targets: &target,
            }),
            primitive: wgpu::PrimitiveState {
                cull_mode: None,
                ..Default::default()
            },
            depth_stencil: depth_state(true, wgpu::CompareFunction::Less),
            multisample: Default::default(),
            multiview_mask: None,
            cache: None,
        });
        let marker = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("present marker"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &module,
                entry_point: Some("vs_marker"),
                compilation_options: Default::default(),
                buffers: &[],
            },
            fragment: Some(wgpu::FragmentState {
                module: &module,
                entry_point: Some("fs_marker"),
                compilation_options: Default::default(),
                targets: &target,
            }),
            primitive: Default::default(),
            depth_stencil: depth_state(false, wgpu::CompareFunction::Always),
            multisample: Default::default(),
            multiview_mask: None,
            cache: None,
        });
        let (v, i) = cube_mesh();
        let vertices = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: None,
            contents: bytemuck::cast_slice(&v),
            usage: wgpu::BufferUsages::VERTEX,
        });
        let indices = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: None,
            contents: bytemuck::cast_slice(&i),
            usage: wgpu::BufferUsages::INDEX,
        });
        let uniforms = device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size: std::mem::size_of::<Uniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: uniforms.as_entire_binding(),
            }],
        });
        CubeRenderer {
            format,
            cube,
            marker,
            vertices,
            indices,
            index_count: i.len() as u32,
            uniforms,
            bind_group,
            depth: None,
        }
    }

    pub fn format(&self) -> wgpu::TextureFormat {
        self.format
    }

    /// Records the frame into `view` (a `width` x `height` target).
    pub fn encode(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        view: &wgpu::TextureView,
        width: u32,
        height: u32,
        frame: &FswPresentFrame,
    ) -> wgpu::CommandBuffer {
        if !matches!(&self.depth, Some((w, h, _)) if *w == width && *h == height) {
            let depth = device.create_texture(&wgpu::TextureDescriptor {
                label: Some("present depth"),
                size: wgpu::Extent3d {
                    width,
                    height,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: DEPTH,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                view_formats: &[],
            });
            self.depth = Some((width, height, depth.create_view(&Default::default())));
        }
        let mvp = mul(&frame.view_proj, &frame.model);
        let encode_srgb = if self.format.is_srgb() { 0.0 } else { 1.0 };
        let u = Uniforms {
            mvp,
            model: frame.model,
            marker: [
                frame.marker_x as f32,
                frame.marker_y as f32,
                frame.marker_block.max(1) as f32,
                encode_srgb,
            ],
            frame: [frame.frame_index & 0xffff, 0, 0, 0],
        };
        queue.write_buffer(&self.uniforms, 0, bytemuck::bytes_of(&u));

        let mut encoder = device.create_command_encoder(&Default::default());
        {
            let depth = &self.depth.as_ref().unwrap().2;
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("present"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: 0.08,
                            g: 0.09,
                            b: 0.12,
                            a: 1.0,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                    view: depth,
                    depth_ops: Some(wgpu::Operations {
                        load: wgpu::LoadOp::Clear(1.0),
                        store: wgpu::StoreOp::Discard,
                    }),
                    stencil_ops: None,
                }),
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            pass.set_bind_group(0, &self.bind_group, &[]);
            pass.set_pipeline(&self.cube);
            pass.set_vertex_buffer(0, self.vertices.slice(..));
            pass.set_index_buffer(self.indices.slice(..), wgpu::IndexFormat::Uint16);
            pass.draw_indexed(0..self.index_count, 0, 0..1);
            pass.set_pipeline(&self.marker);
            pass.draw(0..3, 0..1);
        }
        encoder.finish()
    }
}

// Column-major 4x4 product a * b.
fn mul(a: &[f32; 16], b: &[f32; 16]) -> [f32; 16] {
    let mut o = [0.0; 16];
    for c in 0..4 {
        for r in 0..4 {
            o[c * 4 + r] = (0..4).map(|k| a[k * 4 + r] * b[c * 4 + k]).sum();
        }
    }
    o
}
