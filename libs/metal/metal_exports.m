#include "metal.h"

// ============================================================================
// Hashlink exports: DEFINE_PRIM registrations, thin wrappers, and
// command-buffer management (kept inline because it touches ctx->currentDrawable)
// ============================================================================

// ============================================================================
// Context lifecycle wrappers
// ============================================================================

HL_PRIM void HL_NAME(init)(void) {
    metal_init_context();
}

HL_PRIM bool HL_NAME(setup_window)(vdynamic *win) {
    return metal_setup_window_context(win);
}

HL_PRIM void HL_NAME(shutdown)(void) {
    metal_shutdown_context();
}

// ============================================================================
// Command-buffer management — full implementations kept here
// ============================================================================

HL_PRIM vdynamic* HL_NAME(get_device)() {
    if (ctx == NULL) {
        metal_debug_log("ERROR: get_device() - ctx is NULL");
        return NULL;
    }
    metal_debug_log("get_device() - returning device");
    return (vdynamic*)ctx->device;
}

HL_PRIM vdynamic* HL_NAME(create_command_buffer)() {
    if (ctx == NULL || ctx->commandQueue == NULL) {
        metal_debug_log("ERROR: create_command_buffer() - ctx or commandQueue is NULL");
        return NULL;
    }

    @autoreleasepool {
        id<MTLCommandQueue> commandQueue = (__bridge id<MTLCommandQueue>)ctx->commandQueue;
        id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
        if (commandBuffer == NULL) {
            metal_debug_log("ERROR: create_command_buffer() - failed to create command buffer");
            return NULL;
        }

        metal_debug_log("create_command_buffer() - SUCCESS");
        return (vdynamic*)(__bridge_retained void*)commandBuffer;
    }
}

HL_PRIM bool HL_NAME(commit_command_buffer)(vdynamic *cmdBuffer) {
    if (cmdBuffer == NULL) {
        metal_debug_log("ERROR: commit_command_buffer() - cmdBuffer is NULL");
        return false;
    }

    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = (__bridge_transfer id<MTLCommandBuffer>)cmdBuffer;

        // Present the drawable if we have one
        if (ctx != NULL && ctx->currentDrawable != NULL) {
            id<CAMetalDrawable> drawable = (__bridge id<CAMetalDrawable>)ctx->currentDrawable;
            [commandBuffer presentDrawable:drawable];

            // Release the drawable after presenting
            id<CAMetalDrawable> drawableToRelease = (__bridge_transfer id<CAMetalDrawable>)ctx->currentDrawable;
            (void)drawableToRelease; // ARC will handle release
            ctx->currentDrawable = NULL;
            ctx->currentCommandBuffer = NULL;
            metal_debug_log("commit_command_buffer() - SUCCESS with drawable");
        } else {
            metal_debug_log("WARNING: commit_command_buffer() - no drawable to present");
        }

        [commandBuffer commit];

        return true;
    }
}

HL_PRIM void HL_NAME(wait_until_completed)(vdynamic *cmdBuffer) {
    if (cmdBuffer == NULL) return;

    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = (__bridge_transfer id<MTLCommandBuffer>)cmdBuffer;

        // Wait synchronously for the command buffer to finish execution
        [commandBuffer waitUntilCompleted];
        
        metal_debug_log("wait_until_completed() - Command buffer completed");
    }
}

HL_PRIM bool HL_NAME(commit_without_present)(vdynamic *cmdBuffer) {
    if (cmdBuffer == NULL) {
        metal_debug_log("ERROR: commit_without_present() - null command buffer");
        return false;
    }

    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = (__bridge id<MTLCommandBuffer>)cmdBuffer;
        
        // Release the drawable since we are NOT presenting it.
        // Without this, drawTo() cycles that acquire a drawable in begin_render_pass
        // would leak one drawable per frame.
        if (ctx != NULL && ctx->currentDrawable != NULL) {
            id<CAMetalDrawable> drawableToRelease = (__bridge_transfer id<CAMetalDrawable>)ctx->currentDrawable;
            (void)drawableToRelease; // ARC will release
            ctx->currentDrawable = NULL;
        }
        
        // Just commit, don't present drawable
        [commandBuffer commit];
        metal_debug_log("commit_without_present() - SUCCESS");
        return true;
    }
}

// ============================================================================
// Logging control
// ============================================================================

HL_PRIM void HL_NAME(set_debug_level)(int level) {
    metal_set_log_level(level);
}

HL_PRIM void HL_NAME(log_event)(const char *eventName, int param1, int param2) {
    FILE *f = fopen("/tmp/metal_events.log", "a");
    if (f) {
        fprintf(f, "[EVENT] %s param1=%d param2=%d\n", eventName, param1, param2);
        fflush(f);
        fclose(f);
    }
}

// ============================================================================
// Thin wrappers — Resources (metal_resources.m)
// ============================================================================

HL_PRIM vdynamic* HL_NAME(create_buffer)(int size, int usage) {
    return metal_create_buffer_impl(size, usage);
}

HL_PRIM bool HL_NAME(upload_buffer_data)(vdynamic *buffer, vbyte *data, int size, int offset) {
    return metal_upload_buffer_data_impl(buffer, data, size, offset);
}

HL_PRIM vdynamic* HL_NAME(create_texture)(int width, int height, int format, int usage, bool mipmapped, bool isCube, int arrayLength) {
    return metal_create_texture_impl(width, height, format, usage, mipmapped, isCube, arrayLength);
}

HL_PRIM bool HL_NAME(upload_texture_data)(vdynamic *texture, vbyte *data, int width, int height, int level, int slice) {
    return metal_upload_texture_data_impl(texture, data, width, height, level, slice);
}

HL_PRIM bool HL_NAME(capture_texture_pixels)(vdynamic *texture, vbyte *data, int width, int height, int level) {
    return metal_capture_texture_pixels_impl(texture, data, width, height, level);
}

HL_PRIM void HL_NAME(generate_mipmaps)(vdynamic *texture) {
    metal_generate_mipmaps_impl(texture);
}

HL_PRIM void HL_NAME(dispose_texture)(vdynamic *texture) {
    metal_dispose_texture_impl(texture);
}

HL_PRIM vdynamic* HL_NAME(create_sampler_state)(int minFilter, int magFilter, int mipFilter, int wrapS, int wrapT) {
    return metal_create_sampler_state_impl(minFilter, magFilter, mipFilter, wrapS, wrapT);
}

HL_PRIM void HL_NAME(dispose_buffer)(vdynamic *buffer) {
    metal_dispose_buffer_impl(buffer);
}

HL_PRIM void HL_NAME(dispose_sampler)(vdynamic *sampler) {
    metal_dispose_sampler_impl(sampler);
}

HL_PRIM void HL_NAME(set_fragment_samplers)(vdynamic *encoder, varray *samplers) {
    metal_set_fragment_samplers_impl(encoder, samplers);
}

HL_PRIM void HL_NAME(set_fragment_sampler)(vdynamic *encoder, vdynamic *sampler, int index) {
    metal_set_fragment_sampler_impl(encoder, sampler, index);
}

// ============================================================================
// Thin wrappers — Pipeline (metal_pipeline.m)
// ============================================================================

HL_PRIM vdynamic* HL_NAME(compile_shader)(vstring *source, int shaderType) {
    return metal_compile_shader_impl(source, shaderType);
}

HL_PRIM vdynamic* HL_NAME(create_render_pipeline)(vdynamic *vertexShader, vdynamic *fragmentShader, vstring *vertexDesc, int blendSrc, int blendDst, int blendAlphaSrc, int blendAlphaDst, int blendOp, int blendAlphaOp) {
    return metal_create_render_pipeline_impl(vertexShader, fragmentShader, vertexDesc, blendSrc, blendDst, blendAlphaSrc, blendAlphaDst, blendOp, blendAlphaOp);
}

HL_PRIM vdynamic* HL_NAME(create_compute_pipeline_from_function)(vdynamic *func) {
    return metal_create_compute_pipeline_from_function_impl(func);
}

HL_PRIM void HL_NAME(dispose_pipeline)(vdynamic *pipeline) {
    metal_dispose_pipeline_impl(pipeline);
}

// ============================================================================
// Thin wrappers — Render (metal_render.m)
// ============================================================================

HL_PRIM vdynamic* HL_NAME(begin_render_pass)(vdynamic *cmdBuffer, int r, int g, int b, int a) {
    return metal_begin_render_pass_impl(cmdBuffer, r, g, b, a);
}

HL_PRIM vdynamic* HL_NAME(resume_render_pass)(vdynamic *cmdBuffer) {
    return metal_resume_render_pass_impl(cmdBuffer);
}

HL_PRIM vdynamic* HL_NAME(begin_texture_render_pass)(vdynamic *cmdBuffer, vdynamic *texture, int r, int g, int b, int a, vdynamic *depthTexParam, int layer, int mipLevel, int depthAction) {
    return metal_begin_texture_render_pass_impl(cmdBuffer, texture, r, g, b, a, depthTexParam, layer, mipLevel, depthAction);
}

HL_PRIM vdynamic* HL_NAME(begin_mrt_render_pass)(vdynamic *cmdBuffer, varray *textures, int r, int g, int b, int a, vdynamic *depthTex) {
    return metal_begin_mrt_render_pass_impl(cmdBuffer, textures, r, g, b, a, depthTex);
}

HL_PRIM vdynamic* HL_NAME(begin_depth_render_pass)(vdynamic *cmdBuffer, vdynamic *depthTexture, double clearDepth) {
    return metal_begin_depth_render_pass_impl(cmdBuffer, depthTexture, clearDepth);
}

HL_PRIM void HL_NAME(set_render_pipeline_state)(vdynamic *encoder, vdynamic *pipeline) {
    metal_set_render_pipeline_state_impl(encoder, pipeline);
}

HL_PRIM void HL_NAME(set_depth_state)(vdynamic *encoder, bool depthTest, bool depthWrite) {
    metal_set_depth_state_impl(encoder, depthTest, depthWrite);
}

HL_PRIM void HL_NAME(set_stencil_state)(vdynamic *encoder, int depthCompareFunc, bool depthWrite,
    int frontFunc, int frontSTfail, int frontDPfail, int frontPass,
    int backFunc, int backSTfail, int backDPfail, int backPass,
    int reference, int readMask, int writeMask) {
    metal_set_stencil_state_impl(encoder, depthCompareFunc, depthWrite,
        frontFunc, frontSTfail, frontDPfail, frontPass,
        backFunc, backSTfail, backDPfail, backPass,
        reference, readMask, writeMask);
}

HL_PRIM void HL_NAME(set_cull_mode)(vdynamic *encoder, int cullMode) {
    metal_set_cull_mode_impl(encoder, cullMode);
}

HL_PRIM void HL_NAME(set_triangle_fill_mode)(vdynamic *encoder, bool wireframe) {
    metal_set_triangle_fill_mode_impl(encoder, wireframe);
}

HL_PRIM void HL_NAME(set_viewport)(vdynamic *encoder, double x, double y, double width, double height) {
    metal_set_viewport_impl(encoder, x, y, width, height);
}

HL_PRIM void HL_NAME(set_scissor_rect)(vdynamic *encoder, int x, int y, int width, int height) {
    metal_set_scissor_rect_impl(encoder, x, y, width, height);
}

HL_PRIM void HL_NAME(set_vertex_buffer)(vdynamic *encoder, vdynamic *buffer, int offset, int index) {
    metal_set_vertex_buffer_impl(encoder, buffer, offset, index);
}

HL_PRIM void HL_NAME(set_vertex_bytes)(vdynamic *encoder, vbyte *data, int length, int index) {
    metal_set_vertex_bytes_impl(encoder, data, length, index);
}

HL_PRIM void HL_NAME(set_fragment_bytes)(vdynamic *encoder, vbyte *data, int length, int index) {
    metal_set_fragment_bytes_impl(encoder, data, length, index);
}

HL_PRIM void HL_NAME(set_fragment_texture)(vdynamic *encoder, vdynamic *texture, int index) {
    metal_set_fragment_texture_impl(encoder, texture, index);
}

HL_PRIM void HL_NAME(set_fragment_buffer)(vdynamic *encoder, vdynamic *buffer, int offset, int index) {
    metal_set_fragment_buffer_impl(encoder, buffer, offset, index);
}

HL_PRIM void HL_NAME(draw_primitives)(vdynamic *encoder, int primitiveType, int vertexStart, int vertexCount) {
    metal_draw_primitives_impl(encoder, primitiveType, vertexStart, vertexCount);
}

HL_PRIM void HL_NAME(draw_indexed_primitives)(vdynamic *encoder, int primitiveType, int indexCount, vdynamic *indexBuffer, int indexOffset, int is32bit) {
    metal_draw_indexed_primitives_impl(encoder, primitiveType, indexCount, indexBuffer, indexOffset, is32bit);
}

HL_PRIM void HL_NAME(draw_indexed_primitives_instanced)(vdynamic *encoder, int primitiveType, int indexCount, vdynamic *indexBuffer, int indexOffset, int instanceCount, int is32bit) {
    metal_draw_indexed_primitives_instanced_impl(encoder, primitiveType, indexCount, indexBuffer, indexOffset, instanceCount, is32bit);
}

HL_PRIM void HL_NAME(end_encoding)(vdynamic *encoder) {
    metal_end_encoding_impl(encoder);
}

// ============================================================================
// Thin wrappers — Compute (metal_compute.m)
// ============================================================================

HL_PRIM vdynamic* HL_NAME(create_compute_pipeline)(vbyte *source, vbyte *functionName) {
    return metal_create_compute_pipeline_impl(source, functionName);
}

HL_PRIM void HL_NAME(set_compute_pipeline)(vdynamic *pipeline) {
    metal_set_compute_pipeline_impl(pipeline);
}

HL_PRIM void HL_NAME(set_compute_buffer)(vdynamic *buffer, int index) {
    metal_set_compute_buffer_impl(buffer, index);
}

HL_PRIM void HL_NAME(set_compute_texture)(vdynamic *texture, int index) {
    metal_set_compute_texture_impl(texture, index);
}

HL_PRIM bool HL_NAME(dispatch_compute)(vdynamic *cmdBuffer, int x, int y, int z) {
    return metal_dispatch_compute_impl(cmdBuffer, x, y, z);
}

HL_PRIM void HL_NAME(memory_barrier)(vdynamic *cmdBuffer) {
    metal_memory_barrier_impl(cmdBuffer);
}

// ============================================================================
// All DEFINE_PRIM registrations — consolidated
// ============================================================================

// Context lifecycle
DEFINE_PRIM(_VOID, init, _NO_ARG);
DEFINE_PRIM(_BOOL, setup_window, _DYN);
DEFINE_PRIM(_VOID, shutdown, _NO_ARG);

// Command buffer management
DEFINE_PRIM(_DYN, get_device, _NO_ARG);
DEFINE_PRIM(_DYN, create_command_buffer, _NO_ARG);
DEFINE_PRIM(_BOOL, commit_command_buffer, _DYN);
DEFINE_PRIM(_BOOL, commit_without_present, _DYN);
DEFINE_PRIM(_VOID, wait_until_completed, _DYN);

// Resources
DEFINE_PRIM(_DYN, create_buffer, _I32 _I32);
DEFINE_PRIM(_BOOL, upload_buffer_data, _DYN _BYTES _I32 _I32);
DEFINE_PRIM(_DYN, create_texture, _I32 _I32 _I32 _I32 _BOOL _BOOL _I32);
DEFINE_PRIM(_BOOL, upload_texture_data, _DYN _BYTES _I32 _I32 _I32 _I32);
DEFINE_PRIM(_BOOL, capture_texture_pixels, _DYN _BYTES _I32 _I32 _I32);
DEFINE_PRIM(_VOID, generate_mipmaps, _DYN);
DEFINE_PRIM(_VOID, dispose_buffer, _DYN);
DEFINE_PRIM(_VOID, dispose_texture, _DYN);
DEFINE_PRIM(_DYN, create_sampler_state, _I32 _I32 _I32 _I32 _I32);
DEFINE_PRIM(_VOID, dispose_sampler, _DYN);
DEFINE_PRIM(_VOID, set_fragment_samplers, _DYN _ARR);
DEFINE_PRIM(_VOID, set_fragment_sampler, _DYN _DYN _I32);

// Pipeline
DEFINE_PRIM(_DYN, compile_shader, _STRING _I32);
DEFINE_PRIM(_DYN, create_render_pipeline, _DYN _DYN _STRING _I32 _I32 _I32 _I32 _I32 _I32);
DEFINE_PRIM(_DYN, create_compute_pipeline_from_function, _DYN);
DEFINE_PRIM(_VOID, dispose_pipeline, _DYN);

// Render pass and encoding
DEFINE_PRIM(_DYN, begin_render_pass, _DYN _I32 _I32 _I32 _I32);
DEFINE_PRIM(_DYN, resume_render_pass, _DYN);
DEFINE_PRIM(_DYN, begin_texture_render_pass, _DYN _DYN _I32 _I32 _I32 _I32 _DYN _I32 _I32 _I32);
DEFINE_PRIM(_DYN, begin_mrt_render_pass, _DYN _ARR _I32 _I32 _I32 _I32 _DYN);
DEFINE_PRIM(_DYN, begin_depth_render_pass, _DYN _DYN _F64);
DEFINE_PRIM(_VOID, set_render_pipeline_state, _DYN _DYN);
DEFINE_PRIM(_VOID, set_depth_state, _DYN _BOOL _BOOL);
DEFINE_PRIM(_VOID, set_stencil_state, _DYN _I32 _BOOL _I32 _I32 _I32 _I32 _I32 _I32 _I32 _I32 _I32 _I32 _I32);
DEFINE_PRIM(_VOID, set_cull_mode, _DYN _I32);
DEFINE_PRIM(_VOID, set_triangle_fill_mode, _DYN _BOOL);
DEFINE_PRIM(_VOID, set_viewport, _DYN _F64 _F64 _F64 _F64);
DEFINE_PRIM(_VOID, set_scissor_rect, _DYN _I32 _I32 _I32 _I32);
DEFINE_PRIM(_VOID, set_vertex_buffer, _DYN _DYN _I32 _I32);
DEFINE_PRIM(_VOID, set_vertex_bytes, _DYN _BYTES _I32 _I32);
DEFINE_PRIM(_VOID, set_fragment_bytes, _DYN _BYTES _I32 _I32);
DEFINE_PRIM(_VOID, set_fragment_texture, _DYN _DYN _I32);
DEFINE_PRIM(_VOID, set_fragment_buffer, _DYN _DYN _I32 _I32);
DEFINE_PRIM(_VOID, draw_primitives, _DYN _I32 _I32 _I32);
DEFINE_PRIM(_VOID, draw_indexed_primitives, _DYN _I32 _I32 _DYN _I32 _I32);
DEFINE_PRIM(_VOID, draw_indexed_primitives_instanced, _DYN _I32 _I32 _DYN _I32 _I32 _I32);
DEFINE_PRIM(_VOID, end_encoding, _DYN);

// Compute
DEFINE_PRIM(_DYN, create_compute_pipeline, _BYTES _BYTES);
DEFINE_PRIM(_VOID, set_compute_pipeline, _DYN);
DEFINE_PRIM(_VOID, set_compute_buffer, _DYN _I32);
DEFINE_PRIM(_VOID, set_compute_texture, _DYN _I32);
DEFINE_PRIM(_BOOL, dispatch_compute, _DYN _I32 _I32 _I32);
DEFINE_PRIM(_VOID, memory_barrier, _DYN);

// Logging
DEFINE_PRIM(_VOID, set_debug_level, _I32);
DEFINE_PRIM(_VOID, log_event, _STRING _I32 _I32);

