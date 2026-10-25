//! The global handle table. Every object the ABI hands out is a non-zero
//! `u64` key into one map; `0` is never a valid handle.

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex, MutexGuard};

use crate::error::{Code, FswError, Result};
use crate::format::TextureKind;
use crate::pipeline::PipelineSlot;
use crate::reflect::Resource;

pub struct DeviceState {
    pub adapter: wgpu::Adapter,
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
    pub mipmaps: Mutex<crate::mipmap::MipmapGenerator>,
}

pub struct BufferObj {
    pub buffer: wgpu::Buffer,
    pub size: u64,
}

pub struct TextureObj {
    pub texture: wgpu::Texture,
    pub kind: TextureKind,
}

pub struct ShaderObj {
    pub module: wgpu::ShaderModule,
    pub resources: Vec<Resource>,
}

pub enum Object {
    Device(Arc<DeviceState>),
    Buffer(BufferObj),
    Texture(TextureObj),
    Sampler(wgpu::Sampler),
    Shader(ShaderObj),
    Pipeline(Arc<PipelineSlot>),
}

pub struct Entry {
    pub device: u64,
    pub object: Object,
}

#[derive(Default)]
pub struct Registry {
    next: u64,
    entries: HashMap<u64, Entry>,
}

static REGISTRY: LazyLock<Mutex<Registry>> = LazyLock::new(Default::default);

pub fn lock() -> MutexGuard<'static, Registry> {
    REGISTRY.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn bad(handle: u64, what: &str) -> FswError {
    FswError::new(Code::InvalidHandle, format!("handle {handle} is not a live {what}"))
}

impl Registry {
    pub fn insert(&mut self, device: u64, object: Object) -> u64 {
        self.next += 1;
        let handle = self.next;
        let device = if device == 0 { handle } else { device };
        self.entries.insert(handle, Entry { device, object });
        handle
    }

    pub fn remove(&mut self, handle: u64) -> Result<Entry> {
        self.entries.remove(&handle).ok_or_else(|| bad(handle, "object"))
    }

    /// Removes every object created from `device`.
    pub fn remove_owned_by(&mut self, device: u64) {
        self.entries.retain(|_, entry| entry.device != device);
    }

    pub fn device(&self, handle: u64) -> Result<Arc<DeviceState>> {
        match self.entries.get(&handle) {
            Some(Entry { object: Object::Device(d), .. }) => Ok(d.clone()),
            _ => Err(bad(handle, "device")),
        }
    }

    /// The device state that owns `handle`, with the owning device handle.
    pub fn owner(&self, handle: u64) -> Result<(u64, Arc<DeviceState>)> {
        let entry = self.entries.get(&handle).ok_or_else(|| bad(handle, "object"))?;
        Ok((entry.device, self.device(entry.device)?))
    }

    fn get(&self, device: u64, handle: u64, what: &str) -> Result<&Object> {
        match self.entries.get(&handle) {
            Some(entry) if device == 0 || entry.device == device => Ok(&entry.object),
            _ => Err(bad(handle, what)),
        }
    }

    pub fn buffer(&self, device: u64, handle: u64) -> Result<&BufferObj> {
        match self.get(device, handle, "buffer")? {
            Object::Buffer(b) => Ok(b),
            _ => Err(bad(handle, "buffer")),
        }
    }

    pub fn texture(&self, device: u64, handle: u64) -> Result<&TextureObj> {
        match self.get(device, handle, "texture")? {
            Object::Texture(t) => Ok(t),
            _ => Err(bad(handle, "texture")),
        }
    }

    pub fn sampler(&self, device: u64, handle: u64) -> Result<&wgpu::Sampler> {
        match self.get(device, handle, "sampler")? {
            Object::Sampler(s) => Ok(s),
            _ => Err(bad(handle, "sampler")),
        }
    }

    pub fn shader(&self, device: u64, handle: u64) -> Result<&ShaderObj> {
        match self.get(device, handle, "shader module")? {
            Object::Shader(s) => Ok(s),
            _ => Err(bad(handle, "shader module")),
        }
    }

    pub fn pipeline(&self, device: u64, handle: u64) -> Result<Arc<PipelineSlot>> {
        match self.get(device, handle, "render pipeline")? {
            Object::Pipeline(p) => Ok(p.clone()),
            _ => Err(bad(handle, "render pipeline")),
        }
    }
}
