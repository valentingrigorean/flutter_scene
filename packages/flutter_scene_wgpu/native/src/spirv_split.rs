//! Splits every combined image sampler in a SPIR-V module into a separate
//! image and sampler, which naga's SPIR-V frontend needs.
//!
//! impellerc's Vulkan SPIR-V declares each GLSL `sampler2D` as one
//! `UniformConstant` variable of `OpTypeSampledImage`. Here that variable
//! becomes an image of the same binding, and a new sampler variable sits in
//! the same descriptor set at the binding plus [`SAMPLER_BINDING_OFFSET`].
//! Each load of the combined variable becomes a load of both and an
//! `OpSampledImage`, keeping the original result id, so every use of it is
//! unchanged.

use std::collections::{HashMap, HashSet};

use crate::error::{invalid, unsupported, Result};

/// Where a split sampler binds relative to its image. impellerc numbers
/// vertex resources from 0 and fragment resources from 64, so `+ 128` lands
/// on no other resource.
pub const SAMPLER_BINDING_OFFSET: u32 = 128;

const OP_ENTRY_POINT: u32 = 15;
const OP_TYPE_SAMPLER: u32 = 26;
const OP_TYPE_SAMPLED_IMAGE: u32 = 27;
const OP_TYPE_POINTER: u32 = 32;
const OP_FUNCTION: u32 = 54;
const OP_FUNCTION_PARAMETER: u32 = 55;
const OP_VARIABLE: u32 = 59;
const OP_LOAD: u32 = 61;
const OP_DECORATE: u32 = 71;
const OP_SAMPLED_IMAGE: u32 = 86;

const DECORATION_BINDING: u32 = 33;
const DECORATION_DESCRIPTOR_SET: u32 = 34;
const STORAGE_UNIFORM_CONSTANT: u32 = 0;

fn op(inst: &[u32]) -> u32 {
    inst[0] & 0xffff
}

fn encode(opcode: u32, operands: &[u32]) -> Vec<u32> {
    let mut inst = Vec::with_capacity(operands.len() + 1);
    inst.push(((operands.len() as u32 + 1) << 16) | opcode);
    inst.extend_from_slice(operands);
    inst
}

/// Returns the module with its combined image samplers split, or the input
/// unchanged when it declares none.
pub fn split(bytes: &[u8]) -> Result<Vec<u8>> {
    if bytes.len() % 4 != 0 || bytes.len() < 20 {
        return Err(invalid("SPIR-V length is not a whole number of words"));
    }
    let words: Vec<u32> = bytes
        .chunks_exact(4)
        .map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();
    if words[0] != 0x0723_0203 {
        return Err(invalid("not little-endian SPIR-V"));
    }
    let version = words[1];
    let mut bound = words[3];
    let mut insts: Vec<Vec<u32>> = Vec::new();
    let mut at = 5;
    while at < words.len() {
        let count = (words[at] >> 16) as usize;
        if count == 0 || at + count > words.len() {
            return Err(invalid("malformed SPIR-V instruction stream"));
        }
        insts.push(words[at..at + count].to_vec());
        at += count;
    }

    let mut sampled_to_image: HashMap<u32, u32> = HashMap::new();
    let mut sampler_type = None;
    // (storage class, pointee) -> pointer type id
    let mut pointers: HashMap<(u32, u32), u32> = HashMap::new();
    let mut combined_pointers: HashMap<u32, u32> = HashMap::new();
    for inst in &insts {
        match op(inst) {
            OP_TYPE_SAMPLED_IMAGE => {
                sampled_to_image.insert(inst[1], inst[2]);
            }
            OP_TYPE_SAMPLER => sampler_type = Some(inst[1]),
            OP_TYPE_POINTER => {
                pointers.insert((inst[2], inst[3]), inst[1]);
                if sampled_to_image.contains_key(&inst[3]) {
                    combined_pointers.insert(inst[1], inst[3]);
                }
            }
            _ => {}
        }
    }
    // variable -> sampled image type
    let mut combined: HashMap<u32, u32> = HashMap::new();
    for inst in &insts {
        if op(inst) == OP_VARIABLE {
            if let Some(&sampled) = combined_pointers.get(&inst[1]) {
                if inst[3] != STORAGE_UNIFORM_CONSTANT {
                    return Err(unsupported("a combined image sampler outside UniformConstant"));
                }
                combined.insert(inst[2], sampled);
            }
        }
        if op(inst) == OP_FUNCTION_PARAMETER && combined_pointers.contains_key(&inst[1]) {
            return Err(unsupported(
                "a combined image sampler passed to a function by pointer",
            ));
        }
    }
    if combined.is_empty() {
        return Ok(bytes.to_vec());
    }

    let mut fresh = || {
        let id = bound;
        bound += 1;
        id
    };
    let mut new_types: Vec<Vec<u32>> = Vec::new();
    let sampler_type = match sampler_type {
        Some(id) => id,
        None => {
            let id = fresh();
            new_types.push(encode(OP_TYPE_SAMPLER, &[id]));
            id
        }
    };
    let sampler_pointer = match pointers.get(&(STORAGE_UNIFORM_CONSTANT, sampler_type)) {
        Some(&id) => id,
        None => {
            let id = fresh();
            new_types.push(encode(OP_TYPE_POINTER, &[id, STORAGE_UNIFORM_CONSTANT, sampler_type]));
            id
        }
    };
    let mut image_pointers: HashMap<u32, u32> = HashMap::new();
    for &sampled in combined.values() {
        let image = sampled_to_image[&sampled];
        if image_pointers.contains_key(&image) {
            continue;
        }
        let id = match pointers.get(&(STORAGE_UNIFORM_CONSTANT, image)) {
            Some(&id) => id,
            None => {
                let id = fresh();
                new_types.push(encode(OP_TYPE_POINTER, &[id, STORAGE_UNIFORM_CONSTANT, image]));
                id
            }
        };
        image_pointers.insert(image, id);
    }
    let mut sampler_vars: HashMap<u32, u32> = HashMap::new();
    let mut ordered: Vec<u32> = combined.keys().copied().collect();
    ordered.sort_unstable();
    for var in ordered {
        sampler_vars.insert(var, fresh());
    }

    let mut out: Vec<Vec<u32>> = Vec::with_capacity(insts.len() + 4 * combined.len());
    let mut types_emitted = false;
    let mut in_function = false;
    for inst in insts {
        let opcode = op(&inst);
        if opcode == OP_FUNCTION {
            in_function = true;
        }
        match opcode {
            OP_ENTRY_POINT if version >= 0x0001_0400 => {
                let mut inst = inst;
                let extra: Vec<u32> = inst
                    .iter()
                    .skip(3)
                    .filter_map(|id| sampler_vars.get(id).copied())
                    .collect();
                inst.extend(extra);
                inst[0] = ((inst.len() as u32) << 16) | OP_ENTRY_POINT;
                out.push(inst);
            }
            OP_DECORATE if sampler_vars.contains_key(&inst[1]) && inst.len() >= 4 => {
                let sampler = sampler_vars[&inst[1]];
                let copy = match inst[2] {
                    DECORATION_BINDING => {
                        Some(encode(OP_DECORATE, &[sampler, DECORATION_BINDING, inst[3] + SAMPLER_BINDING_OFFSET]))
                    }
                    DECORATION_DESCRIPTOR_SET => {
                        Some(encode(OP_DECORATE, &[sampler, DECORATION_DESCRIPTOR_SET, inst[3]]))
                    }
                    _ => None,
                };
                out.push(inst);
                out.extend(copy);
            }
            OP_VARIABLE if !in_function && combined.contains_key(&inst[2]) => {
                if !types_emitted {
                    out.append(&mut new_types);
                    types_emitted = true;
                }
                let var = inst[2];
                let image = sampled_to_image[&combined[&var]];
                let mut rewritten = inst;
                rewritten[1] = image_pointers[&image];
                out.push(rewritten);
                out.push(encode(
                    OP_VARIABLE,
                    &[sampler_pointer, sampler_vars[&var], STORAGE_UNIFORM_CONSTANT],
                ));
            }
            OP_LOAD if combined.contains_key(&inst[3]) => {
                let var = inst[3];
                let sampled = inst[1];
                let result = inst[2];
                let image = sampled_to_image[&sampled];
                let image_value = fresh();
                let sampler_value = fresh();
                out.push(encode(OP_LOAD, &[image, image_value, var]));
                out.push(encode(OP_LOAD, &[sampler_type, sampler_value, sampler_vars[&var]]));
                out.push(encode(OP_SAMPLED_IMAGE, &[sampled, result, image_value, sampler_value]));
            }
            _ => out.push(inst),
        }
    }

    let used: HashSet<u32> = sampler_vars.values().copied().collect();
    debug_assert_eq!(used.len(), combined.len());
    let mut result = Vec::with_capacity(bytes.len() + 64 * combined.len());
    for (i, w) in words[..5].iter().enumerate() {
        let w = if i == 3 { bound } else { *w };
        result.extend_from_slice(&w.to_le_bytes());
    }
    for inst in out {
        for w in inst {
            result.extend_from_slice(&w.to_le_bytes());
        }
    }
    Ok(result)
}
