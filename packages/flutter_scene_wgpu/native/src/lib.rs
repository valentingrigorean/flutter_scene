//! Native side of flutter_scene_wgpu: wgpu behind a synchronous,
//! handle-based C ABI that the Dart FFI bindings call.

mod present;

/// Returns the ABI version the Dart bindings check at load.
#[no_mangle]
pub extern "C" fn fsw_abi_version() -> u32 {
    1
}
