//! A bounds-checked little-endian reader over the packed buffers Dart
//! writes (pipeline descriptors and command streams).

use crate::error::{invalid, Result};

pub struct Reader<'a> {
    data: &'a [u8],
    pub pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    pub fn done(&self) -> bool {
        self.pos >= self.data.len()
    }

    pub fn bytes(&mut self, n: usize) -> Result<&'a [u8]> {
        let end = self.pos.checked_add(n).filter(|&e| e <= self.data.len());
        let end = end.ok_or_else(|| {
            invalid(format!("packed buffer truncated at byte {} (need {n} more)", self.pos))
        })?;
        let slice = &self.data[self.pos..end];
        self.pos = end;
        Ok(slice)
    }

    pub fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_le_bytes(self.bytes(4)?.try_into().unwrap()))
    }

    pub fn i32(&mut self) -> Result<i32> {
        Ok(self.u32()? as i32)
    }

    pub fn f32(&mut self) -> Result<f32> {
        Ok(f32::from_bits(self.u32()?))
    }

    pub fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_le_bytes(self.bytes(8)?.try_into().unwrap()))
    }

    pub fn bool(&mut self) -> Result<bool> {
        Ok(self.u32()? != 0)
    }

    /// A string written as a `u32` byte length, the UTF-8 bytes, and zero
    /// padding to the next multiple of four.
    pub fn string(&mut self) -> Result<String> {
        let len = self.u32()? as usize;
        let bytes = self.bytes(len)?;
        self.bytes((4 - len % 4) % 4)?;
        String::from_utf8(bytes.to_vec()).map_err(|_| invalid("string is not UTF-8"))
    }
}

/// Turns a raw pointer and length from Dart into a slice.
///
/// # Safety
/// `ptr` must point at `len` readable bytes, or `len` must be zero.
pub unsafe fn slice<'a>(ptr: *const u8, len: usize) -> Result<&'a [u8]> {
    if len == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() {
        return Err(invalid("null data pointer with a non-zero length"));
    }
    Ok(std::slice::from_raw_parts(ptr, len))
}
