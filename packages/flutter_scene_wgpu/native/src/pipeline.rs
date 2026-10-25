//! Render pipelines: the packed descriptor, explicit bind group layouts
//! built from shader reflection, and synchronous or worker-thread compiles.
//!
//! # Descriptor format
//!
//! Little-endian; every scalar is a `u32` unless noted, strings are a
//! `u32` byte length, the UTF-8 bytes and zero padding to four bytes. Enum
//! values are flutter_gpu ordinals.
//!
//! ```text
//! u64 vertex shader, string vertex entry point
//! u64 fragment shader (0: none), string fragment entry point
//! primitive type, cull mode, winding order, polygon mode, sample count
//! vertex buffer count, then per buffer:
//!     stride, step mode, attribute count, then per attribute:
//!         vertex format, offset, shader location
//! color target count, then per target:
//!     pixel format, blend enabled,
//!     color op, color src factor, color dst factor,
//!     alpha op, alpha src factor, alpha dst factor,
//!     write mask (bits r=1 g=2 b=4 a=8)
//! has depth/stencil, then if set:
//!     pixel format, depth write enabled, depth compare,
//!     front: compare, fail op, depth fail op, pass op,
//!     back: compare, fail op, depth fail op, pass op,
//!     stencil read mask, stencil write mask
//! optionally: binding override count, then per override:
//!     group, binding, code (see `ResourceKind::overridden`)
//! ```

use std::collections::BTreeMap;
use std::sync::{Arc, Condvar, Mutex};

use crate::error::{invalid, scoped, Code, FswError, Result};
use crate::format;
use crate::reader::Reader;
use crate::reflect::ResourceKind;
use crate::registry::Registry;

pub struct GroupLayout {
    pub layout: wgpu::BindGroupLayout,
    pub entries: Vec<(u32, ResourceKind)>,
}

pub struct Built {
    pub pipeline: wgpu::RenderPipeline,
    pub groups: Vec<GroupLayout>,
}

pub enum State {
    Pending,
    Ready(Arc<Built>),
    Failed(FswError),
}

/// A pipeline handle's state, written once by the compiling thread.
pub struct PipelineSlot {
    state: Mutex<State>,
    done: Condvar,
}

impl PipelineSlot {
    fn new(state: State) -> Self {
        Self {
            state: Mutex::new(state),
            done: Condvar::new(),
        }
    }

    fn finish(&self, state: State) {
        *self.state.lock().unwrap_or_else(|p| p.into_inner()) = state;
        self.done.notify_all();
    }

    /// `Ok` when built, [`Code::NotReady`] while compiling, the compile
    /// error once failed.
    pub fn status(&self) -> Result<Arc<Built>> {
        match &*self.state.lock().unwrap_or_else(|p| p.into_inner()) {
            State::Ready(built) => Ok(built.clone()),
            State::Pending => Err(FswError::new(Code::NotReady, "pipeline is still compiling")),
            State::Failed(error) => Err(error.clone()),
        }
    }

    pub fn wait(&self) -> Result<Arc<Built>> {
        let mut state = self.state.lock().unwrap_or_else(|p| p.into_inner());
        while matches!(*state, State::Pending) {
            state = self.done.wait(state).unwrap_or_else(|p| p.into_inner());
        }
        drop(state);
        self.status()
    }
}

struct VertexBufferDesc {
    stride: u64,
    step: wgpu::VertexStepMode,
    attributes: Vec<wgpu::VertexAttribute>,
}

/// Everything a compile needs, owned so it can move to a worker thread.
pub struct Prepared {
    device: wgpu::Device,
    vertex: (wgpu::ShaderModule, String),
    fragment: Option<(wgpu::ShaderModule, String)>,
    primitive: wgpu::PrimitiveState,
    sample_count: u32,
    buffers: Vec<VertexBufferDesc>,
    targets: Vec<Option<wgpu::ColorTargetState>>,
    depth_stencil: Option<wgpu::DepthStencilState>,
    layout: wgpu::PipelineLayout,
    groups: Vec<GroupLayout>,
}

pub fn prepare(reg: &Registry, device_handle: u64, desc: &[u8]) -> Result<Prepared> {
    let state = reg.device(device_handle)?;
    let device = state.device.clone();
    let mut r = Reader::new(desc);

    let vs_handle = r.u64()?;
    let vs_entry = r.string()?;
    let fs_handle = r.u64()?;
    let fs_entry = r.string()?;
    let vs = reg.shader(device_handle, vs_handle)?;
    let fs = if fs_handle == 0 {
        None
    } else {
        Some(reg.shader(device_handle, fs_handle)?)
    };

    let topology = format::primitive(r.u32()?)?;
    let cull_mode = format::cull(r.u32()?)?;
    let front_face = format::winding(r.u32()?)?;
    let polygon_mode = format::polygon(r.u32()?)?;
    let sample_count = r.u32()?.max(1);

    let mut buffers = Vec::new();
    for _ in 0..r.u32()? {
        let stride = r.u32()? as u64;
        let step = format::step_mode(r.u32()?)?;
        let mut attributes = Vec::new();
        for _ in 0..r.u32()? {
            let format = format::vertex_format(r.u32()?)?;
            let offset = r.u32()? as u64;
            let shader_location = r.u32()?;
            attributes.push(wgpu::VertexAttribute {
                format,
                offset,
                shader_location,
            });
        }
        buffers.push(VertexBufferDesc {
            stride,
            step,
            attributes,
        });
    }

    let mut targets = Vec::new();
    for _ in 0..r.u32()? {
        let format = format::pixel_format(r.u32()?)?;
        let enabled = r.bool()?;
        let color = blend_component(&mut r)?;
        let alpha = blend_component(&mut r)?;
        let mask = r.u32()?;
        targets.push(Some(wgpu::ColorTargetState {
            format,
            blend: enabled.then_some(wgpu::BlendState { color, alpha }),
            write_mask: wgpu::ColorWrites::from_bits_truncate(mask),
        }));
    }

    let depth_stencil = if r.bool()? {
        let format = format::pixel_format(r.u32()?)?;
        let depth_write_enabled = r.bool()?;
        let depth_compare = format::compare(r.u32()?)?;
        let front = stencil_face(&mut r)?;
        let back = stencil_face(&mut r)?;
        let read_mask = r.u32()?;
        let write_mask = r.u32()?;
        Some(wgpu::DepthStencilState {
            format,
            depth_write_enabled: Some(depth_write_enabled),
            depth_compare: Some(depth_compare),
            stencil: wgpu::StencilState {
                front,
                back,
                read_mask,
                write_mask,
            },
            bias: Default::default(),
        })
    } else {
        None
    };
    let mut overrides = BTreeMap::new();
    if !r.done() {
        for _ in 0..r.u32()? {
            overrides.insert((r.u32()?, r.u32()?), r.u32()?);
        }
    }
    if !r.done() {
        return Err(invalid("pipeline descriptor has trailing bytes"));
    }

    // Merge the bindings both stages declare, keyed by group then binding.
    let mut merged: BTreeMap<u32, BTreeMap<u32, (ResourceKind, wgpu::ShaderStages)>> =
        BTreeMap::new();
    let stages = [(Some(vs), wgpu::ShaderStages::VERTEX), (fs, wgpu::ShaderStages::FRAGMENT)];
    for (shader, stage) in stages {
        let Some(shader) = shader else { continue };
        for res in &shader.resources {
            let slot = merged
                .entry(res.group)
                .or_default()
                .entry(res.binding)
                .or_insert((res.kind, wgpu::ShaderStages::empty()));
            if slot.0 != res.kind {
                return Err(invalid(format!(
                    "@group({}) @binding({}) has different types in the two stages",
                    res.group, res.binding
                )));
            }
            slot.1 |= stage;
        }
    }
    for ((group, binding), code) in overrides {
        if let Some(slot) = merged.get_mut(&group).and_then(|g| g.get_mut(&binding)) {
            slot.0 = slot.0.overridden(code)?;
        }
    }
    let group_count = merged.keys().next_back().map_or(0, |g| g + 1);
    let mut groups = Vec::new();
    scoped(&device, || {
        for g in 0..group_count {
            let bindings = merged.get(&g).cloned().unwrap_or_default();
            let entries: Vec<_> = bindings
                .iter()
                .map(|(&binding, &(kind, visibility))| wgpu::BindGroupLayoutEntry {
                    binding,
                    visibility,
                    ty: kind.binding_type(),
                    count: None,
                })
                .collect();
            let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                label: None,
                entries: &entries,
            });
            groups.push(GroupLayout {
                layout,
                entries: bindings.iter().map(|(&b, &(k, _))| (b, k)).collect(),
            });
        }
    })?;
    let layout = scoped(&device, || {
        let refs: Vec<_> = groups.iter().map(|g| Some(&g.layout)).collect();
        device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: None,
            bind_group_layouts: &refs,
            immediate_size: 0,
        })
    })?;

    Ok(Prepared {
        vertex: (vs.module.clone(), vs_entry),
        fragment: fs.map(|fs| (fs.module.clone(), fs_entry)),
        primitive: wgpu::PrimitiveState {
            topology,
            strip_index_format: None,
            front_face,
            cull_mode,
            unclipped_depth: false,
            polygon_mode,
            conservative: false,
        },
        sample_count,
        buffers,
        targets,
        depth_stencil,
        layout,
        groups,
        device,
    })
}

fn blend_component(r: &mut Reader) -> Result<wgpu::BlendComponent> {
    let operation = format::blend_op(r.u32()?)?;
    let src_factor = format::blend_factor(r.u32()?)?;
    let dst_factor = format::blend_factor(r.u32()?)?;
    Ok(wgpu::BlendComponent {
        src_factor,
        dst_factor,
        operation,
    })
}

fn stencil_face(r: &mut Reader) -> Result<wgpu::StencilFaceState> {
    Ok(wgpu::StencilFaceState {
        compare: format::compare(r.u32()?)?,
        fail_op: format::stencil_op(r.u32()?)?,
        depth_fail_op: format::stencil_op(r.u32()?)?,
        pass_op: format::stencil_op(r.u32()?)?,
    })
}

fn entry(name: &str) -> Option<&str> {
    (!name.is_empty()).then_some(name)
}

impl Prepared {
    fn compile(self) -> Result<Built> {
        let buffers: Vec<_> = self
            .buffers
            .iter()
            .map(|b| {
                Some(wgpu::VertexBufferLayout {
                    array_stride: b.stride,
                    step_mode: b.step,
                    attributes: &b.attributes,
                })
            })
            .collect();
        let device = &self.device;
        let pipeline = scoped(device, || {
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: None,
                layout: Some(&self.layout),
                vertex: wgpu::VertexState {
                    module: &self.vertex.0,
                    entry_point: entry(&self.vertex.1),
                    compilation_options: Default::default(),
                    buffers: &buffers,
                },
                primitive: self.primitive,
                depth_stencil: self.depth_stencil.clone(),
                multisample: wgpu::MultisampleState {
                    count: self.sample_count,
                    mask: !0,
                    alpha_to_coverage_enabled: false,
                },
                fragment: self.fragment.as_ref().map(|(module, name)| wgpu::FragmentState {
                    module,
                    entry_point: entry(name),
                    compilation_options: Default::default(),
                    targets: &self.targets,
                }),
                multiview_mask: None,
                cache: None,
            })
        })?;
        Ok(Built {
            pipeline,
            groups: self.groups,
        })
    }

    pub fn compile_now(self) -> PipelineSlot {
        PipelineSlot::new(match self.compile() {
            Ok(built) => State::Ready(Arc::new(built)),
            Err(error) => State::Failed(error),
        })
    }

    /// Returns a pending slot and finishes it from a worker thread.
    pub fn compile_async(self) -> Arc<PipelineSlot> {
        let slot = Arc::new(PipelineSlot::new(State::Pending));
        let worker = slot.clone();
        std::thread::spawn(move || {
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| self.compile()));
            worker.finish(match result {
                Ok(Ok(built)) => State::Ready(Arc::new(built)),
                Ok(Err(error)) => State::Failed(error),
                Err(_) => State::Failed(FswError::new(Code::Panic, "pipeline compile panicked")),
            });
        });
        slot
    }
}
