//! Presentation into a Flutter external texture.
//!
//! A presenter owns a render target the platform plugin handed over
//! (IOSurfaces on macOS and iOS, a SurfaceProducer's window on Android)
//! and draws into it with one synchronous call per frame: the example
//! cube, or any colour texture of the device API's registry. It renders on
//! the process's shared wgpu device, the one the device API hands out.

#[cfg(target_os = "android")]
mod android;
#[cfg(target_vendor = "apple")]
mod apple;
mod blit;
mod cube;
mod device;

use std::collections::HashMap;
use std::ffi::{c_char, c_void, CString};
use std::sync::{LazyLock, Mutex, OnceLock};

use blit::Blitter;
use cube::{CubeRenderer, FswPresentFrame};
use device::Gpu;

static GPU: OnceLock<Gpu> = OnceLock::new();
static STATE: LazyLock<Mutex<State>> = LazyLock::new(Default::default);
static LAST_ERROR: Mutex<Option<CString>> = Mutex::new(None);
static BACKEND: OnceLock<CString> = OnceLock::new();

#[derive(Default)]
struct State {
    next: u64,
    presenters: HashMap<u64, Presenter>,
    #[cfg(target_os = "android")]
    windows: HashMap<i64, android::WindowSlot>,
}

struct Presenter {
    target: Target,
    renderer: Option<CubeRenderer>,
    blitter: Option<Blitter>,
}

enum Target {
    #[cfg(target_vendor = "apple")]
    Apple(apple::IoSurfaceTarget),
    #[cfg(target_os = "android")]
    Android(android::WindowTarget),
}

/// `fsw_present_render` results.
const RENDERED: i32 = 0;
const SKIPPED: i32 = 1;
const NO_SURFACE: i32 = 2;
const FAILED: i32 = -1;

fn fail(message: String) {
    eprintln!("flutter_scene_wgpu present: {message}");
    *LAST_ERROR.lock().unwrap() = CString::new(message).ok();
}

fn gpu_or_open(open: impl FnOnce() -> Result<Gpu, String>) -> Result<&'static Gpu, String> {
    if let Some(gpu) = GPU.get() {
        return Ok(gpu);
    }
    let gpu = open()?;
    let _ = BACKEND.set(CString::new(gpu.backend_name()).unwrap());
    Ok(GPU.get_or_init(|| gpu))
}

fn insert(state: &mut State, presenter: Presenter) -> u64 {
    state.next += 1;
    state.presenters.insert(state.next, presenter);
    state.next
}

/// The last error message, or null. Valid until the next failing call.
#[no_mangle]
pub extern "C" fn fsw_present_last_error() -> *const c_char {
    LAST_ERROR
        .lock()
        .unwrap()
        .as_ref()
        .map_or(std::ptr::null(), |s| s.as_ptr())
}

/// The wgpu backend presenters render with, or null before the first
/// presenter opened the device.
#[no_mangle]
pub extern "C" fn fsw_present_backend() -> *const c_char {
    BACKEND.get().map_or(std::ptr::null(), |s| s.as_ptr())
}

/// Creates a presenter that renders into `count` IOSurfaces (BGRA8,
/// `width` x `height`), calling `on_ready(context, generation, index)` from
/// a background thread once the GPU finished a buffer. Returns 0 on failure.
///
/// # Safety
/// The surfaces and `context` must stay alive until the presenter is
/// disposed or resized onto other surfaces.
#[cfg(target_vendor = "apple")]
#[no_mangle]
pub unsafe extern "C" fn fsw_present_create_apple(
    surfaces: *const *mut c_void,
    count: u32,
    width: u32,
    height: u32,
    generation: u32,
    on_ready: apple::ReadyFn,
    context: *mut c_void,
) -> u64 {
    let result = gpu_or_open(apple::open_gpu).and_then(|gpu| {
        let target = unsafe {
            apple::IoSurfaceTarget::new(
                gpu, surfaces, count, width, height, generation, on_ready, context,
            )
        }?;
        Ok(Presenter {
            target: Target::Apple(target),
            renderer: Some(CubeRenderer::new(&gpu.device, apple::FORMAT)),
            blitter: None,
        })
    });
    match result {
        Ok(p) => insert(&mut STATE.lock().unwrap(), p),
        Err(e) => {
            fail(e);
            0
        }
    }
}

/// Moves an Apple presenter onto a new set of IOSurfaces of the new size.
/// Waits for in-flight frames first, so no callback names the old set
/// after this returns.
///
/// # Safety
/// As for [`fsw_present_create_apple`].
#[cfg(target_vendor = "apple")]
#[no_mangle]
pub unsafe extern "C" fn fsw_present_resize_apple(
    handle: u64,
    surfaces: *const *mut c_void,
    count: u32,
    width: u32,
    height: u32,
    generation: u32,
    on_ready: apple::ReadyFn,
    context: *mut c_void,
) -> i32 {
    let Some(gpu) = GPU.get() else { return FAILED };
    let mut state = STATE.lock().unwrap();
    let Some(p) = state.presenters.get_mut(&handle) else { return FAILED };
    gpu.wait_idle();
    match unsafe {
        apple::IoSurfaceTarget::new(
            gpu, surfaces, count, width, height, generation, on_ready, context,
        )
    } {
        Ok(target) => {
            p.target = Target::Apple(target);
            RENDERED
        }
        Err(e) => {
            fail(e);
            FAILED
        }
    }
}

/// Creates a presenter for the SurfaceProducer registered as `texture_id`,
/// whose window the plugin passed through `WgpuPresentNative.setSurface`.
/// `prefer_gl` != 0 opens the device on GLES instead of Vulkan; it only
/// matters for the first presenter. Returns 0 on failure.
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "C" fn fsw_present_create_android(
    texture_id: i64,
    width: u32,
    height: u32,
    prefer_gl: u32,
) -> u64 {
    let mut state = STATE.lock().unwrap();
    let window = state.windows.get(&texture_id).and_then(|s| s.window.as_ref());
    let opened = match window {
        Some(w) => gpu_or_open(|| android::open_gpu(w, prefer_gl != 0)).map(|_| ()),
        None if GPU.get().is_some() => Ok(()),
        None => Err(format!("no surface was handed over for texture {texture_id}")),
    };
    match opened {
        Ok(()) => insert(
            &mut state,
            Presenter {
                target: Target::Android(android::WindowTarget::new(texture_id, width, height)),
                renderer: None,
                blitter: None,
            },
        ),
        Err(e) => {
            fail(e);
            0
        }
    }
}

/// Resizes an Android presenter; the plugin resizes the producer first.
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "C" fn fsw_present_resize(handle: u64, width: u32, height: u32) -> i32 {
    let mut state = STATE.lock().unwrap();
    match state.presenters.get_mut(&handle) {
        Some(Presenter {
            target: Target::Android(t),
            ..
        }) => {
            t.resize(width, height);
            RENDERED
        }
        _ => FAILED,
    }
}

/// Renders one frame. Returns 0 when a frame was submitted, 1 when it was
/// skipped (no free buffer or the surface was not ready), 2 when there is
/// no surface to render into, and -1 on failure.
///
/// # Safety
/// `frame` must point to a valid `FswPresentFrame`.
#[no_mangle]
pub unsafe extern "C" fn fsw_present_render(handle: u64, frame: *const FswPresentFrame) -> i32 {
    let Some(gpu) = GPU.get() else { return FAILED };
    let Some(frame) = (unsafe { frame.as_ref() }) else { return FAILED };
    let mut state = STATE.lock().unwrap();
    let state = &mut *state;
    let Some(p) = state.presenters.get_mut(&handle) else { return FAILED };
    match &mut p.target {
        #[cfg(target_vendor = "apple")]
        Target::Apple(t) => apple_status(t.render(gpu, p.renderer.as_mut().unwrap(), frame)),
        #[cfg(target_os = "android")]
        Target::Android(t) => {
            let slot = state.windows.get(&t.texture_id);
            android_status(t.render(gpu, &mut p.renderer, slot, frame))
        }
    }
}

#[cfg(target_vendor = "apple")]
fn apple_status(result: Result<bool, String>) -> i32 {
    match result {
        Ok(true) => RENDERED,
        Ok(false) => SKIPPED,
        Err(e) => {
            fail(e);
            FAILED
        }
    }
}

#[cfg(target_os = "android")]
fn android_status(result: Result<android::Rendered, String>) -> i32 {
    match result {
        Ok(android::Rendered::Presented) => RENDERED,
        Ok(android::Rendered::Skipped) => SKIPPED,
        Ok(android::Rendered::NoSurface) => NO_SURFACE,
        Err(e) => {
            fail(e);
            FAILED
        }
    }
}

/// Draws the registry texture `texture` (a single-sampled 2D colour
/// texture the device API created on the shared device: 8-bit, sRGB or
/// float) over the presenter's next free buffer or surface image, scaled
/// to the presenter size, and submits it. An sRGB or float texture holds
/// linear values and is sRGB-encoded; an 8-bit UNorm one is shown as
/// stored. Returns as [`fsw_present_render`] does.
#[no_mangle]
pub extern "C" fn fsw_present_texture(handle: u64, texture: u64) -> i32 {
    let Some(gpu) = GPU.get() else { return FAILED };
    let source = {
        let reg = crate::registry::lock();
        let owned_by_shared = reg.owner(texture).map(|(_, state)| state.device == gpu.device);
        match (reg.texture(0, texture), owned_by_shared) {
            (Ok(t), Ok(true)) => t.texture.clone(),
            (Ok(_), _) => {
                fail(format!("texture {texture} is not on the device presenters render with"));
                return FAILED;
            }
            (Err(e), _) => {
                fail(e.message);
                return FAILED;
            }
        }
    };
    let mut state = STATE.lock().unwrap();
    let state = &mut *state;
    let Some(p) = state.presenters.get_mut(&handle) else { return FAILED };
    let blitter = p.blitter.get_or_insert_with(|| Blitter::new(&gpu.device));
    match &mut p.target {
        #[cfg(target_vendor = "apple")]
        Target::Apple(t) => apple_status(
            t.render_with(gpu, |view, _, _| blitter.encode(&gpu.device, &source, view, apple::FORMAT)),
        ),
        #[cfg(target_os = "android")]
        Target::Android(t) => {
            let slot = state.windows.get(&t.texture_id);
            android_status(t.render_with(gpu, slot, |view, format, _, _| {
                blitter.encode(&gpu.device, &source, view, format)
            }))
        }
    }
}

/// Creates an Apple presenter over `count` IOSurfaces of its own, with no
/// Flutter texture, whose buffers [`fsw_present_read_latest`] reads back.
/// Returns 0 on failure.
#[cfg(target_vendor = "apple")]
#[no_mangle]
pub extern "C" fn fsw_present_create_offscreen(width: u32, height: u32, count: u32) -> u64 {
    let result = gpu_or_open(apple::open_gpu).and_then(|gpu| {
        Ok(Presenter {
            target: Target::Apple(apple::offscreen(gpu, width, height, count)?),
            renderer: Some(CubeRenderer::new(&gpu.device, apple::FORMAT)),
            blitter: None,
        })
    });
    match result {
        Ok(p) => insert(&mut STATE.lock().unwrap(), p),
        Err(e) => {
            fail(e);
            0
        }
    }
}

/// Waits for an offscreen presenter's frames and copies its most recently
/// finished buffer (`width * height * 4` bytes, BGRA) into `out`. Returns
/// the buffer index, or -1 on failure.
///
/// # Safety
/// `out` must point to `len` writable bytes.
#[cfg(target_vendor = "apple")]
#[no_mangle]
pub unsafe extern "C" fn fsw_present_read_latest(handle: u64, out: *mut u8, len: usize) -> i32 {
    let Some(gpu) = GPU.get() else { return FAILED };
    if out.is_null() {
        return FAILED;
    }
    let out = unsafe { std::slice::from_raw_parts_mut(out, len) };
    let state = STATE.lock().unwrap();
    let Some(Presenter { target: Target::Apple(t), .. }) = state.presenters.get(&handle) else { return FAILED };
    match t.read_latest(gpu, out) {
        Ok(index) => index as i32,
        Err(e) => {
            fail(e);
            FAILED
        }
    }
}

/// Disposes a presenter once its in-flight frames finished; after this no
/// ready callback for it fires.
#[no_mangle]
pub extern "C" fn fsw_present_dispose(handle: u64) {
    let removed = STATE.lock().unwrap().presenters.remove(&handle);
    if removed.is_some() {
        if let Some(gpu) = GPU.get() {
            gpu.wait_idle();
        }
    }
}
