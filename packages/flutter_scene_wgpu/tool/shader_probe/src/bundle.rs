//! A minimal reader for impellerc's shader bundle flatbuffer
//! (`impeller/shader_bundle/shader_bundle.fbs`, file identifier `IPSB`).

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stage {
    Vertex,
    Fragment,
    Compute,
}

impl Stage {
    pub fn name(self) -> &'static str {
        match self {
            Stage::Vertex => "vertex",
            Stage::Fragment => "fragment",
            Stage::Compute => "compute",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Input {
    pub name: String,
    pub location: u64,
    pub vec_size: u64,
}

#[derive(Debug, Clone)]
pub struct UniformField {
    pub name: String,
    pub offset: u64,
    pub total_size: u64,
    pub array_elements: u64,
}

#[derive(Debug, Clone)]
pub struct UniformStruct {
    pub name: String,
    pub set: u64,
    pub binding: u64,
    pub size: u64,
    pub fields: Vec<UniformField>,
}

#[derive(Debug, Clone)]
pub struct UniformTexture {
    pub name: String,
    pub set: u64,
    pub binding: u64,
}

#[derive(Debug, Clone)]
pub struct BackendShader {
    pub stage: Stage,
    pub entrypoint: String,
    pub inputs: Vec<Input>,
    pub uniform_structs: Vec<UniformStruct>,
    pub uniform_textures: Vec<UniformTexture>,
    pub code: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct Shader {
    pub name: String,
    pub opengl_es: Option<BackendShader>,
    pub vulkan: Option<BackendShader>,
}

struct Buf<'a>(&'a [u8]);

impl<'a> Buf<'a> {
    fn u8(&self, at: usize) -> u8 {
        self.0[at]
    }
    fn u16(&self, at: usize) -> u16 {
        u16::from_le_bytes(self.0[at..at + 2].try_into().unwrap())
    }
    fn u32(&self, at: usize) -> u32 {
        u32::from_le_bytes(self.0[at..at + 4].try_into().unwrap())
    }
    fn i32(&self, at: usize) -> i32 {
        i32::from_le_bytes(self.0[at..at + 4].try_into().unwrap())
    }
    fn u64(&self, at: usize) -> u64 {
        u64::from_le_bytes(self.0[at..at + 8].try_into().unwrap())
    }
    fn deref(&self, at: usize) -> usize {
        at + self.u32(at) as usize
    }
}

#[derive(Clone, Copy)]
struct Table<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Table<'a> {
    fn new(buf: &'a [u8], pos: usize) -> Self {
        Table { buf, pos }
    }
    fn field(&self, index: usize) -> Option<usize> {
        let b = Buf(self.buf);
        let vtable = (self.pos as i64 - b.i32(self.pos) as i64) as usize;
        let size = b.u16(vtable) as usize;
        let slot = 4 + 2 * index;
        if slot >= size {
            return None;
        }
        match b.u16(vtable + slot) {
            0 => None,
            off => Some(self.pos + off as usize),
        }
    }
    fn u64(&self, index: usize) -> u64 {
        self.field(index).map_or(0, |at| Buf(self.buf).u64(at))
    }
    fn u32(&self, index: usize) -> u32 {
        self.field(index).map_or(0, |at| Buf(self.buf).u32(at))
    }
    fn u8(&self, index: usize) -> u8 {
        self.field(index).map_or(0, |at| Buf(self.buf).u8(at))
    }
    fn string(&self, index: usize) -> String {
        String::from_utf8_lossy(self.bytes(index).unwrap_or(&[])).into_owned()
    }
    fn bytes(&self, index: usize) -> Option<&'a [u8]> {
        let b = Buf(self.buf);
        self.field(index).map(|at| {
            let start = b.deref(at);
            let len = b.u32(start) as usize;
            &self.buf[start + 4..start + 4 + len]
        })
    }
    fn table(&self, index: usize) -> Option<Table<'a>> {
        self.field(index)
            .map(|at| Table::new(self.buf, Buf(self.buf).deref(at)))
    }
    fn tables(&self, index: usize) -> Vec<Table<'a>> {
        let b = Buf(self.buf);
        let Some(at) = self.field(index) else {
            return Vec::new();
        };
        let start = b.deref(at);
        (0..b.u32(start) as usize)
            .map(|i| Table::new(self.buf, b.deref(start + 4 + 4 * i)))
            .collect()
    }
}

fn backend(t: Table) -> BackendShader {
    BackendShader {
        stage: match t.u8(0) {
            0 => Stage::Vertex,
            1 => Stage::Fragment,
            _ => Stage::Compute,
        },
        entrypoint: t.string(1),
        inputs: t
            .tables(2)
            .into_iter()
            .map(|i| Input {
                name: i.string(0),
                location: i.u64(1),
                vec_size: i.u64(6),
            })
            .collect(),
        uniform_structs: t
            .tables(3)
            .into_iter()
            .map(|s| UniformStruct {
                name: s.string(0),
                set: s.u64(2),
                binding: s.u64(3),
                size: s.u64(4),
                fields: s
                    .tables(5)
                    .into_iter()
                    .map(|f| UniformField {
                        name: f.string(0),
                        offset: f.u64(2),
                        total_size: f.u64(4),
                        array_elements: f.u64(5),
                    })
                    .collect(),
            })
            .collect(),
        uniform_textures: t
            .tables(4)
            .into_iter()
            .map(|u| UniformTexture {
                name: u.string(0),
                set: u.u64(2),
                binding: u.u64(3),
            })
            .collect(),
        code: t.bytes(5).unwrap_or(&[]).to_vec(),
    }
}

/// Reads every shader of a bundle, keeping the GLES and Vulkan entries.
pub fn read(bytes: &[u8]) -> Result<(u32, Vec<Shader>), String> {
    if bytes.len() < 8 || &bytes[4..8] != b"IPSB" {
        return Err("not a shader bundle (no IPSB identifier)".into());
    }
    let root = Table::new(bytes, Buf(bytes).u32(0) as usize);
    let shaders = root
        .tables(0)
        .into_iter()
        .map(|s| Shader {
            name: s.string(0),
            opengl_es: s.table(3).map(backend),
            vulkan: s.table(5).map(backend),
        })
        .collect();
    Ok((root.u32(1), shaders))
}
