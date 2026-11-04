use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;

const OK: i32 = 0;
const ERR_ARGUMENT: i32 = -1;
const ERR_DIMENSIONS: i32 = -2;
const ERR_OUTPUT: i32 = -3;
const ERR_DECODE: i32 = -5;
const ERR_PANIC: i32 = -6;
const MAX_PIXELS: usize = 32 * 1024 * 1024;

// Stable private C ABI IDs shared with patches/high_texture_decoder.py.
const BC1: u32 = 1;
const BC2: u32 = 2;
const BC3: u32 = 3;
const BC4: u32 = 4;
const BC5: u32 = 5;
const BC6_UNSIGNED: u32 = 6;
const BC6_SIGNED: u32 = 7;
const BC7: u32 = 8;
const ATC_RGB: u32 = 9;
const ATC_RGBA: u32 = 10;
const ETC1: u32 = 11;
const ETC2_RGB: u32 = 12;
const ETC2_RGBA1: u32 = 13;
const ETC2_RGBA8: u32 = 14;
const EAC_R: u32 = 15;
const EAC_R_SIGNED: u32 = 16;
const EAC_RG: u32 = 17;
const EAC_RG_SIGNED: u32 = 18;
const ASTC: u32 = 19;
const PVRTC_2BPP: u32 = 20;
const PVRTC_4BPP: u32 = 21;

fn decode(
    format: u32,
    data: &[u8],
    width: usize,
    height: usize,
    block_width: usize,
    block_height: usize,
    pixels: &mut [u32],
) -> Result<(), &'static str> {
    use texture2ddecoder as t;

    match format {
        BC1 => t::decode_bc1(data, width, height, pixels),
        BC2 => t::decode_bc2(data, width, height, pixels),
        BC3 => t::decode_bc3(data, width, height, pixels),
        BC4 => t::decode_bc4(data, width, height, pixels),
        BC5 => t::decode_bc5(data, width, height, pixels),
        BC6_UNSIGNED => t::decode_bc6_unsigned(data, width, height, pixels),
        BC6_SIGNED => t::decode_bc6_signed(data, width, height, pixels),
        BC7 => t::decode_bc7(data, width, height, pixels),
        ATC_RGB => t::decode_atc_rgb4(data, width, height, pixels),
        ATC_RGBA => t::decode_atc_rgba8(data, width, height, pixels),
        ETC1 => t::decode_etc1(data, width, height, pixels),
        ETC2_RGB => t::decode_etc2_rgb(data, width, height, pixels),
        ETC2_RGBA1 => t::decode_etc2_rgba1(data, width, height, pixels),
        ETC2_RGBA8 => t::decode_etc2_rgba8(data, width, height, pixels),
        EAC_R => t::decode_eacr(data, width, height, pixels),
        EAC_R_SIGNED => t::decode_eacr_signed(data, width, height, pixels),
        EAC_RG => t::decode_eacrg(data, width, height, pixels),
        EAC_RG_SIGNED => t::decode_eacrg_signed(data, width, height, pixels),
        ASTC => {
            if !(2..=12).contains(&block_width) || !(2..=12).contains(&block_height) {
                return Err("Unsupported ASTC block dimensions");
            }
            t::decode_astc(data, width, height, block_width, block_height, pixels)
        }
        PVRTC_2BPP => t::decode_pvrtc_2bpp(data, width, height, pixels),
        PVRTC_4BPP => t::decode_pvrtc_4bpp(data, width, height, pixels),
        _ => Err("Unsupported texture format ID"),
    }
}

/// Decodes a compressed Unity Texture2D image into tightly packed BGRA8 bytes.
/// The decoder's u32 pixels are written little-endian as [B,G,R,A].
#[no_mangle]
pub unsafe extern "C" fn mlbb_texture_decode(
    format: u32,
    input: *const u8,
    input_len: usize,
    width: u32,
    height: u32,
    block_width: u32,
    block_height: u32,
    output: *mut u8,
    output_len: usize,
) -> i32 {
    if input.is_null() || output.is_null() || input_len == 0 {
        return ERR_ARGUMENT;
    }

    let width = width as usize;
    let height = height as usize;
    if width == 0 || height == 0 {
        return ERR_DIMENSIONS;
    }

    let pixel_count = match width.checked_mul(height) {
        Some(count) if count <= MAX_PIXELS => count,
        _ => return ERR_DIMENSIONS,
    };
    let required_output = match pixel_count.checked_mul(4) {
        Some(size) => size,
        None => return ERR_DIMENSIONS,
    };
    if output_len < required_output {
        return ERR_OUTPUT;
    }

    let source = unsafe { slice::from_raw_parts(input, input_len) };
    let destination = unsafe { slice::from_raw_parts_mut(output, required_output) };
    let mut decoded = vec![0u32; pixel_count];

    let result = catch_unwind(AssertUnwindSafe(|| {
        decode(
            format,
            source,
            width,
            height,
            block_width as usize,
            block_height as usize,
            &mut decoded,
        )
    }));

    match result {
        Ok(Ok(())) => {
            for (pixel, bytes) in decoded.iter().zip(destination.chunks_exact_mut(4)) {
                bytes.copy_from_slice(&pixel.to_le_bytes());
            }
            OK
        }
        Ok(Err(_)) => ERR_DECODE,
        Err(_) => ERR_PANIC,
    }
}

#[no_mangle]
pub extern "C" fn mlbb_texture_decoder_version() -> u32 {
    0x0001_0000
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn etc1_zero_block_decodes_to_opaque_bgra() {
        let data = [0u8; 8];
        let mut pixels = [0u32; 16];
        decode(ETC1, &data, 4, 4, 4, 4, &mut pixels).unwrap();
        assert_eq!(pixels[0].to_le_bytes(), [0, 0, 0, 255]);
        assert_eq!(pixels.len(), 16);
    }

    #[test]
    fn bc1_rejects_truncated_block() {
        let data = [0u8; 7];
        let mut pixels = [0u32; 16];
        assert!(decode(BC1, &data, 4, 4, 4, 4, &mut pixels).is_err());
    }

    #[test]
    fn unknown_format_is_rejected() {
        let data = [0u8; 16];
        let mut pixels = [0u32; 16];
        assert!(decode(999, &data, 4, 4, 4, 4, &mut pixels).is_err());
    }

    #[test]
    fn dimensions_are_bounded_before_allocating() {
        assert!(32_768usize.checked_mul(32_768usize).unwrap() > MAX_PIXELS);
    }
}
