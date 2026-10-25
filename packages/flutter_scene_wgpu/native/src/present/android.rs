//! Android: the plugin hands over the SurfaceProducer's Surface through JNI
//! as an ANativeWindow, and the presenter renders into a wgpu surface on it
//! (Vulkan, or GLES when no Vulkan adapter can present to it).

use std::ffi::c_void;
use std::ptr::NonNull;

use raw_window_handle::{
    AndroidDisplayHandle, AndroidNdkWindowHandle, DisplayHandle, HandleError, HasDisplayHandle,
    RawDisplayHandle, RawWindowHandle,
};

use super::cube::{CubeRenderer, FswPresentFrame};
use super::device::Gpu;
use super::STATE;

#[link(name = "android")]
extern "C" {
    fn ANativeWindow_fromSurface(env: *mut c_void, surface: *mut c_void) -> *mut c_void;
    fn ANativeWindow_release(window: *mut c_void);
}

/// An acquired ANativeWindow reference.
pub struct NativeWindow(NonNull<c_void>);
unsafe impl Send for NativeWindow {}

impl Drop for NativeWindow {
    fn drop(&mut self) {
        unsafe { ANativeWindow_release(self.0.as_ptr()) }
    }
}

/// The window the plugin last handed over for a texture, and a counter
/// that changes every time it does.
pub struct WindowSlot {
    pub window: Option<NativeWindow>,
    pub generation: u64,
}

#[derive(Debug)]
struct AndroidDisplay;
impl HasDisplayHandle for AndroidDisplay {
    fn display_handle(&self) -> Result<DisplayHandle<'_>, HandleError> {
        Ok(DisplayHandle::android())
    }
}

/// Called by `WgpuPresentNative.setSurface` with the producer's current
/// Surface, or null when the producer tears it down. On null the
/// presenter drops its wgpu surface before this returns, as the
/// SurfaceProducer cleanup contract requires.
#[no_mangle]
pub extern "C" fn Java_dev_fscene_flutter_1scene_1wgpu_WgpuPresentNative_setSurface(
    env: *mut c_void,
    _class: *mut c_void,
    texture_id: i64,
    surface: *mut c_void,
) {
    let window = if surface.is_null() {
        None
    } else {
        NonNull::new(unsafe { ANativeWindow_fromSurface(env, surface) }).map(NativeWindow)
    };
    let mut state = STATE.lock().unwrap();
    for p in state.presenters.values_mut() {
        if let super::Target::Android(t) = &mut p.target {
            if t.texture_id == texture_id {
                t.surface = None;
            }
        }
    }
    let slot = state.windows.entry(texture_id).or_insert(WindowSlot {
        window: None,
        generation: 0,
    });
    slot.window = window;
    slot.generation += 1;
}

fn create_surface(instance: &wgpu::Instance, window: &NativeWindow) -> Result<wgpu::Surface<'static>, String> {
    unsafe {
        instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::RawHandle {
            raw_display_handle: Some(RawDisplayHandle::Android(AndroidDisplayHandle::new())),
            raw_window_handle: RawWindowHandle::AndroidNdk(AndroidNdkWindowHandle::new(window.0)),
        })
    }
    .map_err(|e| format!("create_surface failed: {e}"))
}

/// Opens the shared device on an adapter that can present to `window`:
/// Vulkan first, then GLES. `prefer_gl` skips Vulkan.
pub fn open_gpu(window: &NativeWindow, prefer_gl: bool) -> Result<Gpu, String> {
    let mut errors = Vec::new();
    let order: &[wgpu::Backends] = if prefer_gl {
        &[wgpu::Backends::GL]
    } else {
        &[wgpu::Backends::VULKAN, wgpu::Backends::GL]
    };
    for &backends in order {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends,
            ..wgpu::InstanceDescriptor::new_with_display_handle(Box::new(AndroidDisplay))
        });
        let surface = match create_surface(&instance, window) {
            Ok(s) => s,
            Err(e) => {
                errors.push(format!("{backends:?}: {e}"));
                continue;
            }
        };
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            compatible_surface: Some(&surface),
            ..Default::default()
        }));
        drop(surface);
        match adapter {
            Ok(adapter) => return Gpu::open(instance, adapter),
            Err(e) => errors.push(format!("{backends:?}: {e}")),
        }
    }
    Err(format!("no adapter can present: {}", errors.join("; ")))
}

pub struct WindowTarget {
    pub texture_id: i64,
    pub surface: Option<(wgpu::Surface<'static>, wgpu::SurfaceConfiguration)>,
    generation: u64,
    pub width: u32,
    pub height: u32,
}

/// The outcome of one Android frame.
pub enum Rendered {
    Presented,
    NoSurface,
    Skipped,
}

impl WindowTarget {
    pub fn new(texture_id: i64, width: u32, height: u32) -> WindowTarget {
        WindowTarget {
            texture_id,
            surface: None,
            generation: 0,
            width,
            height,
        }
    }

    pub fn resize(&mut self, width: u32, height: u32) {
        self.width = width;
        self.height = height;
        self.surface = None;
    }

    pub fn render(
        &mut self,
        gpu: &Gpu,
        renderer: &mut Option<CubeRenderer>,
        slot: Option<&WindowSlot>,
        frame: &FswPresentFrame,
    ) -> Result<Rendered, String> {
        let Some(slot) = slot else { return Ok(Rendered::NoSurface) };
        let Some(window) = &slot.window else { return Ok(Rendered::NoSurface) };
        if self.surface.is_none() || self.generation != slot.generation {
            self.surface = None;
            let surface = create_surface(&gpu.instance, window)?;
            let caps = surface.get_capabilities(&gpu.adapter);
            let format = caps
                .formats
                .iter()
                .copied()
                .find(|f| !f.is_srgb())
                .or(caps.formats.first().copied())
                .ok_or("the surface reports no formats")?;
            let present_mode = if caps.present_modes.contains(&wgpu::PresentMode::Mailbox) {
                wgpu::PresentMode::Mailbox
            } else {
                wgpu::PresentMode::Fifo
            };
            let config = wgpu::SurfaceConfiguration {
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                format,
                width: self.width,
                height: self.height,
                present_mode,
                desired_maximum_frame_latency: 2,
                alpha_mode: caps.alpha_modes[0],
                view_formats: vec![],
                color_space: Default::default(),
            };
            surface.configure(&gpu.device, &config);
            eprintln!("flutter_scene_wgpu present: surface {format:?} {present_mode:?} {}x{}", self.width, self.height);
            if renderer.as_ref().map(|r| r.format()) != Some(format) {
                *renderer = Some(CubeRenderer::new(&gpu.device, format));
            }
            self.surface = Some((surface, config));
            self.generation = slot.generation;
        }
        let (surface, config) = self.surface.as_ref().unwrap();
        let texture = match surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(t) | wgpu::CurrentSurfaceTexture::Suboptimal(t) => t,
            wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                surface.configure(&gpu.device, config);
                return Ok(Rendered::Skipped);
            }
            _ => return Ok(Rendered::Skipped),
        };
        let view = texture.texture.create_view(&Default::default());
        let commands = renderer.as_mut().unwrap().encode(
            &gpu.device,
            &gpu.queue,
            &view,
            self.width,
            self.height,
            frame,
        );
        gpu.queue.submit([commands]);
        gpu.queue.present(texture);
        Ok(Rendered::Presented)
    }
}
