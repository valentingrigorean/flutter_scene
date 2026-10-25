//! macOS and iOS: render straight into the IOSurfaces behind the
//! platform's CVPixelBuffers, wrapped as MTLTextures through wgpu's Metal
//! HAL, so the Flutter texture reads the same memory with no copy.

use std::ffi::c_void;
use std::ptr::NonNull;
use std::sync::{Arc, Mutex};

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_io_surface::IOSurfaceRef;
use objc2_metal::{
    MTLDevice, MTLPixelFormat, MTLTexture, MTLTextureDescriptor, MTLTextureType, MTLTextureUsage,
};

use super::cube::{CubeRenderer, FswPresentFrame};
use super::device::Gpu;

/// Called on the poll thread when the GPU finished writing buffer `index`
/// of buffer set `generation`.
pub type ReadyFn = extern "C" fn(context: *mut c_void, generation: u32, index: u32);

pub const FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Bgra8Unorm;

pub fn open_gpu() -> Result<Gpu, String> {
    let gpu = Gpu::open(|| {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::METAL,
            ..wgpu::InstanceDescriptor::new_without_display_handle()
        });
        let adapter = pollster::block_on(instance.request_adapter(&Default::default()))
            .map_err(|e| format!("no Metal adapter: {e}"))?;
        Ok((instance, adapter))
    })?;
    if gpu.adapter.get_info().backend != wgpu::Backend::Metal {
        return Err("the shared wgpu device is not on Metal, which IOSurfaces need".into());
    }
    Ok(gpu)
}

#[derive(Default)]
struct Slots {
    in_flight: Vec<bool>,
    // Order in which each buffer last finished; the oldest free one is reused.
    finished_at: Vec<u64>,
    latest: Option<usize>,
    serial: u64,
}

struct Ctx(*mut c_void);
unsafe impl Send for Ctx {}
unsafe impl Sync for Ctx {}

pub struct IoSurfaceTarget {
    views: Vec<wgpu::TextureView>,
    _textures: Vec<wgpu::Texture>,
    slots: Arc<Mutex<Slots>>,
    on_ready: ReadyFn,
    context: Arc<Ctx>,
    generation: u32,
    pub width: u32,
    pub height: u32,
}

impl IoSurfaceTarget {
    /// Wraps `count` IOSurfaces of `width` x `height` BGRA pixels.
    ///
    /// # Safety
    /// Each pointer must be a live IOSurfaceRef that outlives the target.
    pub unsafe fn new(
        gpu: &Gpu,
        surfaces: *const *mut c_void,
        count: u32,
        width: u32,
        height: u32,
        generation: u32,
        on_ready: ReadyFn,
        context: *mut c_void,
    ) -> Result<IoSurfaceTarget, String> {
        if surfaces.is_null() || count < 2 {
            return Err("at least two IOSurfaces are required".into());
        }
        let hal_device = unsafe { gpu.device.as_hal::<wgpu::hal::api::Metal>() }
            .ok_or("the device is not a Metal device")?;
        let mtl_device = hal_device.raw_device().clone();
        drop(hal_device);

        let mut textures = Vec::new();
        let mut views = Vec::new();
        for i in 0..count as usize {
            let surface = unsafe { *surfaces.add(i) } as *mut IOSurfaceRef;
            let surface = NonNull::new(surface).ok_or("null IOSurface")?;
            let raw = unsafe { wrap_iosurface(&mtl_device, surface.as_ref(), width, height) }
                .ok_or("newTextureWithDescriptor:iosurface:plane: returned nil")?;
            let hal_texture = unsafe {
                wgpu::hal::metal::Device::texture_from_raw(
                    raw,
                    FORMAT,
                    MTLTextureType::Type2D,
                    1,
                    1,
                    wgpu::hal::CopyExtent {
                        width,
                        height,
                        depth: 1,
                    },
                    None,
                )
            };
            let texture = unsafe {
                gpu.device.create_texture_from_hal::<wgpu::hal::api::Metal>(
                    hal_texture,
                    &wgpu::TextureDescriptor {
                        label: Some("present iosurface"),
                        size: wgpu::Extent3d {
                            width,
                            height,
                            depth_or_array_layers: 1,
                        },
                        mip_level_count: 1,
                        sample_count: 1,
                        dimension: wgpu::TextureDimension::D2,
                        format: FORMAT,
                        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                        view_formats: &[],
                    },
                    wgpu::TextureUses::UNINITIALIZED,
                )
            };
            views.push(texture.create_view(&Default::default()));
            textures.push(texture);
        }
        let n = views.len();
        Ok(IoSurfaceTarget {
            views,
            _textures: textures,
            slots: Arc::new(Mutex::new(Slots {
                in_flight: vec![false; n],
                finished_at: vec![0; n],
                ..Default::default()
            })),
            on_ready,
            context: Arc::new(Ctx(context)),
            generation,
            width,
            height,
        })
    }

    /// Renders into a free buffer and reports it ready once the GPU is done.
    /// Returns false when every buffer is displayed or still in flight.
    pub fn render(&self, gpu: &Gpu, renderer: &mut CubeRenderer, frame: &FswPresentFrame) -> bool {
        let index = {
            let mut s = self.slots.lock().unwrap();
            let free = (0..self.views.len())
                .filter(|&i| !s.in_flight[i] && s.latest != Some(i))
                .min_by_key(|&i| s.finished_at[i]);
            let Some(i) = free else { return false };
            s.in_flight[i] = true;
            i
        };
        let commands = renderer.encode(
            &gpu.device,
            &gpu.queue,
            &self.views[index],
            self.width,
            self.height,
            frame,
        );
        gpu.queue.submit([commands]);
        let slots = self.slots.clone();
        let context = self.context.clone();
        let on_ready = self.on_ready;
        let generation = self.generation;
        gpu.queue.on_submitted_work_done(move || {
            {
                let mut s = slots.lock().unwrap();
                s.serial += 1;
                s.in_flight[index] = false;
                s.finished_at[index] = s.serial;
                s.latest = Some(index);
            }
            on_ready(context.0, generation, index as u32);
        });
        gpu.poke();
        true
    }
}

unsafe fn wrap_iosurface(
    device: &Retained<ProtocolObject<dyn MTLDevice>>,
    surface: &IOSurfaceRef,
    width: u32,
    height: u32,
) -> Option<Retained<ProtocolObject<dyn MTLTexture>>> {
    let desc = unsafe {
        MTLTextureDescriptor::texture2DDescriptorWithPixelFormat_width_height_mipmapped(
            MTLPixelFormat::BGRA8Unorm,
            width as usize,
            height as usize,
            false,
        )
    };
    desc.setUsage(MTLTextureUsage::RenderTarget | MTLTextureUsage::ShaderRead);
    device.newTextureWithDescriptor_iosurface_plane(&desc, surface, 0)
}
