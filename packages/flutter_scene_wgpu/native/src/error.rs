//! Error codes, the thread-local last-error message, and the guard that
//! keeps panics from crossing the C ABI.
//!
//! Every exported function returns an `i32` status: `0` on success, one of
//! the [`Code`] values otherwise. On failure the message is stored per
//! thread and read back with `fsw_last_error_message`.

use std::cell::RefCell;
use std::ffi::{c_char, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

/// Status codes returned by every ABI call. The Dart side mirrors these in
/// `WgpuErrorCode`.
#[repr(i32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Code {
    Ok = 0,
    /// A handle is unknown, destroyed, of the wrong kind, or from another
    /// device.
    InvalidHandle = 1,
    /// An argument is out of range or a packed buffer is malformed.
    InvalidArgument = 2,
    /// wgpu rejected the call (a validation error).
    Validation = 3,
    /// wgpu ran out of memory.
    OutOfMemory = 4,
    /// An asynchronously compiled pipeline is still building.
    NotReady = 5,
    /// The device or this layer does not support the request.
    Unsupported = 6,
    /// A shader failed to parse or validate.
    ShaderCompile = 7,
    /// The native side panicked; the panic was caught at the ABI boundary.
    Panic = 8,
    /// No adapter or device could be created.
    NoAdapter = 9,
    /// An internal wgpu error.
    Internal = 10,
}

/// An error carried back to the ABI boundary.
#[derive(Clone, Debug)]
pub struct FswError {
    pub code: Code,
    pub message: String,
}

impl FswError {
    pub fn new(code: Code, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

pub type Result<T> = std::result::Result<T, FswError>;

/// Shorthand for an [`FswError`] with [`Code::InvalidArgument`].
pub fn invalid(message: impl Into<String>) -> FswError {
    FswError::new(Code::InvalidArgument, message)
}

/// Shorthand for an [`FswError`] with [`Code::Unsupported`].
pub fn unsupported(message: impl Into<String>) -> FswError {
    FswError::new(Code::Unsupported, message)
}

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::default());
}

fn set_last_error(message: &str) {
    let text = CString::new(message.replace('\0', " ")).unwrap_or_default();
    LAST_ERROR.with(|slot| *slot.borrow_mut() = text);
}

/// Runs `body`, converts its error or panic into a status code, and records
/// the message for `fsw_last_error_message`.
pub fn guard(body: impl FnOnce() -> Result<()>) -> i32 {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(())) => Code::Ok as i32,
        Ok(Err(error)) => {
            set_last_error(&error.message);
            error.code as i32
        }
        Err(payload) => {
            let message = payload
                .downcast_ref::<&str>()
                .map(|s| s.to_string())
                .or_else(|| payload.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "unknown panic".to_string());
            set_last_error(&format!("native panic: {message}"));
            Code::Panic as i32
        }
    }
}

/// The message of the last failed call on this thread, as a NUL-terminated
/// UTF-8 string owned by the library. It stays valid until the next failing
/// call on the same thread.
#[no_mangle]
pub extern "C" fn fsw_last_error_message() -> *const c_char {
    LAST_ERROR.with(|slot| slot.borrow().as_ptr())
}

/// Runs `f` inside validation, out-of-memory and internal error scopes on
/// `device` and turns a captured wgpu error into an [`FswError`].
pub fn scoped<T>(device: &wgpu::Device, f: impl FnOnce() -> T) -> Result<T> {
    let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
    let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
    let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
    let value = f();
    let internal = pollster::block_on(internal.pop());
    let memory = pollster::block_on(memory.pop());
    let validation = pollster::block_on(validation.pop());
    if let Some(error) = validation {
        return Err(FswError::new(Code::Validation, error.to_string()));
    }
    if let Some(error) = memory {
        return Err(FswError::new(Code::OutOfMemory, error.to_string()));
    }
    if let Some(error) = internal {
        return Err(FswError::new(Code::Internal, error.to_string()));
    }
    Ok(value)
}
