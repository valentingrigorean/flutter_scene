//! Native side of flutter_scene_wgpu: wgpu behind a synchronous,
//! handle-based C ABI that the Dart FFI bindings call.
//!
//! Every call returns an `i32` status ([`error::Code`]); handles and other
//! results come back through out pointers. Objects are `u64` handles into
//! one global table, `0` is never valid, and resources are destroyed with
//! `fsw_destroy`. Enum arguments are flutter_gpu ordinals ([`format`]).
//! Rendering goes through one packed command stream per submit
//! ([`commands`]).

mod commands;
mod defaults;
mod error;
mod format;
mod mipmap;
mod pipeline;
mod present;
mod reader;
mod reflect;
mod registry;
mod spirv_split;

use std::sync::{Arc, Mutex};

use error::{guard, invalid, scoped, unsupported, Code, FswError, Result};
use reader::slice;
use registry::{BufferObj, DeviceState, Object, ShaderObj, TextureObj};
use wgpu::naga;

/// Returns the ABI version the Dart bindings check at load.
#[no_mangle]
pub extern "C" fn fsw_abi_version() -> u32 {
    1
}

fn out<T>(ptr: *mut T, value: T) -> Result<()> {
    if ptr.is_null() {
        return Err(invalid("null out pointer"));
    }
    unsafe { ptr.write(value) };
    Ok(())
}

// Feature bits reported by fsw_device_features.
const FEATURE_COMPUTE: u64 = 1 << 0;
const FEATURE_INDIRECT_DRAW: u64 = 1 << 1;
const FEATURE_TEXTURE_BINDING_ARRAY: u64 = 1 << 2;
const FEATURE_TIMESTAMP_QUERY: u64 = 1 << 3;
const FEATURE_BC: u64 = 1 << 4;
const FEATURE_ETC2: u64 = 1 << 5;
const FEATURE_ASTC: u64 = 1 << 6;
const FEATURE_ASTC_HDR: u64 = 1 << 7;
const FEATURE_DEPTH32_STENCIL8: u64 = 1 << 8;
const FEATURE_FLOAT32_FILTERABLE: u64 = 1 << 9;
const FEATURE_INDIRECT_FIRST_INSTANCE: u64 = 1 << 10;

/// The process's one wgpu device, which the device API and every presenter
/// share, so a scene renders straight into a presenter's textures.
static SHARED_DEVICE: Mutex<Option<Arc<DeviceState>>> = Mutex::new(None);

/// The shared device, opened on the instance and adapter [choose] returns
/// when nothing opened it yet. A presenter chooses an adapter that can
/// present to its surface; the device API takes wgpu's preferred one.
pub(crate) fn shared_device(
    choose: impl FnOnce() -> Result<(wgpu::Instance, wgpu::Adapter)>,
) -> Result<Arc<DeviceState>> {
    let mut shared = SHARED_DEVICE.lock().unwrap_or_else(|p| p.into_inner());
    if let Some(state) = shared.as_ref() {
        return Ok(state.clone());
    }
    let (instance, adapter) = choose()?;
    let wanted = wgpu::Features::TEXTURE_COMPRESSION_BC
        | wgpu::Features::TEXTURE_COMPRESSION_ETC2
        | wgpu::Features::TEXTURE_COMPRESSION_ASTC
        | wgpu::Features::TEXTURE_COMPRESSION_ASTC_HDR
        | wgpu::Features::DEPTH32FLOAT_STENCIL8
        | wgpu::Features::TIMESTAMP_QUERY
        | wgpu::Features::TEXTURE_BINDING_ARRAY
        | wgpu::Features::FLOAT32_FILTERABLE
        | wgpu::Features::INDIRECT_FIRST_INSTANCE;
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some("flutter_scene_wgpu"),
        required_features: adapter.features() & wanted,
        required_limits: adapter.limits(),
        ..Default::default()
    }))
    .map_err(|e| FswError::new(Code::NoAdapter, e.to_string()))?;
    // Errors outside an error scope must not reach wgpu's default handler,
    // which panics.
    device.on_uncaptured_error(Arc::new(|error| {
        eprintln!("flutter_scene_wgpu: uncaptured wgpu error: {error}");
    }));
    let state = Arc::new(DeviceState {
        instance,
        adapter,
        device,
        queue,
        mipmaps: Mutex::new(Default::default()),
        defaults: Default::default(),
    });
    *shared = Some(state.clone());
    Ok(state)
}

/// Returns a handle on the shared device, opening it headless on the
/// adapter wgpu prefers when no presenter opened it first. `backends` is a
/// wgpu `Backends` bit set (Vulkan 1, GL 2, Metal 4, DX12 8), 0 for all; it
/// only applies when this call opens the device.
#[no_mangle]
pub extern "C" fn fsw_device_create(backends: u32, out_device: *mut u64) -> i32 {
    guard(|| {
        let state = shared_device(|| {
            let mut desc = wgpu::InstanceDescriptor::new_without_display_handle_from_env();
            if backends != 0 {
                desc.backends = wgpu::Backends::from_bits_truncate(backends);
            }
            let instance = wgpu::Instance::new(desc);
            let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                force_fallback_adapter: false,
                compatible_surface: None,
                ..Default::default()
            }))
            .map_err(|e| FswError::new(Code::NoAdapter, e.to_string()))?;
            Ok((instance, adapter))
        })?;
        let handle = registry::lock().insert(0, Object::Device(state));
        out(out_device, handle)
    })
}

/// The adapter's backend: 0 noop, 1 Vulkan, 2 Metal, 3 DX12, 4 GL, 5 WebGPU.
#[no_mangle]
pub extern "C" fn fsw_device_backend(device: u64, out_backend: *mut u32) -> i32 {
    guard(|| {
        let state = registry::lock().device(device)?;
        out(out_backend, format::backend_code(state.adapter.get_info().backend))
    })
}

/// Copies the adapter name as UTF-8 into `buf` (up to `cap` bytes) and
/// writes its full length to `out_len`.
#[no_mangle]
pub extern "C" fn fsw_device_adapter_name(device: u64, buf: *mut u8, cap: usize, out_len: *mut usize) -> i32 {
    guard(|| {
        let state = registry::lock().device(device)?;
        let name = state.adapter.get_info().name;
        let n = name.len().min(cap);
        if n > 0 {
            if buf.is_null() {
                return Err(invalid("null name buffer"));
            }
            unsafe { std::ptr::copy_nonoverlapping(name.as_ptr(), buf, n) };
        }
        out(out_len, name.len())
    })
}

/// Writes the feature bit set (FEATURE_* constants) to `out_features`.
#[no_mangle]
pub extern "C" fn fsw_device_features(device: u64, out_features: *mut u64) -> i32 {
    guard(|| {
        let state = registry::lock().device(device)?;
        let f = state.device.features();
        let downlevel = state.adapter.get_downlevel_capabilities().flags;
        let mut bits = 0;
        let mut set = |on: bool, bit| {
            if on {
                bits |= bit
            }
        };
        set(downlevel.contains(wgpu::DownlevelFlags::COMPUTE_SHADERS), FEATURE_COMPUTE);
        set(downlevel.contains(wgpu::DownlevelFlags::INDIRECT_EXECUTION), FEATURE_INDIRECT_DRAW);
        set(f.contains(wgpu::Features::TEXTURE_BINDING_ARRAY), FEATURE_TEXTURE_BINDING_ARRAY);
        set(f.contains(wgpu::Features::TIMESTAMP_QUERY), FEATURE_TIMESTAMP_QUERY);
        set(f.contains(wgpu::Features::TEXTURE_COMPRESSION_BC), FEATURE_BC);
        set(f.contains(wgpu::Features::TEXTURE_COMPRESSION_ETC2), FEATURE_ETC2);
        set(f.contains(wgpu::Features::TEXTURE_COMPRESSION_ASTC), FEATURE_ASTC);
        set(f.contains(wgpu::Features::TEXTURE_COMPRESSION_ASTC_HDR), FEATURE_ASTC_HDR);
        set(f.contains(wgpu::Features::DEPTH32FLOAT_STENCIL8), FEATURE_DEPTH32_STENCIL8);
        set(f.contains(wgpu::Features::FLOAT32_FILTERABLE), FEATURE_FLOAT32_FILTERABLE);
        set(f.contains(wgpu::Features::INDIRECT_FIRST_INSTANCE), FEATURE_INDIRECT_FIRST_INSTANCE);
        out(out_features, bits)
    })
}

/// Writes up to `count` limits to `out_limits`, in this order:
/// maxTextureDimension2D, maxTextureArrayLayers, maxBindGroups,
/// maxBindingsPerBindGroup, maxUniformBufferBindingSize,
/// maxStorageBufferBindingSize, maxVertexBuffers, maxVertexAttributes,
/// maxVertexBufferArrayStride, maxBufferSize,
/// minUniformBufferOffsetAlignment, minStorageBufferOffsetAlignment,
/// maxColorAttachments, maxSamplersPerShaderStage,
/// maxSampledTexturesPerShaderStage, maxComputeWorkgroupSizeX,
/// maxComputeInvocationsPerWorkgroup, maxTextureDimension3D.
#[no_mangle]
pub extern "C" fn fsw_device_limits(device: u64, out_limits: *mut u64, count: u32) -> i32 {
    guard(|| {
        let state = registry::lock().device(device)?;
        let l = state.device.limits();
        let values = [
            l.max_texture_dimension_2d as u64,
            l.max_texture_array_layers as u64,
            l.max_bind_groups as u64,
            l.max_bindings_per_bind_group as u64,
            l.max_uniform_buffer_binding_size as u64,
            l.max_storage_buffer_binding_size as u64,
            l.max_vertex_buffers as u64,
            l.max_vertex_attributes as u64,
            l.max_vertex_buffer_array_stride as u64,
            l.max_buffer_size,
            l.min_uniform_buffer_offset_alignment as u64,
            l.min_storage_buffer_offset_alignment as u64,
            l.max_color_attachments as u64,
            l.max_samplers_per_shader_stage as u64,
            l.max_sampled_textures_per_shader_stage as u64,
            l.max_compute_workgroup_size_x as u64,
            l.max_compute_invocations_per_workgroup as u64,
            l.max_texture_dimension_3d as u64,
        ];
        let n = (count as usize).min(values.len());
        if n > 0 {
            if out_limits.is_null() {
                return Err(invalid("null limits buffer"));
            }
            unsafe { std::ptr::copy_nonoverlapping(values.as_ptr(), out_limits, n) };
        }
        Ok(())
    })
}

/// Destroys any object. Destroying a device also destroys every object
/// created from it. Pending GPU work that uses the object still completes.
#[no_mangle]
pub extern "C" fn fsw_destroy(handle: u64) -> i32 {
    guard(|| {
        let mut reg = registry::lock();
        let entry = reg.remove(handle)?;
        match entry.object {
            Object::Device(_) => reg.remove_owned_by(handle),
            Object::Buffer(b) => b.buffer.destroy(),
            Object::Texture(t) => t.texture.destroy(),
            _ => {}
        }
        Ok(())
    })
}

// Buffer usage bits for fsw_buffer_create.
const BUFFER_VERTEX: u32 = 1;
const BUFFER_INDEX: u32 = 2;
const BUFFER_UNIFORM: u32 = 4;
const BUFFER_STORAGE: u32 = 8;
const BUFFER_INDIRECT: u32 = 16;

/// Creates a buffer of `size` bytes (rounded up to 4). `usage` combines
/// vertex 1, index 2, uniform 4, storage 8, indirect 16; copies in and out
/// are always allowed.
#[no_mangle]
pub extern "C" fn fsw_buffer_create(device: u64, size: u64, usage: u32, out_buffer: *mut u64) -> i32 {
    guard(|| {
        let mut reg = registry::lock();
        let state = reg.device(device)?;
        let mut usages = wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::COPY_SRC;
        for (bit, u) in [
            (BUFFER_VERTEX, wgpu::BufferUsages::VERTEX),
            (BUFFER_INDEX, wgpu::BufferUsages::INDEX),
            (BUFFER_UNIFORM, wgpu::BufferUsages::UNIFORM),
            (BUFFER_STORAGE, wgpu::BufferUsages::STORAGE),
            (BUFFER_INDIRECT, wgpu::BufferUsages::INDIRECT),
        ] {
            if usage & bit != 0 {
                usages |= u;
            }
        }
        let size = size.max(4).next_multiple_of(4);
        let buffer = scoped(&state.device, || {
            state.device.create_buffer(&wgpu::BufferDescriptor {
                label: None,
                size,
                usage: usages,
                mapped_at_creation: false,
            })
        })?;
        let handle = reg.insert(device, Object::Buffer(BufferObj { buffer, size }));
        out(out_buffer, handle)
    })
}

/// Writes `len` bytes at `offset`. The write is ordered before the next
/// submit on the device.
#[no_mangle]
pub extern "C" fn fsw_buffer_write(buffer: u64, offset: u64, data: *const u8, len: usize) -> i32 {
    guard(|| {
        let reg = registry::lock();
        let (device, state) = reg.owner(buffer)?;
        let obj = reg.buffer(device, buffer)?;
        let bytes = unsafe { slice(data, len)? };
        if offset % 4 != 0 {
            return Err(invalid("buffer write offset must be a multiple of 4"));
        }
        if offset + (len as u64) > obj.size {
            return Err(invalid(format!(
                "write of {len} bytes at {offset} overruns a {}-byte buffer",
                obj.size
            )));
        }
        scoped(&state.device, || {
            if len % 4 == 0 {
                state.queue.write_buffer(&obj.buffer, offset, bytes);
            } else {
                let mut padded = bytes.to_vec();
                padded.resize(len.next_multiple_of(4), 0);
                state.queue.write_buffer(&obj.buffer, offset, &padded);
            }
        })
    })
}

// Texture usage bits for fsw_texture_create.
const TEXTURE_SHADER_READ: u32 = 1;
const TEXTURE_SHADER_WRITE: u32 = 2;
const TEXTURE_RENDER_TARGET: u32 = 4;

/// Creates a texture. `texture_type` and `pixel_format` are flutter_gpu
/// ordinals; `usage` combines shader read 1, shader write 2, render target
/// 4. Single-sampled textures also allow copies in and out; textures with
/// more than one mip level also get render-target use when the format is
/// renderable, for mipmap generation.
#[no_mangle]
pub extern "C" fn fsw_texture_create(
    device: u64,
    texture_type: u32,
    pixel_format: u32,
    width: u32,
    height: u32,
    mip_levels: u32,
    sample_count: u32,
    usage: u32,
    out_texture: *mut u64,
) -> i32 {
    guard(|| {
        let mut reg = registry::lock();
        let state = reg.device(device)?;
        let kind = format::texture_kind(texture_type)?;
        let format = format::pixel_format(pixel_format)?;
        let sample_count = sample_count.max(1);
        let layers = if kind == format::TextureKind::Cube { 6 } else { 1 };
        let mut usages = wgpu::TextureUsages::empty();
        if usage & TEXTURE_SHADER_READ != 0 {
            usages |= wgpu::TextureUsages::TEXTURE_BINDING;
        }
        if usage & TEXTURE_SHADER_WRITE != 0 {
            usages |= wgpu::TextureUsages::STORAGE_BINDING;
        }
        if usage & TEXTURE_RENDER_TARGET != 0 {
            usages |= wgpu::TextureUsages::RENDER_ATTACHMENT;
        }
        if sample_count == 1 {
            usages |= wgpu::TextureUsages::COPY_SRC | wgpu::TextureUsages::COPY_DST;
        }
        if mip_levels > 1 {
            let allowed = state.adapter.get_texture_format_features(format).allowed_usages;
            if allowed.contains(wgpu::TextureUsages::RENDER_ATTACHMENT) && !format.is_depth_stencil_format() {
                usages |= wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING;
            }
        }
        let texture = scoped(&state.device, || {
            state.device.create_texture(&wgpu::TextureDescriptor {
                label: None,
                size: wgpu::Extent3d {
                    width,
                    height,
                    depth_or_array_layers: layers,
                },
                mip_level_count: mip_levels.max(1),
                sample_count,
                dimension: wgpu::TextureDimension::D2,
                format,
                usage: usages,
                view_formats: &[],
            })
        })?;
        let handle = reg.insert(device, Object::Texture(TextureObj { texture, kind }));
        out(out_texture, handle)
    })
}

/// Writes tightly or `bytes_per_row`-strided texel data into one mip level
/// and slice of a texture. `bytes_per_row` 0 means tightly packed.
#[no_mangle]
pub extern "C" fn fsw_texture_write(
    texture: u64,
    mip_level: u32,
    slice_index: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    data: *const u8,
    len: usize,
    bytes_per_row: u32,
) -> i32 {
    guard(|| {
        let reg = registry::lock();
        let (device, state) = reg.owner(texture)?;
        let obj = reg.texture(device, texture)?;
        let bytes = unsafe { slice(data, len)? };
        let format = obj.texture.format();
        let (bw, bh) = format.block_dimensions();
        let block_size = format
            .block_copy_size(None)
            .ok_or_else(|| unsupported("texture writes of combined depth/stencil formats"))?;
        let row = if bytes_per_row != 0 {
            bytes_per_row
        } else {
            width.div_ceil(bw) * block_size
        };
        let rows = height.div_ceil(bh);
        if (len as u64) < row as u64 * rows as u64 {
            return Err(invalid(format!("texture write needs {} bytes, got {len}", row * rows)));
        }
        scoped(&state.device, || {
            state.queue.write_texture(
                wgpu::TexelCopyTextureInfo {
                    texture: &obj.texture,
                    mip_level,
                    origin: wgpu::Origin3d { x, y, z: slice_index },
                    aspect: wgpu::TextureAspect::All,
                },
                bytes,
                wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(row),
                    rows_per_image: Some(rows),
                },
                wgpu::Extent3d {
                    width,
                    height,
                    depth_or_array_layers: 1,
                },
            )
        })
    })
}

/// Reads a region of one mip level and slice back into `dst`, tightly
/// packed, after all submitted work completes. Blocks the calling thread.
#[no_mangle]
pub extern "C" fn fsw_texture_read(
    texture: u64,
    mip_level: u32,
    slice_index: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    dst: *mut u8,
    dst_len: usize,
) -> i32 {
    guard(|| {
        let (state, tex) = {
            let reg = registry::lock();
            let (device, state) = reg.owner(texture)?;
            (state, reg.texture(device, texture)?.texture.clone())
        };
        let format = tex.format();
        if format.block_dimensions() != (1, 1) {
            return Err(unsupported("readback of block-compressed textures"));
        }
        let aspect = if format.is_combined_depth_stencil_format() {
            wgpu::TextureAspect::DepthOnly
        } else {
            wgpu::TextureAspect::All
        };
        let bpp = format
            .block_copy_size(Some(aspect))
            .ok_or_else(|| unsupported(format!("readback of {format:?}")))?;
        let tight = width * bpp;
        let padded = tight.next_multiple_of(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT);
        let needed = tight as usize * height as usize;
        if dst.is_null() || dst_len < needed {
            return Err(invalid(format!("readback needs a {needed}-byte destination")));
        }
        let device = &state.device;
        let staging = scoped(device, || {
            let staging = device.create_buffer(&wgpu::BufferDescriptor {
                label: None,
                size: padded as u64 * height as u64,
                usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                mapped_at_creation: false,
            });
            let mut encoder = device.create_command_encoder(&Default::default());
            encoder.copy_texture_to_buffer(
                wgpu::TexelCopyTextureInfo {
                    texture: &tex,
                    mip_level,
                    origin: wgpu::Origin3d { x, y, z: slice_index },
                    aspect: wgpu::TextureAspect::All,
                },
                wgpu::TexelCopyBufferInfo {
                    buffer: &staging,
                    layout: wgpu::TexelCopyBufferLayout {
                        offset: 0,
                        bytes_per_row: Some(padded),
                        rows_per_image: Some(height),
                    },
                },
                wgpu::Extent3d {
                    width,
                    height,
                    depth_or_array_layers: 1,
                },
            );
            state.queue.submit([encoder.finish()]);
            staging
        })?;
        let mapped = Arc::new(Mutex::new(None));
        let slot = mapped.clone();
        staging.slice(..).map_async(wgpu::MapMode::Read, move |result| {
            *slot.lock().unwrap() = Some(result);
        });
        device
            .poll(wgpu::PollType::wait_indefinitely())
            .map_err(|e| FswError::new(Code::Internal, e.to_string()))?;
        match mapped.lock().unwrap().take() {
            Some(Ok(())) => {}
            Some(Err(e)) => return Err(FswError::new(Code::Validation, e.to_string())),
            None => return Err(FswError::new(Code::Internal, "readback map did not complete")),
        }
        {
            let view = staging
                .slice(..)
                .get_mapped_range()
                .map_err(|e| FswError::new(Code::Internal, e.to_string()))?;
            for row in 0..height as usize {
                let src = &view[row * padded as usize..][..tight as usize];
                unsafe {
                    std::ptr::copy_nonoverlapping(src.as_ptr(), dst.add(row * tight as usize), tight as usize)
                };
            }
        }
        staging.unmap();
        Ok(())
    })
}

/// Creates a sampler. Filters and address modes are flutter_gpu ordinals;
/// `compare` is 0 for none or a flutter_gpu CompareFunction ordinal plus 1.
#[no_mangle]
pub extern "C" fn fsw_sampler_create(
    device: u64,
    min_filter: u32,
    mag_filter: u32,
    mip_filter: u32,
    address_u: u32,
    address_v: u32,
    address_w: u32,
    lod_min: f32,
    lod_max: f32,
    compare: u32,
    max_anisotropy: u32,
    out_sampler: *mut u64,
) -> i32 {
    guard(|| {
        let mut reg = registry::lock();
        let state = reg.device(device)?;
        let desc = wgpu::SamplerDescriptor {
            label: None,
            address_mode_u: format::address(address_u)?,
            address_mode_v: format::address(address_v)?,
            address_mode_w: format::address(address_w)?,
            mag_filter: format::filter(mag_filter)?,
            min_filter: format::filter(min_filter)?,
            mipmap_filter: format::mip_filter(mip_filter)?,
            lod_min_clamp: lod_min,
            lod_max_clamp: lod_max,
            compare: if compare == 0 { None } else { Some(format::compare(compare - 1)?) },
            anisotropy_clamp: max_anisotropy.clamp(1, 16) as u16,
            border_color: None,
        };
        let sampler = scoped(&state.device, || state.device.create_sampler(&desc))?;
        let handle = reg.insert(device, Object::Sampler(sampler));
        out(out_sampler, handle)
    })
}

fn create_shader(device: u64, module: Result<naga::Module>, out_shader: *mut u64) -> Result<()> {
    let module = module?;
    let resources = reflect::resources(&module)?;
    let mut reg = registry::lock();
    let state = reg.device(device)?;
    let shader = scoped(&state.device, || {
        state.device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: None,
            source: wgpu::ShaderSource::Naga(std::borrow::Cow::Owned(module)),
        })
    })
    .map_err(|e| FswError::new(Code::ShaderCompile, e.message))?;
    let handle = reg.insert(device, Object::Shader(ShaderObj { module: shader, resources }));
    out(out_shader, handle)
}

/// Creates a shader module from WGSL source (UTF-8, not NUL-terminated).
#[no_mangle]
pub extern "C" fn fsw_shader_create_wgsl(device: u64, source: *const u8, len: usize, out_shader: *mut u64) -> i32 {
    guard(|| {
        let bytes = unsafe { slice(source, len)? };
        let text = std::str::from_utf8(bytes).map_err(|_| invalid("WGSL source is not UTF-8"))?;
        let module = naga::front::wgsl::parse_str(text)
            .map_err(|e| FswError::new(Code::ShaderCompile, e.emit_to_string(text)));
        create_shader(device, module, out_shader)
    })
}

/// Creates a shader module from SPIR-V bytes.
#[no_mangle]
pub extern "C" fn fsw_shader_create_spirv(device: u64, words: *const u8, len: usize, out_shader: *mut u64) -> i32 {
    guard(|| {
        let bytes = unsafe { slice(words, len)? };
        let split = spirv_split::split(bytes)?;
        let options = naga::front::spv::Options {
            adjust_coordinate_space: false,
            strict_capabilities: false,
            block_ctx_dump_prefix: None,
        };
        let module = naga::front::spv::parse_u8_slice(&split, &options)
            .map_err(|e| FswError::new(Code::ShaderCompile, e.to_string()));
        create_shader(device, module, out_shader)
    })
}

/// Creates a render pipeline from a packed descriptor ([`pipeline`]) and
/// compiles it before returning.
#[no_mangle]
pub extern "C" fn fsw_pipeline_create(device: u64, desc: *const u8, len: usize, out_pipeline: *mut u64) -> i32 {
    guard(|| {
        let bytes = unsafe { slice(desc, len)? };
        let prepared = pipeline::prepare(&registry::lock(), device, bytes)?;
        let slot = prepared.compile_now();
        slot.status()?;
        let handle = registry::lock().insert(device, Object::Pipeline(Arc::new(slot)));
        out(out_pipeline, handle)
    })
}

/// Creates a render pipeline and compiles it on a worker thread. The handle
/// is returned at once; `fsw_pipeline_status` reports readiness. Descriptor
/// and reflection errors are reported here, compile errors by the status.
#[no_mangle]
pub extern "C" fn fsw_pipeline_create_async(device: u64, desc: *const u8, len: usize, out_pipeline: *mut u64) -> i32 {
    guard(|| {
        let bytes = unsafe { slice(desc, len)? };
        let mut reg = registry::lock();
        let prepared = pipeline::prepare(&reg, device, bytes)?;
        let handle = reg.insert(device, Object::Pipeline(prepared.compile_async()));
        out(out_pipeline, handle)
    })
}

/// 0 when the pipeline is built, 5 (not ready) while it compiles, or the
/// compile error's code and message once it failed.
#[no_mangle]
pub extern "C" fn fsw_pipeline_status(pipeline: u64) -> i32 {
    guard(|| registry::lock().pipeline(0, pipeline)?.status().map(|_| ()))
}

/// Blocks until the pipeline's compile finishes; returns as
/// `fsw_pipeline_status` would then.
#[no_mangle]
pub extern "C" fn fsw_pipeline_wait(pipeline: u64) -> i32 {
    guard(|| {
        let slot = registry::lock().pipeline(0, pipeline)?;
        slot.wait().map(|_| ())
    })
}

/// Decodes a packed command stream ([`commands`]) into one command buffer
/// and submits it. Binding a pipeline that is not built fails with code 5.
#[no_mangle]
pub extern "C" fn fsw_submit(device: u64, stream: *const u8, len: usize) -> i32 {
    guard(|| {
        let bytes = unsafe { slice(stream, len)? };
        commands::submit(&registry::lock(), device, bytes)
    })
}

/// Blocks until all work submitted to the device has completed.
#[no_mangle]
pub extern "C" fn fsw_device_wait_idle(device: u64) -> i32 {
    guard(|| {
        let state = registry::lock().device(device)?;
        state
            .device
            .poll(wgpu::PollType::wait_indefinitely())
            .map(|_| ())
            .map_err(|e| FswError::new(Code::Internal, e.to_string()))
    })
}
