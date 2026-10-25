//! Splits each combined image sampler of a SPIR-V module into a separate image
//! and sampler, which naga's spv-in requires.
//!
//! For every `UniformConstant` variable of `OpTypeSampledImage` type the
//! variable is retyped to the image, a sampler variable is added in the same
//! descriptor set at binding + `sampler_offset`, and every
//! `%r = OpLoad %combined %var` becomes
//! `%i = OpLoad %image %var; %s = OpLoad %sampler %svar;
//! %r = OpSampledImage %combined %i %s`. Any other use of such a variable
//! (an access chain into an array, a function parameter) is refused, since
//! impellerc's optimized output has none.

use std::collections::BTreeMap;

const OP_DECORATE: u32 = 71;
const OP_TYPE_SAMPLER: u32 = 26;
const OP_TYPE_SAMPLED_IMAGE: u32 = 27;
const OP_TYPE_POINTER: u32 = 32;
const OP_VARIABLE: u32 = 59;
const OP_LOAD: u32 = 61;
const OP_SAMPLED_IMAGE: u32 = 86;
const OP_NAME: u32 = 5;
const OP_FUNCTION: u32 = 54;
const DECORATION_BINDING: u32 = 33;
const DECORATION_DESCRIPTOR_SET: u32 = 34;
const UNIFORM_CONSTANT: u32 = 0;

fn inst(op: u32, operands: &[u32]) -> Vec<u32> {
    let mut v = vec![((operands.len() as u32 + 1) << 16) | op];
    v.extend_from_slice(operands);
    v
}

pub fn split(bytes: &[u8], sampler_offset: u32) -> Result<Vec<u8>, String> {
    if bytes.len() % 4 != 0 || bytes.len() < 20 {
        return Err("not SPIR-V".into());
    }
    let words: Vec<u32> = bytes.chunks_exact(4).map(|c| u32::from_le_bytes(c.try_into().unwrap())).collect();
    if words[0] != 0x0723_0203 {
        return Err("not little-endian SPIR-V".into());
    }
    let mut header = words[..5].to_vec();
    let mut insts: Vec<Vec<u32>> = Vec::new();
    let mut at = 5;
    while at < words.len() {
        let count = (words[at] >> 16) as usize;
        if count == 0 || at + count > words.len() {
            return Err(format!("malformed instruction at word {at}"));
        }
        insts.push(words[at..at + count].to_vec());
        at += count;
    }
    let op = |i: &Vec<u32>| i[0] & 0xffff;

    let mut sampled_to_image = BTreeMap::new();
    let mut pointers: BTreeMap<(u32, u32), u32> = BTreeMap::new();
    let mut sampler_type = None;
    for i in &insts {
        match op(i) {
            OP_TYPE_SAMPLED_IMAGE => {
                sampled_to_image.insert(i[1], i[2]);
            }
            OP_TYPE_POINTER => {
                pointers.insert((i[2], i[3]), i[1]);
            }
            OP_TYPE_SAMPLER => sampler_type = Some(i[1]),
            _ => {}
        }
    }
    let combined_pointers: BTreeMap<u32, u32> = pointers
        .iter()
        .filter(|((storage, pointee), _)| *storage == UNIFORM_CONSTANT && sampled_to_image.contains_key(pointee))
        .map(|((_, pointee), id)| (*id, *pointee))
        .collect();
    let mut combined_vars: BTreeMap<u32, u32> = BTreeMap::new();
    for i in &insts {
        if op(i) == OP_VARIABLE && combined_pointers.contains_key(&i[1]) {
            combined_vars.insert(i[2], combined_pointers[&i[1]]);
        }
    }
    if combined_vars.is_empty() {
        return Ok(bytes.to_vec());
    }

    let mut bound = header[3];
    let mut fresh = || {
        let id = bound;
        bound += 1;
        id
    };
    let mut new_types = Vec::new();
    let sampler_type = sampler_type.unwrap_or_else(|| {
        let id = fresh();
        new_types.push(inst(OP_TYPE_SAMPLER, &[id]));
        id
    });
    let sampler_pointer = match pointers.get(&(UNIFORM_CONSTANT, sampler_type)) {
        Some(id) => *id,
        None => {
            let id = fresh();
            new_types.push(inst(OP_TYPE_POINTER, &[id, UNIFORM_CONSTANT, sampler_type]));
            id
        }
    };
    let mut image_pointers = BTreeMap::new();
    for &image in sampled_to_image.values() {
        if image_pointers.contains_key(&image) {
            continue;
        }
        let id = match pointers.get(&(UNIFORM_CONSTANT, image)) {
            Some(id) => *id,
            None => {
                let id = fresh();
                new_types.push(inst(OP_TYPE_POINTER, &[id, UNIFORM_CONSTANT, image]));
                id
            }
        };
        image_pointers.insert(image, id);
    }
    let sampler_vars: BTreeMap<u32, u32> = combined_vars.keys().map(|&v| (v, fresh())).collect();

    // Opcodes that could carry the variable somewhere a plain load split
    // cannot follow. Scanning every operand word instead would misread
    // literals (a capability, a member index) that equal the variable's id.
    const POINTER_USES: [u32; 9] = [57, 62, 63, 65, 66, 67, 83, 169, 245];
    let mut out: Vec<Vec<u32>> = Vec::new();
    let mut types_placed = false;
    for i in &insts {
        let code = op(i);
        if POINTER_USES.contains(&code) && i[1..].iter().any(|w| combined_vars.contains_key(w)) {
            return Err(format!("combined sampler used by opcode {code}"));
        }
        match code {
            OP_VARIABLE if combined_vars.contains_key(&i[2]) => {
                if !types_placed {
                    out.append(&mut new_types);
                    types_placed = true;
                }
                let image = sampled_to_image[&combined_vars[&i[2]]];
                out.push(inst(OP_VARIABLE, &[image_pointers[&image], i[2], UNIFORM_CONSTANT]));
                out.push(inst(OP_VARIABLE, &[sampler_pointer, sampler_vars[&i[2]], UNIFORM_CONSTANT]));
            }
            OP_DECORATE if combined_vars.contains_key(&i[1]) => {
                out.push(i.clone());
                let sampler = sampler_vars[&i[1]];
                match i[2] {
                    DECORATION_BINDING => out.push(inst(OP_DECORATE, &[sampler, DECORATION_BINDING, i[3] + sampler_offset])),
                    DECORATION_DESCRIPTOR_SET => out.push(inst(OP_DECORATE, &[sampler, DECORATION_DESCRIPTOR_SET, i[3]])),
                    _ => {}
                }
            }
            OP_LOAD if combined_vars.contains_key(&i[3]) => {
                let combined = i[1];
                let image = sampled_to_image
                    .get(&combined)
                    .copied()
                    .ok_or("load of a combined sampler with another type")?;
                let (img, smp) = (fresh(), fresh());
                out.push(inst(OP_LOAD, &[image, img, i[3]]));
                out.push(inst(OP_LOAD, &[sampler_type, smp, sampler_vars[&i[3]]]));
                out.push(inst(OP_SAMPLED_IMAGE, &[combined, i[2], img, smp]));
            }
            OP_FUNCTION if !types_placed => {
                out.append(&mut new_types);
                types_placed = true;
                out.push(i.clone());
            }
            _ => out.push(i.clone()),
        }
    }
    header[3] = bound;
    Ok(header.into_iter().chain(out.into_iter().flatten()).flat_map(u32::to_le_bytes).collect())
}
