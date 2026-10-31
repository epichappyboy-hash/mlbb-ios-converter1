// SPDX-License-Identifier: Apache-2.0
// Minimal C ABI wrapper around Arm's ASTC encoder for the iOS app.
#include <cstddef>
#include <cstdint>
#include <limits>
#include "astcenc.h"

extern "C" __attribute__((visibility("default")))
int mlbb_astc_encode_rgba(
    const std::uint8_t* rgba,
    std::uint32_t width,
    std::uint32_t height,
    std::uint32_t block_size,
    float quality,
    std::uint8_t* output,
    std::size_t output_capacity
) {
    if (!rgba || !output || width == 0 || height == 0 ||
        (block_size != 4 && block_size != 6 && block_size != 8)) {
        return ASTCENC_ERR_BAD_PARAM;
    }

    const std::size_t blocks_x =
        (static_cast<std::size_t>(width) + block_size - 1) / block_size;
    const std::size_t blocks_y =
        (static_cast<std::size_t>(height) + block_size - 1) / block_size;
    if (blocks_x > std::numeric_limits<std::size_t>::max() / blocks_y / 16) {
        return ASTCENC_ERR_BAD_PARAM;
    }
    const std::size_t required = blocks_x * blocks_y * 16;
    if (output_capacity < required) {
        return ASTCENC_ERR_BAD_PARAM;
    }

    astcenc_config config{};
    astcenc_error status = astcenc_config_init(
        ASTCENC_PRF_LDR,
        block_size,
        block_size,
        1,
        quality,
        ASTCENC_FLG_USE_DECODE_UNORM8,
        &config
    );
    if (status != ASTCENC_SUCCESS) {
        return status;
    }

    astcenc_context* context = nullptr;
    status = astcenc_context_alloc(&config, 1, &context, nullptr);
    if (status != ASTCENC_SUCCESS) {
        return status;
    }

    void* slices[1] = {const_cast<std::uint8_t*>(rgba)};
    astcenc_image image{width, height, 1, ASTCENC_TYPE_U8, slices};
    astcenc_swizzle swizzle{
        ASTCENC_SWZ_R, ASTCENC_SWZ_G, ASTCENC_SWZ_B, ASTCENC_SWZ_A
    };

    status = astcenc_compress_image(
        context, &image, &swizzle, output, required, 0
    );
    astcenc_context_free(context);
    return status;
}
