//! The packed command stream: one buffer per submit, decoded into a single
//! wgpu command encoder and submitted to the queue.
//!
//! # Format
//!
//! Little-endian. The stream is a sequence of commands, each an 8-byte
//! header (`u32` opcode, `u32` payload length in bytes) followed by the
//! payload. Scalars are `u32` unless marked; `u64` fields (handles,
//! offsets, sizes) are 8 bytes and need no alignment. Enum values are
//! flutter_gpu ordinals. A decoder that reads a different number of payload
//! bytes than the header states rejects the stream.
//!
//! | op | command | payload |
//! |----|---------|---------|
//! | 1  | begin render pass | color count; per color: u64 texture, mip level, slice, load action, store action, f32 r g b a clear, u64 resolve texture (0: none); has depth/stencil; if set: u64 texture, mip level, slice, depth load, depth store, f32 depth clear, stencil load, stencil store, stencil clear |
//! | 2  | end render pass | (none) |
//! | 3  | bind pipeline | u64 pipeline |
//! | 4  | bind vertex buffer | slot, u64 buffer, u64 offset, u64 size (0: to the end) |
//! | 5  | bind index buffer | u64 buffer, u64 offset, u64 size (0: to the end), index type |
//! | 6  | bind buffer range (uniform or storage) | group, binding, u64 buffer, u64 offset, u64 size (0: to the end) |
//! | 7  | bind texture and sampler | group, texture binding, u64 texture, sampler binding, u64 sampler (0: texture only) |
//! | 8  | set viewport | f32 x, y, width, height, min depth, max depth |
//! | 9  | set scissor | x, y, width, height |
//! | 10 | set stencil reference | reference |
//! | 11 | set blend constant | f32 r, g, b, a |
//! | 12 | draw | vertex count, instance count, first vertex, first instance |
//! | 13 | draw indexed | index count, instance count, first index, i32 base vertex, first instance |
//! | 14 | copy buffer to buffer | u64 src, u64 src offset, u64 dst, u64 dst offset, u64 size |
//! | 15 | copy buffer to texture | u64 buffer, u64 offset, bytes per row, rows per image, u64 texture, mip level, slice, x, y, width, height |
//! | 16 | copy texture to buffer | u64 texture, mip level, slice, x, y, width, height, u64 buffer, u64 offset, bytes per row, rows per image |
//! | 17 | copy texture to texture | u64 src, mip level, slice, x, y, u64 dst, mip level, slice, x, y, width, height |
//! | 18 | generate mipmaps | u64 texture |
//!
//! Commands 3 to 13 are valid only inside a render pass, 14 to 18 only
//! outside one. Bindings persist across draws and passes until rebound.
//! Buffer copies need `bytes per row` to be a multiple of 256 and offsets a
//! multiple of 4 (wgpu's copy alignment). Uniform binding offsets must be a
//! multiple of the device's `minUniformBufferOffsetAlignment` limit.

use std::collections::HashMap;
use std::sync::Arc;

use crate::error::{invalid, scoped, unsupported, Result};
use crate::format;
use crate::pipeline::Built;
use crate::reader::Reader;
use crate::reflect::ResourceKind;
use crate::registry::{DeviceState, Registry};

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum Bound {
    Buffer { handle: u64, offset: u64, size: u64 },
    Texture(u64),
    Sampler(u64),
}

struct Decoder<'r> {
    reg: &'r Registry,
    device_handle: u64,
    state: Arc<DeviceState>,
    encoder: Option<wgpu::CommandEncoder>,
    pass: Option<wgpu::RenderPass<'static>>,
    pipeline: Option<Arc<Built>>,
    bindings: HashMap<(u32, u32), Bound>,
    groups_dirty: bool,
    cache: HashMap<(usize, Vec<Bound>), wgpu::BindGroup>,
}

fn view_2d(texture: &wgpu::Texture, mip: u32, slice: u32) -> wgpu::TextureView {
    texture.create_view(&wgpu::TextureViewDescriptor {
        dimension: Some(wgpu::TextureViewDimension::D2),
        base_mip_level: mip,
        mip_level_count: Some(1),
        base_array_layer: slice,
        array_layer_count: Some(1),
        ..Default::default()
    })
}

fn size_or_rest(size: u64) -> Option<wgpu::BufferSize> {
    wgpu::BufferSize::new(size)
}

impl<'r> Decoder<'r> {
    fn pass(&mut self) -> Result<&mut wgpu::RenderPass<'static>> {
        self.pass.as_mut().ok_or_else(|| invalid("command needs an open render pass"))
    }

    fn encoder(&mut self) -> Result<&mut wgpu::CommandEncoder> {
        if self.pass.is_some() {
            return Err(invalid("copy and mipmap commands are not allowed inside a render pass"));
        }
        Ok(self.encoder.as_mut().unwrap())
    }

    fn texture(&self, handle: u64) -> Result<&'r crate::registry::TextureObj> {
        self.reg.texture(self.device_handle, handle)
    }

    fn begin_pass(&mut self, r: &mut Reader) -> Result<()> {
        if self.pass.is_some() {
            return Err(invalid("render pass begun while another is open"));
        }
        let mut views = Vec::new();
        let mut colors = Vec::new();
        for _ in 0..r.u32()? {
            let texture = self.texture(r.u64()?)?;
            let mip = r.u32()?;
            let slice = r.u32()?;
            let load = r.u32()?;
            let (store, resolves) = format::store(r.u32()?)?;
            let clear = wgpu::Color {
                r: r.f32()? as f64,
                g: r.f32()? as f64,
                b: r.f32()? as f64,
                a: r.f32()? as f64,
            };
            let resolve = r.u64()?;
            let view = view_2d(&texture.texture, mip, slice);
            let resolve_view = match (resolves, resolve) {
                (true, 0) => return Err(invalid("multisample resolve without a resolve texture")),
                (true, h) => Some(view_2d(&self.texture(h)?.texture, 0, 0)),
                (false, _) => None,
            };
            views.push((view, resolve_view));
            colors.push((format::load(load, clear)?, store));
        }
        let depth = if r.bool()? {
            let texture = self.texture(r.u64()?)?;
            let mip = r.u32()?;
            let slice = r.u32()?;
            let depth_load = r.u32()?;
            let (depth_store, _) = format::store(r.u32()?)?;
            let depth_clear = r.f32()?;
            let stencil_load = r.u32()?;
            let (stencil_store, _) = format::store(r.u32()?)?;
            let stencil_clear = r.u32()?;
            let fmt = texture.texture.format();
            fn ops<V>(has: bool, load: wgpu::LoadOp<V>, store: wgpu::StoreOp) -> Result<Option<wgpu::Operations<V>>> {
                Ok(has.then_some(wgpu::Operations { load, store }))
            }
            Some((
                view_2d(&texture.texture, mip, slice),
                ops(fmt.has_depth_aspect(), format::load(depth_load, depth_clear)?, depth_store)?,
                ops(
                    fmt.has_stencil_aspect(),
                    format::load(stencil_load, stencil_clear)?,
                    stencil_store,
                )?,
            ))
        } else {
            None
        };
        let color_attachments: Vec<_> = views
            .iter()
            .zip(&colors)
            .map(|((view, resolve), (load, store))| {
                Some(wgpu::RenderPassColorAttachment {
                    view,
                    depth_slice: None,
                    resolve_target: resolve.as_ref(),
                    ops: wgpu::Operations {
                        load: *load,
                        store: *store,
                    },
                })
            })
            .collect();
        let encoder = self.encoder.as_mut().unwrap();
        let pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: None,
            color_attachments: &color_attachments,
            depth_stencil_attachment: depth.as_ref().map(|(view, depth_ops, stencil_ops)| {
                wgpu::RenderPassDepthStencilAttachment {
                    view,
                    depth_ops: *depth_ops,
                    stencil_ops: *stencil_ops,
                }
            }),
            timestamp_writes: None,
            occlusion_query_set: None,
            multiview_mask: None,
        });
        self.pass = Some(pass.forget_lifetime());
        self.groups_dirty = true;
        Ok(())
    }

    fn flush_bind_groups(&mut self) -> Result<()> {
        if !self.groups_dirty {
            return Ok(());
        }
        let built = self.pipeline.clone().ok_or_else(|| invalid("draw without a bound pipeline"))?;
        for (index, group) in built.groups.iter().enumerate() {
            let mut key = Vec::with_capacity(group.entries.len());
            for &(binding, kind) in &group.entries {
                let bound = self.bindings.get(&(index as u32, binding)).copied().ok_or_else(|| {
                    invalid(format!("@group({index}) @binding({binding}) is not bound"))
                })?;
                let fits = matches!(
                    (kind, bound),
                    (ResourceKind::UniformBuffer | ResourceKind::StorageBuffer { .. }, Bound::Buffer { .. })
                        | (ResourceKind::Texture { .. }, Bound::Texture(_))
                        | (ResourceKind::Sampler { .. }, Bound::Sampler(_))
                );
                if !fits {
                    return Err(invalid(format!(
                        "@group({index}) @binding({binding}) is bound to the wrong kind of resource"
                    )));
                }
                key.push(bound);
            }
            let cache_key = (Arc::as_ptr(&built) as usize + index, key);
            if !self.cache.contains_key(&cache_key) {
                let mut views = Vec::new();
                for (&(_, kind), bound) in group.entries.iter().zip(&cache_key.1) {
                    if let (ResourceKind::Texture { view_dimension, .. }, Bound::Texture(h)) =
                        (kind, bound)
                    {
                        views.push(self.texture(*h)?.texture.create_view(
                            &wgpu::TextureViewDescriptor {
                                dimension: Some(view_dimension),
                                ..Default::default()
                            },
                        ));
                    }
                }
                let mut views_iter = views.iter();
                let mut entries = Vec::new();
                for (&(binding, _), bound) in group.entries.iter().zip(&cache_key.1) {
                    let resource = match *bound {
                        Bound::Buffer { handle, offset, size } => {
                            wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                                buffer: &self.reg.buffer(self.device_handle, handle)?.buffer,
                                offset,
                                size: size_or_rest(size),
                            })
                        }
                        Bound::Texture(_) => {
                            wgpu::BindingResource::TextureView(views_iter.next().unwrap())
                        }
                        Bound::Sampler(h) => {
                            wgpu::BindingResource::Sampler(self.reg.sampler(self.device_handle, h)?)
                        }
                    };
                    entries.push(wgpu::BindGroupEntry { binding, resource });
                }
                let bind_group = self.state.device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: None,
                    layout: &group.layout,
                    entries: &entries,
                });
                self.cache.insert(cache_key.clone(), bind_group);
            }
            let bind_group = &self.cache[&cache_key];
            self.pass.as_mut().unwrap().set_bind_group(index as u32, bind_group, &[]);
        }
        self.groups_dirty = false;
        Ok(())
    }

    fn command(&mut self, op: u32, r: &mut Reader) -> Result<()> {
        match op {
            1 => self.begin_pass(r)?,
            2 => {
                self.pass.take().ok_or_else(|| invalid("end render pass without a pass"))?;
            }
            3 => {
                let built = self.reg.pipeline(self.device_handle, r.u64()?)?.status()?;
                self.pass()?.set_pipeline(&built.pipeline);
                self.pipeline = Some(built);
                self.groups_dirty = true;
            }
            4 => {
                let slot = r.u32()?;
                let buffer = &self.reg.buffer(self.device_handle, r.u64()?)?.buffer;
                let offset = r.u64()?;
                let size = r.u64()?;
                let slice = if size == 0 {
                    buffer.slice(offset..)
                } else {
                    buffer.slice(offset..offset + size)
                };
                self.pass()?.set_vertex_buffer(slot, slice);
            }
            5 => {
                let buffer = &self.reg.buffer(self.device_handle, r.u64()?)?.buffer;
                let offset = r.u64()?;
                let size = r.u64()?;
                let index = format::index_format(r.u32()?)?;
                let slice = if size == 0 {
                    buffer.slice(offset..)
                } else {
                    buffer.slice(offset..offset + size)
                };
                self.pass()?.set_index_buffer(slice, index);
            }
            6 => {
                let key = (r.u32()?, r.u32()?);
                let handle = r.u64()?;
                self.reg.buffer(self.device_handle, handle)?;
                let bound = Bound::Buffer {
                    handle,
                    offset: r.u64()?,
                    size: r.u64()?,
                };
                self.bindings.insert(key, bound);
                self.groups_dirty = true;
            }
            7 => {
                let group = r.u32()?;
                let binding = r.u32()?;
                let texture = r.u64()?;
                let sampler_binding = r.u32()?;
                let sampler = r.u64()?;
                self.texture(texture)?;
                self.bindings.insert((group, binding), Bound::Texture(texture));
                if sampler != 0 {
                    self.reg.sampler(self.device_handle, sampler)?;
                    self.bindings.insert((group, sampler_binding), Bound::Sampler(sampler));
                }
                self.groups_dirty = true;
            }
            8 => {
                let v = [r.f32()?, r.f32()?, r.f32()?, r.f32()?, r.f32()?, r.f32()?];
                self.pass()?.set_viewport(v[0], v[1], v[2], v[3], v[4], v[5]);
            }
            9 => {
                let v = [r.u32()?, r.u32()?, r.u32()?, r.u32()?];
                self.pass()?.set_scissor_rect(v[0], v[1], v[2], v[3]);
            }
            10 => {
                let reference = r.u32()?;
                self.pass()?.set_stencil_reference(reference);
            }
            11 => {
                let c = wgpu::Color {
                    r: r.f32()? as f64,
                    g: r.f32()? as f64,
                    b: r.f32()? as f64,
                    a: r.f32()? as f64,
                };
                self.pass()?.set_blend_constant(c);
            }
            12 => {
                let (count, instances, first, first_instance) = (r.u32()?, r.u32()?, r.u32()?, r.u32()?);
                self.pass()?;
                self.flush_bind_groups()?;
                self.pass()?
                    .draw(first..first + count, first_instance..first_instance + instances);
            }
            13 => {
                let (count, instances, first) = (r.u32()?, r.u32()?, r.u32()?);
                let base_vertex = r.i32()?;
                let first_instance = r.u32()?;
                self.pass()?;
                self.flush_bind_groups()?;
                self.pass()?.draw_indexed(
                    first..first + count,
                    base_vertex,
                    first_instance..first_instance + instances,
                );
            }
            14 => {
                let src = &self.reg.buffer(self.device_handle, r.u64()?)?.buffer;
                let src_offset = r.u64()?;
                let dst = &self.reg.buffer(self.device_handle, r.u64()?)?.buffer;
                let dst_offset = r.u64()?;
                let size = r.u64()?;
                self.encoder()?.copy_buffer_to_buffer(src, src_offset, dst, dst_offset, size);
            }
            15 => {
                let buffer = &self.reg.buffer(self.device_handle, r.u64()?)?.buffer;
                let layout = wgpu::TexelCopyBufferLayout {
                    offset: r.u64()?,
                    bytes_per_row: Some(r.u32()?),
                    rows_per_image: Some(r.u32()?),
                };
                let (texture, size) = self.texture_region(r)?;
                self.encoder()?.copy_buffer_to_texture(
                    wgpu::TexelCopyBufferInfo { buffer, layout },
                    texture,
                    size,
                );
            }
            16 => {
                let (texture, size) = self.texture_region(r)?;
                let buffer = &self.reg.buffer(self.device_handle, r.u64()?)?.buffer;
                let layout = wgpu::TexelCopyBufferLayout {
                    offset: r.u64()?,
                    bytes_per_row: Some(r.u32()?),
                    rows_per_image: Some(r.u32()?),
                };
                self.encoder()?.copy_texture_to_buffer(
                    texture,
                    wgpu::TexelCopyBufferInfo { buffer, layout },
                    size,
                );
            }
            17 => {
                let src = self.texture_origin(r)?;
                let dst = self.texture_origin(r)?;
                let size = wgpu::Extent3d {
                    width: r.u32()?,
                    height: r.u32()?,
                    depth_or_array_layers: 1,
                };
                self.encoder()?.copy_texture_to_texture(src, dst, size);
            }
            18 => {
                let texture = &self.texture(r.u64()?)?.texture;
                if !texture.usage().contains(wgpu::TextureUsages::RENDER_ATTACHMENT) {
                    return Err(unsupported(
                        "mipmap generation needs a color-renderable, filterable texture format",
                    ));
                }
                let state = self.state.clone();
                let encoder = self.encoder()?;
                state
                    .mipmaps
                    .lock()
                    .unwrap_or_else(|p| p.into_inner())
                    .generate(&state.device, encoder, texture);
            }
            _ => return Err(invalid(format!("unknown command opcode {op}"))),
        }
        Ok(())
    }

    fn texture_origin(&self, r: &mut Reader) -> Result<wgpu::TexelCopyTextureInfo<'r>> {
        let texture = &self.texture(r.u64()?)?.texture;
        let mip_level = r.u32()?;
        let slice = r.u32()?;
        Ok(wgpu::TexelCopyTextureInfo {
            texture,
            mip_level,
            origin: wgpu::Origin3d {
                x: r.u32()?,
                y: r.u32()?,
                z: slice,
            },
            aspect: wgpu::TextureAspect::All,
        })
    }

    fn texture_region(&self, r: &mut Reader) -> Result<(wgpu::TexelCopyTextureInfo<'r>, wgpu::Extent3d)> {
        let origin = self.texture_origin(r)?;
        let size = wgpu::Extent3d {
            width: r.u32()?,
            height: r.u32()?,
            depth_or_array_layers: 1,
        };
        Ok((origin, size))
    }
}

pub fn submit(reg: &Registry, device_handle: u64, stream: &[u8]) -> Result<()> {
    let state = reg.device(device_handle)?;
    let device = state.device.clone();
    let mut decoder = Decoder {
        reg,
        device_handle,
        encoder: Some(device.create_command_encoder(&Default::default())),
        state,
        pass: None,
        pipeline: None,
        bindings: HashMap::new(),
        groups_dirty: true,
        cache: HashMap::new(),
    };
    scoped(&device, || -> Result<()> {
        let mut r = Reader::new(stream);
        while !r.done() {
            let op = r.u32()?;
            let len = r.u32()? as usize;
            let start = r.pos;
            let mut payload = Reader::new(r.bytes(len)?);
            decoder.command(op, &mut payload)?;
            if payload.pos != len {
                return Err(invalid(format!(
                    "command {op} at byte {} declares {len} payload bytes but uses {}",
                    start - 8,
                    payload.pos
                )));
            }
        }
        if decoder.pass.take().is_some() {
            return Err(invalid("command stream ends inside a render pass"));
        }
        let commands = decoder.encoder.take().unwrap().finish();
        decoder.state.queue.submit([commands]);
        Ok(())
    })?
}
