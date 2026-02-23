#include "metal.h"

bool metal_setup_frame_data(void) {
    if (ctx == NULL) return false;

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;

        // Create frame data buffers for triple buffering
        for (int i = 0; i < MAX_FRAMES_IN_FLIGHT; i++) {
            id<MTLBuffer> buffer = [device newBufferWithLength:sizeof(frame_data)
                                                       options:MTLResourceStorageModeShared];
            if (!buffer) {
                metal_debug_log("Failed to create frame data buffer %d", i);
                return false;
            }
            ctx->frameDataBuffers[i] = (__bridge_retained void*)buffer;
        }

        // Create dispatch semaphore for frame synchronization
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(MAX_FRAMES_IN_FLIGHT);
        ctx->frameSemaphore = (__bridge_retained void*)semaphore;
        ctx->frameIndex = 0;
        ctx->angle = 0.0f;

        metal_debug_log("Frame data buffers created successfully");
    }

    return true;
}

vdynamic* metal_alloc_buffer_impl(int size, int flags) {
    if (ctx == NULL) return NULL;

    @autoreleasepool {
        // Debug output for allocation
        metal_debug_log("Metal allocating buffer of size: %d bytes, flags: 0x%X", size, flags);

        if (size <= 0) {
            metal_debug_log("Warning: Trying to allocate a buffer of size <= 0");
            size = 1024; // Minimum size
        }

        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;

        // Determine storage mode based on flags
        MTLResourceOptions options = MTLResourceStorageModeShared;
        
        // Add usage flags for dual-purpose buffers
        MTLResourceUsage usage = 0;
        if (flags & BUFFER_FLAG_VERTEX_READ) {
            usage |= MTLResourceUsageRead;  // Vertex shader reads
        }
        if (flags & BUFFER_FLAG_COMPUTE_WRITE) {
            usage |= MTLResourceUsageWrite; // Compute shader writes
        }
        
        // Create a Metal buffer with the specified size and options
        id<MTLBuffer> metalBuffer = [device newBufferWithLength:size options:options];

        if (!metalBuffer) {
            metal_debug_log("Failed to allocate Metal buffer of size %d", size);
            return NULL;
        }
        
        // Set usage if specified (for compute-to-vertex pipeline)
        if (usage != 0) {
            // Note: Usage is set at buffer creation time through options
            // Metal automatically handles synchronization for shared buffers
            metal_debug_log("Buffer created with usage flags: 0x%lX", (unsigned long)usage);
        }

        // Create a dynamic integer value to return - store as retained void*
        void* retainedBuffer = (__bridge_retained void*)metalBuffer;
        vdynamic *result = (vdynamic*)hl_gc_alloc_noptr(sizeof(vdynamic));
        result->t = &hlt_i32;
        result->v.i = (int)(uintptr_t)retainedBuffer; // Cast void* to integer
        return result;
    }
}

void metal_dispose_buffer_impl(vdynamic *buffer) {
    if (!buffer) return;

    @autoreleasepool {
        if (buffer->t == &hlt_i32) {
            // Legacy alloc_buffer format: pointer stored as int in vdynamic wrapper
            void* retainedBuffer = (void*)(uintptr_t)buffer->v.i;
            if (retainedBuffer) {
                id<MTLBuffer> metalBuffer = (__bridge_transfer id<MTLBuffer>)retainedBuffer;
                (void)metalBuffer; // ARC will release
            }
        } else {
            // create_buffer format: raw retained MTLBuffer pointer cast as vdynamic*
            id<MTLBuffer> metalBuffer = (__bridge_transfer id<MTLBuffer>)buffer;
            (void)metalBuffer; // ARC will release
        }
    }
}

bool metal_update_buffer_impl(vdynamic *buffer, void *data, int size, int offset) {
    if (ctx == NULL || buffer == NULL || buffer->t != &hlt_i32 || data == NULL || size <= 0) {
        metal_debug_log("Invalid parameters for update_buffer");
        return false;
    }

    @autoreleasepool {
        // Get the Metal buffer by casting integer back to void* then bridging
        void* retainedBuffer = (void*)(uintptr_t)buffer->v.i;
        id<MTLBuffer> metalBuffer = (__bridge id<MTLBuffer>)retainedBuffer;

        // Check if the buffer size is sufficient
        if (offset + size > metalBuffer.length) {
            metal_debug_log("Buffer update exceeds buffer size: offset %d + size %d > buffer length %lu",
                           offset, size, metalBuffer.length);
            return false;
        }

        // Copy data to the buffer
        void *bufferPtr = metalBuffer.contents;
        if (bufferPtr) {
            memcpy((char*)bufferPtr + offset, data, size);
            return true;
        } else {
            metal_debug_log("Failed to get buffer contents for update");
            return false;
        }
    }
}

// Hashlink exports for buffer management
HL_PRIM vdynamic* HL_NAME(alloc_buffer)(int size, int flags) {
    return metal_alloc_buffer_impl(size, flags);
}

HL_PRIM void HL_NAME(dispose_buffer)(vdynamic *buffer) {
    metal_dispose_buffer_impl(buffer);
}

HL_PRIM bool HL_NAME(update_buffer)(vdynamic *buffer, void *data, int size, int offset) {
    return metal_update_buffer_impl(buffer, data, size, offset);
}

DEFINE_PRIM(_DYN, alloc_buffer, _I32 _I32);
DEFINE_PRIM(_VOID, dispose_buffer, _DYN);
DEFINE_PRIM(_BOOL, update_buffer, _DYN _BYTES _I32 _I32);