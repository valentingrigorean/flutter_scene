//! Loads flutter_gpu shader bundles (impellerc output) into naga and a headless
//! wgpu device, one row per shader.
//!
//! ```text
//! cargo run --release -- [--via spirv|wgsl|glsl] [--no-pipeline]
//!     [--unchecked] [--filter <substring>] [--dump <dir>] [label=]<bundle>...
//! ```
//!
//! `--via spirv` (default) parses the bundle's Vulkan SPIR-V with naga's
//! spv-in. `--via spirv-split` first runs `spirv-opt
//! --split-combined-image-sampler` and moves each split sampler to binding +
//! 128. `--via spirv-pass` does the same split with this crate's own
//! `split_pass`, no external tool. `--via wgsl` reads the Tint WGSL sidecar next to the bundle
//! (`<bundle>.wgsl.json`, written when `flutter_scene_webgpu` is on). `--via
//! glsl` parses the bundle's GLES source with naga's glsl-in.
//!
//! Each shader goes through: parse, naga validation, wgpu shader module, a
//! pipeline layout built from the module's resource bindings, a render
//! pipeline (a vertex-only one for a vertex shader, one with a generated
//! pass-through vertex stage for a fragment shader), and a check of the
//! module's bindings against the binding map the bundle reflection predicts.

mod bundle;
mod split_pass;

use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write as _;
use std::panic::{catch_unwind, AssertUnwindSafe};

use bundle::{BackendShader, Stage};

/// Where a combined image sampler's split sampler lands, relative to the
/// texture's bundle binding. Matches `WgslBindingMap.splitSamplerOffset` in
/// flutter_scene's `lib/src/gpu/shared/wgsl_bindings.dart`.
const SPLIT_SAMPLER_OFFSET: u32 = 128;

/// The shader being probed, for errors wgpu reports outside a scope.
static CURRENT: std::sync::Mutex<String> = std::sync::Mutex::new(String::new());

#[derive(Clone, Copy, PartialEq, Eq)]
enum Via {
    Spirv,
    SpirvSplit,
    SpirvPass,
    Wgsl,
    Glsl,
}

struct Options {
    via: Via,
    pipeline: bool,
    unchecked: bool,
    filter: Option<String>,
    dump: Option<std::path::PathBuf>,
    bundles: Vec<String>,
}

struct Failure {
    class: String,
    reason: String,
}

fn fail(class: impl Into<String>, reason: impl Into<String>) -> Failure {
    Failure {
        class: class.into(),
        reason: reason.into().replace('\n', " ").replace('\t', " "),
    }
}

fn parse_args() -> Options {
    let mut options = Options {
        via: Via::Spirv,
        pipeline: true,
        unchecked: false,
        filter: None,
        dump: None,
        bundles: Vec::new(),
    };
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--via" => {
                options.via = match args.next().as_deref() {
                    Some("spirv") => Via::Spirv,
                    Some("spirv-split") => Via::SpirvSplit,
                    Some("spirv-pass") => Via::SpirvPass,
                    Some("wgsl") => Via::Wgsl,
                    Some("glsl") => Via::Glsl,
                    other => panic!("--via takes spirv, spirv-split, spirv-pass, wgsl or glsl, not {other:?}"),
                }
            }
            "--no-pipeline" => options.pipeline = false,
            "--unchecked" => options.unchecked = true,
            "--filter" => options.filter = args.next(),
            "--dump" => options.dump = args.next().map(Into::into),
            _ => options.bundles.push(arg),
        }
    }
    if options.bundles.is_empty() {
        eprintln!("usage: shader_probe [--via spirv|wgsl|glsl] [--no-pipeline] [--unchecked] [--filter s] [--dump dir] <bundle>...");
        std::process::exit(2);
    }
    options
}

fn headless_device() -> (wgpu::Device, String) {
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        force_fallback_adapter: false,
        compatible_surface: None,
        apply_limit_buckets: false,
    }))
    .expect("no wgpu adapter");
    let info = adapter.get_info();
    let (device, _queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some("shader_probe"),
        required_features: adapter.features() & !wgpu::Features::all_experimental_mask(),
        required_limits: adapter.limits(),
        experimental_features: wgpu::ExperimentalFeatures::disabled(),
        memory_hints: wgpu::MemoryHints::Performance,
        trace: wgpu::Trace::Off,
    }))
    .expect("no wgpu device");
    device.on_uncaptured_error(std::sync::Arc::new(|e| {
        let current = CURRENT.lock().map(|c| c.clone()).unwrap_or_default();
        eprintln!("uncaptured while probing {current}: {e}");
    }));
    (device, format!("{} ({:?})", info.name, info.backend))
}

/// The leading enum variant names in an error's `Debug` text, which name its
/// kind more stably than the message does.
fn variant_path(debug: &str) -> String {
    let mut out = Vec::new();
    let chars: Vec<char> = debug.chars().collect();
    let mut i = 0;
    let mut in_str = false;
    while i < chars.len() && out.len() < 3 {
        let c = chars[i];
        if c == '"' {
            in_str = !in_str;
            i += 1;
            continue;
        }
        if in_str || !c.is_ascii_uppercase() || (i > 0 && chars[i - 1].is_alphanumeric()) {
            i += 1;
            continue;
        }
        let start = i;
        while i < chars.len() && (chars[i].is_alphanumeric() || chars[i] == '_') {
            i += 1;
        }
        let ident: String = chars[start..i].iter().collect();
        let mut j = i;
        while j < chars.len() && chars[j] == ' ' {
            j += 1;
        }
        let opens = j < chars.len() && (chars[j] == '(' || chars[j] == '{');
        let skip = matches!(ident.as_str(), "Some" | "Span" | "Handle" | "WithSpan" | "Ok" | "Err");
        if opens && !skip {
            out.push(ident);
        } else if !opens && out.is_empty() && i == chars.len() {
            out.push(ident);
        }
    }
    if out.is_empty() {
        debug.split(|c: char| !c.is_alphanumeric()).next().unwrap_or("").to_string()
    } else {
        out.join("/")
    }
}

fn error_chain(e: &dyn std::error::Error) -> String {
    let mut s = e.to_string();
    let mut source = e.source();
    while let Some(inner) = source {
        let text = inner.to_string();
        if !s.contains(&text) {
            let _ = write!(s, ": {text}");
        }
        source = inner.source();
    }
    s
}

fn guard<T>(class: &str, f: impl FnOnce() -> Result<T, Failure>) -> Result<T, Failure> {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(r) => r,
        Err(panic) => {
            let msg = panic
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_default();
            Err(fail(format!("{class}-panic"), msg))
        }
    }
}

fn naga_stage(stage: Stage) -> naga::ShaderStage {
    match stage {
        Stage::Vertex => naga::ShaderStage::Vertex,
        Stage::Fragment => naga::ShaderStage::Fragment,
        Stage::Compute => naga::ShaderStage::Compute,
    }
}

fn parse(
    via: Via,
    name: &str,
    shader: &BackendShader,
    sidecar: Option<&serde_json::Value>,
) -> Result<naga::Module, Failure> {
    match via {
        Via::Spirv => guard("spv-in", || {
            let options = naga::front::spv::Options {
                adjust_coordinate_space: false,
                strict_capabilities: false,
                block_ctx_dump_prefix: None,
            };
            naga::front::spv::parse_u8_slice(&shader.code, &options)
                .map_err(|e| fail(format!("spv-in:{}", variant_path(&format!("{e:?}"))), e.to_string()))
        }),
        Via::SpirvSplit => guard("spv-in", || {
            let split = split_combined_samplers(&shader.code)?;
            let options = naga::front::spv::Options {
                adjust_coordinate_space: false,
                strict_capabilities: false,
                block_ctx_dump_prefix: None,
            };
            naga::front::spv::parse_u8_slice(&split, &options)
                .map_err(|e| fail(format!("spv-in:{}", variant_path(&format!("{e:?}"))), e.to_string()))
        }),
        Via::SpirvPass => guard("spv-in", || {
            let split = split_pass::split(&shader.code, SPLIT_SAMPLER_OFFSET)
                .map_err(|e| fail("split-pass", e))?;
            let options = naga::front::spv::Options {
                adjust_coordinate_space: false,
                strict_capabilities: false,
                block_ctx_dump_prefix: None,
            };
            naga::front::spv::parse_u8_slice(&split, &options)
                .map_err(|e| fail(format!("spv-in:{}", variant_path(&format!("{e:?}"))), e.to_string()))
        }),
        Via::Glsl => guard("glsl-in", || {
            let source = String::from_utf8_lossy(&shader.code);
            let mut frontend = naga::front::glsl::Frontend::default();
            frontend
                .parse(&naga::front::glsl::Options::from(naga_stage(shader.stage)), &source)
                .map_err(|e| {
                    let first = e.errors.first();
                    let class = first.map_or("unknown".into(), |f| variant_path(&format!("{:?}", f.kind)));
                    fail(format!("glsl-in:{class}"), e.emit_to_string(&source))
                })
        }),
        Via::Wgsl => guard("wgsl-in", || {
            let entry = sidecar
                .and_then(|s| s.get("shaders"))
                .and_then(|s| s.get(name))
                .ok_or_else(|| fail("wgsl-missing", "no sidecar entry"))?;
            let source = entry["wgsl"].as_str().unwrap_or_default();
            naga::front::wgsl::parse_str(source)
                .map_err(|e| fail("wgsl-in", e.emit_to_string(source)))
        }),
    }
}

/// Splits every combined image sampler into an image and a sampler with
/// `spirv-opt --split-combined-image-sampler` (SPIRV-Tools, `SPIRV_OPT` or
/// `spirv-opt` on PATH), then moves each new sampler from its image's binding
/// to binding + 128.
fn split_combined_samplers(code: &[u8]) -> Result<Vec<u8>, Failure> {
    use std::io::Write;
    use std::process::{Command, Stdio};
    let opt = std::env::var("SPIRV_OPT").unwrap_or_else(|_| "spirv-opt".into());
    let mut child = Command::new(&opt)
        .args(["--split-combined-image-sampler", "-", "-o", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| fail("spirv-opt", format!("{opt}: {e}")))?;
    child.stdin.take().unwrap().write_all(code).map_err(|e| fail("spirv-opt", e.to_string()))?;
    let out = child.wait_with_output().map_err(|e| fail("spirv-opt", e.to_string()))?;
    if !out.status.success() {
        return Err(fail("spirv-opt", String::from_utf8_lossy(&out.stderr).into_owned()));
    }
    Ok(rebind_samplers(&out.stdout))
}

fn rebind_samplers(bytes: &[u8]) -> Vec<u8> {
    const OP_TYPE_SAMPLER: u32 = 26;
    const OP_TYPE_POINTER: u32 = 32;
    const OP_VARIABLE: u32 = 59;
    const OP_DECORATE: u32 = 71;
    const BINDING: u32 = 33;
    let mut words: Vec<u32> = bytes.chunks_exact(4).map(|c| u32::from_le_bytes(c.try_into().unwrap())).collect();
    let mut instructions = Vec::new();
    let mut at = 5;
    while at < words.len() {
        let count = (words[at] >> 16) as usize;
        instructions.push((at, words[at] & 0xffff));
        at += count.max(1);
    }
    let mut samplers = BTreeSet::new();
    let mut sampler_pointers = BTreeSet::new();
    let mut sampler_vars = BTreeSet::new();
    for &(at, op) in &instructions {
        match op {
            OP_TYPE_SAMPLER => {
                samplers.insert(words[at + 1]);
            }
            OP_TYPE_POINTER if samplers.contains(&words[at + 3]) => {
                sampler_pointers.insert(words[at + 1]);
            }
            OP_VARIABLE if sampler_pointers.contains(&words[at + 1]) => {
                sampler_vars.insert(words[at + 2]);
            }
            _ => {}
        }
    }
    for &(at, op) in &instructions {
        if op == OP_DECORATE && words[at + 2] == BINDING && sampler_vars.contains(&words[at + 1]) {
            words[at + 3] += SPLIT_SAMPLER_OFFSET;
        }
    }
    words.iter().flat_map(|w| w.to_le_bytes()).collect()
}

fn validate(module: &naga::Module) -> Result<naga::valid::ModuleInfo, Failure> {
    guard("validate", || {
        naga::valid::Validator::new(naga::valid::ValidationFlags::all(), naga::valid::Capabilities::all())
            .validate(module)
            .map_err(|e| {
                fail(
                    format!("validate:{}", variant_path(&format!("{:?}", e.as_inner()))),
                    error_chain(e.as_inner()),
                )
            })
    })
}

fn scoped<T>(device: &wgpu::Device, class: &str, f: impl FnOnce() -> T) -> Result<T, Failure> {
    let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
    let scope = device.push_error_scope(wgpu::ErrorFilter::Validation);
    let value = guard(class, || Ok(f()));
    let error = pollster::block_on(scope.pop()).or(pollster::block_on(internal.pop()));
    let value = value?;
    match error {
        None => Ok(value),
        Some(e) => {
            let text = error_chain(&e);
            let class = match &e {
                wgpu::Error::Validation { source, .. } => {
                    format!("{class}:{}", variant_path(&format!("{source:?}")))
                }
                wgpu::Error::Internal { .. } => format!("{class}:Internal"),
                _ => class.to_string(),
            };
            Err(fail(class, text))
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Kind {
    Uniform,
    Storage,
    Texture,
    Sampler,
}

fn binding_type(module: &naga::Module, var: &naga::GlobalVariable) -> Option<(Kind, wgpu::BindingType)> {
    use naga::{ImageClass, ImageDimension, ScalarKind, TypeInner};
    match var.space {
        naga::AddressSpace::Uniform => Some((
            Kind::Uniform,
            wgpu::BindingType::Buffer {
                ty: wgpu::BufferBindingType::Uniform,
                has_dynamic_offset: false,
                min_binding_size: None,
            },
        )),
        naga::AddressSpace::Storage { access } => Some((
            Kind::Storage,
            wgpu::BindingType::Buffer {
                ty: wgpu::BufferBindingType::Storage {
                    read_only: !access.contains(naga::StorageAccess::STORE),
                },
                has_dynamic_offset: false,
                min_binding_size: None,
            },
        )),
        naga::AddressSpace::Handle => match &module.types[var.ty].inner {
            TypeInner::Sampler { comparison } => Some((
                Kind::Sampler,
                wgpu::BindingType::Sampler(if *comparison {
                    wgpu::SamplerBindingType::Comparison
                } else {
                    wgpu::SamplerBindingType::Filtering
                }),
            )),
            TypeInner::Image { dim, arrayed, class } => {
                let view_dimension = match (dim, arrayed) {
                    (ImageDimension::D1, _) => wgpu::TextureViewDimension::D1,
                    (ImageDimension::D2, false) => wgpu::TextureViewDimension::D2,
                    (ImageDimension::D2, true) => wgpu::TextureViewDimension::D2Array,
                    (ImageDimension::D3, _) => wgpu::TextureViewDimension::D3,
                    (ImageDimension::Cube, false) => wgpu::TextureViewDimension::Cube,
                    (ImageDimension::Cube, true) => wgpu::TextureViewDimension::CubeArray,
                };
                let (sample_type, multisampled) = match class {
                    ImageClass::Sampled { kind, multi } => (
                        match kind {
                            ScalarKind::Sint => wgpu::TextureSampleType::Sint,
                            ScalarKind::Uint => wgpu::TextureSampleType::Uint,
                            _ => wgpu::TextureSampleType::Float { filterable: !multi },
                        },
                        *multi,
                    ),
                    ImageClass::Depth { multi } => (wgpu::TextureSampleType::Depth, *multi),
                    _ => return None,
                };
                Some((
                    Kind::Texture,
                    wgpu::BindingType::Texture {
                        sample_type,
                        view_dimension,
                        multisampled,
                    },
                ))
            }
            _ => None,
        },
        _ => None,
    }
}

/// The module's resources as (group, binding) -> kind, plus the bind group
/// layout entries built from them.
fn module_bindings(
    module: &naga::Module,
    stage: Stage,
) -> (BTreeMap<(u32, u32), Kind>, BTreeMap<u32, Vec<wgpu::BindGroupLayoutEntry>>) {
    let visibility = match stage {
        Stage::Vertex => wgpu::ShaderStages::VERTEX,
        Stage::Fragment => wgpu::ShaderStages::FRAGMENT,
        Stage::Compute => wgpu::ShaderStages::COMPUTE,
    };
    let mut kinds = BTreeMap::new();
    let mut groups: BTreeMap<u32, Vec<wgpu::BindGroupLayoutEntry>> = BTreeMap::new();
    for (_, var) in module.global_variables.iter() {
        let Some(rb) = &var.binding else { continue };
        let Some((kind, ty)) = binding_type(module, var) else { continue };
        kinds.insert((rb.group, rb.binding), kind);
        groups.entry(rb.group).or_default().push(wgpu::BindGroupLayoutEntry {
            binding: rb.binding,
            visibility,
            ty,
            count: None,
        });
    }
    (kinds, groups)
}

/// The bindings the bundle reflection predicts: group 0, a uniform block or a
/// texture at its bundle binding, a texture's sampler at binding + 128.
fn predicted_bindings(shader: &BackendShader) -> BTreeMap<(u32, u32), Kind> {
    let mut out = BTreeMap::new();
    for u in &shader.uniform_structs {
        out.insert((u.set as u32, u.binding as u32), Kind::Uniform);
    }
    for t in &shader.uniform_textures {
        out.insert((t.set as u32, t.binding as u32), Kind::Texture);
        out.insert((t.set as u32, t.binding as u32 + SPLIT_SAMPLER_OFFSET), Kind::Sampler);
    }
    out
}

fn scalar_wgsl(scalar: naga::Scalar) -> Option<&'static str> {
    use naga::ScalarKind::*;
    Some(match (scalar.kind, scalar.width) {
        (Float, 4) => "f32",
        (Float, 2) => "f16",
        (Sint, 4) => "i32",
        (Uint, 4) => "u32",
        _ => return None,
    })
}

fn type_wgsl(module: &naga::Module, ty: naga::Handle<naga::Type>) -> Option<(String, naga::Scalar, u32)> {
    match module.types[ty].inner {
        naga::TypeInner::Scalar(s) => Some((scalar_wgsl(s)?.to_string(), s, 1)),
        naga::TypeInner::Vector { size, scalar } => {
            let n = size as u32;
            Some((format!("vec{n}<{}>", scalar_wgsl(scalar)?), scalar, n))
        }
        _ => None,
    }
}

/// Every `@location` binding of an entry point's arguments or result, struct
/// members included, as (location, type, interpolation).
fn locations(
    module: &naga::Module,
    items: impl Iterator<Item = (Option<naga::Binding>, naga::Handle<naga::Type>)>,
) -> Vec<(u32, naga::Handle<naga::Type>, Option<naga::Interpolation>)> {
    let mut out = Vec::new();
    for (binding, ty) in items {
        match binding {
            Some(naga::Binding::Location { location, interpolation, .. }) => {
                out.push((location, ty, interpolation))
            }
            Some(_) => {}
            None => {
                if let naga::TypeInner::Struct { members, .. } = &module.types[ty].inner {
                    for m in members {
                        if let Some(naga::Binding::Location { location, interpolation, .. }) = m.binding {
                            out.push((location, m.ty, interpolation));
                        }
                    }
                }
            }
        }
    }
    out.sort_by_key(|l| l.0);
    out
}

fn entry_inputs(
    module: &naga::Module,
    ep: &naga::EntryPoint,
) -> Vec<(u32, naga::Handle<naga::Type>, Option<naga::Interpolation>)> {
    locations(module, ep.function.arguments.iter().map(|a| (a.binding.clone(), a.ty)))
}

fn entry_outputs(
    module: &naga::Module,
    ep: &naga::EntryPoint,
) -> Vec<(u32, naga::Handle<naga::Type>, Option<naga::Interpolation>)> {
    locations(module, ep.function.result.iter().map(|r| (r.binding.clone(), r.ty)))
}

/// A vertex shader whose outputs match the fragment entry point's inputs.
fn passthrough_vertex(module: &naga::Module, ep: &naga::EntryPoint) -> Result<String, Failure> {
    let mut fields = String::from("  @builtin(position) position: vec4<f32>,\n");
    let mut assigns = String::new();
    for (location, ty, interpolation) in entry_inputs(module, ep) {
        let (name, scalar, _) =
            type_wgsl(module, ty).ok_or_else(|| fail("stub", format!("fragment input {location} has no WGSL varying type")))?;
        let interp = match interpolation {
            Some(naga::Interpolation::Flat) => " @interpolate(flat)",
            Some(naga::Interpolation::Linear) => " @interpolate(linear)",
            _ if scalar.kind != naga::ScalarKind::Float => " @interpolate(flat)",
            _ => "",
        };
        let _ = writeln!(fields, "  @location({location}){interp} v{location}: {name},");
        let _ = writeln!(assigns, "  o.v{location} = {name}();");
    }
    Ok(format!(
        "struct O {{\n{fields}}}\n@vertex fn main() -> O {{\n  var o: O;\n  o.position = vec4<f32>(0.0, 0.0, 0.0, 1.0);\n{assigns}  return o;\n}}\n"
    ))
}

fn vertex_format(scalar: naga::Scalar, n: u32) -> Option<wgpu::VertexFormat> {
    use naga::ScalarKind::*;
    use wgpu::VertexFormat as F;
    Some(match (scalar.kind, scalar.width, n) {
        (Float, 4, 1) => F::Float32,
        (Float, 4, 2) => F::Float32x2,
        (Float, 4, 3) => F::Float32x3,
        (Float, 4, 4) => F::Float32x4,
        (Sint, 4, 1) => F::Sint32,
        (Sint, 4, 2) => F::Sint32x2,
        (Sint, 4, 3) => F::Sint32x3,
        (Sint, 4, 4) => F::Sint32x4,
        (Uint, 4, 1) => F::Uint32,
        (Uint, 4, 2) => F::Uint32x2,
        (Uint, 4, 3) => F::Uint32x3,
        (Uint, 4, 4) => F::Uint32x4,
        _ => return None,
    })
}

fn color_format(scalar: naga::Scalar, n: u32) -> wgpu::TextureFormat {
    use naga::ScalarKind::*;
    use wgpu::TextureFormat as T;
    match (scalar.kind, n) {
        (Sint, 1) => T::R32Sint,
        (Sint, 2) => T::Rg32Sint,
        (Sint, _) => T::Rgba32Sint,
        (Uint, 1) => T::R32Uint,
        (Uint, 2) => T::Rg32Uint,
        (Uint, _) => T::Rgba32Uint,
        (_, 1) => T::R16Float,
        (_, 2) => T::Rg16Float,
        _ => T::Rgba16Float,
    }
}

fn depth_target() -> wgpu::DepthStencilState {
    wgpu::DepthStencilState {
        format: wgpu::TextureFormat::Depth32Float,
        depth_write_enabled: Some(true),
        depth_compare: Some(wgpu::CompareFunction::Less),
        stencil: Default::default(),
        bias: Default::default(),
    }
}

fn writes_depth(module: &naga::Module, ep: &naga::EntryPoint) -> bool {
    let depth = |b: &Option<naga::Binding>| matches!(b, Some(naga::Binding::BuiltIn(naga::BuiltIn::FragDepth)));
    ep.function.result.as_ref().is_some_and(|r| {
        depth(&r.binding)
            || match &module.types[r.ty].inner {
                naga::TypeInner::Struct { members, .. } => members.iter().any(|m| depth(&m.binding)),
                _ => false,
            }
    })
}

fn build_pipeline(
    device: &wgpu::Device,
    module: &naga::Module,
    shader_module: &wgpu::ShaderModule,
    layout: &wgpu::PipelineLayout,
    stage: Stage,
) -> Result<(), Failure> {
    let ep = module
        .entry_points
        .iter()
        .find(|e| e.stage == naga_stage(stage))
        .ok_or_else(|| fail("no-entry-point", format!("no {} entry point", stage.name())))?;
    match stage {
        Stage::Vertex => {
            let mut attributes = Vec::new();
            for (location, ty, _) in entry_inputs(module, ep) {
                let (_, scalar, n) =
                    type_wgsl(module, ty).ok_or_else(|| fail("stub", format!("vertex input {location} type")))?;
                let format = vertex_format(scalar, n)
                    .ok_or_else(|| fail("stub", format!("vertex input {location} has no vertex format")))?;
                attributes.push([wgpu::VertexAttribute { format, offset: 0, shader_location: location }]);
            }
            let buffers: Vec<_> = attributes
                .iter()
                .map(|a| Some(wgpu::VertexBufferLayout {
                    array_stride: a[0].format.size(),
                    step_mode: wgpu::VertexStepMode::Vertex,
                    attributes: a,
                }))
                .collect();
            scoped(device, "pipeline", || {
                device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                    label: None,
                    layout: Some(layout),
                    vertex: wgpu::VertexState {
                        module: shader_module,
                        entry_point: Some(&ep.name),
                        compilation_options: Default::default(),
                        buffers: &buffers,
                    },
                    primitive: Default::default(),
                    depth_stencil: Some(depth_target()),
                    multisample: Default::default(),
                    fragment: None,
                    multiview_mask: None,
                    cache: None,
                })
            })?;
        }
        Stage::Fragment => {
            let stub_source = passthrough_vertex(module, ep)?;
            let stub = scoped(device, "stub", || {
                device.create_shader_module(wgpu::ShaderModuleDescriptor {
                    label: Some("passthrough"),
                    source: wgpu::ShaderSource::Wgsl(Cow::Owned(stub_source.clone())),
                })
            })
            .map_err(|f| fail(f.class, format!("{} in\n{stub_source}", f.reason)))?;
            let mut targets = Vec::new();
            for (location, ty, _) in entry_outputs(module, ep) {
                let (_, scalar, n) =
                    type_wgsl(module, ty).ok_or_else(|| fail("stub", format!("fragment output {location} type")))?;
                while targets.len() < location as usize {
                    targets.push(None);
                }
                targets.push(Some(wgpu::ColorTargetState {
                    format: color_format(scalar, n),
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                }));
            }
            scoped(device, "pipeline", || {
                device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                    label: None,
                    layout: Some(layout),
                    vertex: wgpu::VertexState {
                        module: &stub,
                        entry_point: Some("main"),
                        compilation_options: Default::default(),
                        buffers: &[],
                    },
                    primitive: Default::default(),
                    depth_stencil: writes_depth(module, ep).then(depth_target),
                    multisample: Default::default(),
                    fragment: Some(wgpu::FragmentState {
                        module: shader_module,
                        entry_point: Some(&ep.name),
                        compilation_options: Default::default(),
                        targets: &targets,
                    }),
                    multiview_mask: None,
                    cache: None,
                })
            })?;
        }
        Stage::Compute => {
            scoped(device, "pipeline", || {
                device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                    label: None,
                    layout: Some(layout),
                    module: shader_module,
                    entry_point: Some(&ep.name),
                    compilation_options: Default::default(),
                    cache: None,
                })
            })?;
        }
    }
    Ok(())
}

/// Compares each reflected uniform block's size and member offsets with the
/// module's struct layout, which the backend lays out from the SPIR-V
/// `Offset` decorations. Returns the disagreements.
fn uniform_layout_mismatches(module: &naga::Module, shader: &BackendShader) -> Vec<String> {
    let mut out = Vec::new();
    for u in &shader.uniform_structs {
        let var = module.global_variables.iter().find(|(_, v)| {
            v.binding.as_ref().is_some_and(|b| b.group == u.set as u32 && b.binding == u.binding as u32)
        });
        let Some((_, var)) = var else { continue };
        let naga::TypeInner::Struct { members, span } = &module.types[var.ty].inner else {
            continue;
        };
        // A block wrapping one struct member is laid out through that member.
        let (members, span) = match members.as_slice() {
            [only] if u.fields.len() > 1 => match &module.types[only.ty].inner {
                naga::TypeInner::Struct { members, span } => (members, span),
                _ => (members, span),
            },
            _ => (members, span),
        };
        if (*span as u64) < u.size {
            out.push(format!("{}: span {} < reflected {}", u.name, span, u.size));
        }
        let offsets: BTreeSet<u32> = members.iter().map(|m| m.offset).collect();
        for f in &u.fields {
            if !offsets.contains(&(f.offset as u32)) {
                out.push(format!("{}.{} offset {} not a member offset", u.name, f.name, f.offset));
            }
        }
    }
    out
}

struct Probed {
    note: String,
}

#[allow(clippy::too_many_arguments)]
fn probe(
    device: &wgpu::Device,
    options: &Options,
    name: &str,
    shader: &BackendShader,
    reflection: &BackendShader,
    sidecar: Option<&serde_json::Value>,
) -> Result<Probed, Failure> {
    let module = parse(options.via, name, shader, sidecar)?;
    validate(&module)?;
    let shader_module = scoped(device, "wgpu-module", || {
        let desc = wgpu::ShaderModuleDescriptor {
            label: Some(name),
            source: wgpu::ShaderSource::Naga(Cow::Owned(module.clone())),
        };
        if options.unchecked {
            // SAFETY: drops naga's bounds and loop-termination checks only;
            // a probe never dispatches the shader.
            unsafe { device.create_shader_module_trusted(desc, wgpu::ShaderRuntimeChecks::unchecked()) }
        } else {
            device.create_shader_module(desc)
        }
    })?;
    let (kinds, groups) = module_bindings(&module, reflection.stage);
    let max_group = groups.keys().max().copied();
    let mut bgls = Vec::new();
    if let Some(max) = max_group {
        for g in 0..=max {
            let entries = groups.get(&g).cloned().unwrap_or_default();
            bgls.push(scoped(device, "layout", || {
                device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: None, entries: &entries })
            })?);
        }
    }
    let bgl_refs: Vec<Option<&wgpu::BindGroupLayout>> = bgls.iter().map(Some).collect();
    let layout = scoped(device, "layout", || {
        device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: None,
            bind_group_layouts: &bgl_refs,
            immediate_size: 0,
        })
    })?;
    if options.pipeline {
        build_pipeline(device, &module, &shader_module, &layout, reflection.stage)?;
    }
    let predicted = predicted_bindings(reflection);
    if predicted != kinds {
        let fmt = |m: &BTreeMap<(u32, u32), Kind>| {
            m.iter().map(|((g, b), k)| format!("{g}.{b}:{k:?}")).collect::<Vec<_>>().join(",")
        };
        return Err(fail(
            "binding-map",
            format!("reflection predicts [{}], module has [{}]", fmt(&predicted), fmt(&kinds)),
        ));
    }
    let mismatches = uniform_layout_mismatches(&module, reflection);
    Ok(Probed {
        note: if mismatches.is_empty() {
            String::new()
        } else {
            format!("uniform layout: {}", mismatches.join("; "))
        },
    })
}

fn main() {
    let options = parse_args();
    std::panic::set_hook(Box::new(|_| {}));
    let (device, adapter) = headless_device();
    let via = match options.via {
        Via::Spirv => "spirv",
        Via::SpirvSplit => "spirv-split",
        Via::SpirvPass => "spirv-pass",
        Via::Wgsl => "wgsl",
        Via::Glsl => "glsl",
    };
    println!("# adapter: {adapter}; via: {via}; pipeline: {}", options.pipeline);
    println!("bundle\tshader\tstage\tresult\treason");
    let mut per_bundle: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    let mut per_class: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for arg in &options.bundles {
        // `label=path` names a bundle in the table; a bare path is labelled
        // by its file name.
        let (label, path) = match arg.split_once('=') {
            Some((label, path)) => (label.to_string(), path),
            None => (
                std::path::Path::new(arg).file_name().unwrap().to_string_lossy().into_owned(),
                arg.as_str(),
            ),
        };
        let bytes = std::fs::read(path).unwrap_or_else(|e| panic!("{path}: {e}"));
        let (_, shaders) = bundle::read(&bytes).unwrap_or_else(|e| panic!("{path}: {e}"));
        let sidecar: Option<serde_json::Value> = if options.via == Via::Wgsl {
            std::fs::read_to_string(format!("{path}.wgsl.json"))
                .ok()
                .and_then(|s| serde_json::from_str(&s).ok())
        } else {
            None
        };
        for shader in &shaders {
            if options.filter.as_ref().is_some_and(|f| !shader.name.contains(f.as_str())) {
                continue;
            }
            let Some(vulkan) = &shader.vulkan else {
                println!("{label}\t{}\t-\tskip\tno Vulkan entry (bundle trimmed)", shader.name);
                continue;
            };
            let source = match options.via {
                Via::Glsl => match &shader.opengl_es {
                    Some(s) => s,
                    None => {
                        println!("{label}\t{}\t-\tskip\tno GLES entry", shader.name);
                        continue;
                    }
                },
                _ => vulkan,
            };
            let stage = vulkan.stage.name();
            let counts = per_bundle.entry(label.clone()).or_default();
            counts.0 += 1;
            *CURRENT.lock().unwrap() = format!("{label}:{}", shader.name);
            match probe(&device, &options, &shader.name, source, vulkan, sidecar.as_ref()) {
                Ok(p) => {
                    counts.1 += 1;
                    println!("{label}\t{}\t{stage}\tloads\t{}", shader.name, p.note);
                }
                Err(f) => {
                    let reason: String = f.reason.chars().take(400).collect();
                    println!("{label}\t{}\t{stage}\t{}\t{reason}", shader.name, f.class);
                    per_class.entry(f.class.clone()).or_default().push(format!("{label}:{}", shader.name));
                    if let Some(dir) = &options.dump {
                        let _ = std::fs::create_dir_all(dir);
                        let ext = match options.via {
                            Via::Spirv | Via::SpirvSplit | Via::SpirvPass => "spv",
                            Via::Glsl => if vulkan.stage == Stage::Vertex { "vert" } else { "frag" },
                            Via::Wgsl => "txt",
                        };
                        let _ = std::fs::write(dir.join(format!("{}.{ext}", shader.name)), &source.code);
                    }
                }
            }
        }
    }
    println!();
    println!("# per bundle: loaded / total");
    for (b, (total, ok)) in &per_bundle {
        println!("#   {b}: {ok} / {total}");
    }
    println!("# failure classes");
    for (class, names) in &per_class {
        println!("#   {class}: {}", names.len());
    }
}
