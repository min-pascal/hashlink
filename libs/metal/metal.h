#ifndef METAL_H
#define METAL_H

#define HL_NAME(n) metal_##n

#include <hl.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_metal.h>
#include <Metal/Metal.h>
#include <QuartzCore/CAMetalLayer.h>
#include <simd/simd.h>
#include <stdarg.h>  // Add this for va_list

// Common constants and macros
#define DEBUG_FILE "/tmp/metal_debug.log"
#define MAX_FRAMES_IN_FLIGHT 3
#define NUM_INSTANCES 32

// Forward declarations
typedef struct metal_context metal_context;
typedef struct metal_vertex metal_vertex;
typedef struct frame_data frame_data;
typedef struct metal_instance_data metal_instance_data;

// Vertex structure with position and color for triangle rendering
struct metal_vertex {
    float position[3];
    float color[4];
};

// Frame data structure for animation
struct frame_data {
    float angle;
};

// Instance data for instanced rendering
struct metal_instance_data {
    simd_float4x4 instanceTransform;
    simd_float4 instanceColor;
};

// Camera data structure for perspective rendering
struct metal_camera_data {
    simd_float4x4 perspectiveTransform;
    simd_float4x4 worldTransform;
};

// Vertex structure with position and normal for lighting
struct metal_lighting_vertex {
    float position[3];
    float normal[3];
};

// Instance data for lighting with normal transform
struct metal_lighting_instance_data {
    simd_float4x4 instanceTransform;
    simd_float3x3 instanceNormalTransform;
    simd_float4 instanceColor;
};

// Camera data for lighting with normal transform
struct metal_lighting_camera_data {
    simd_float4x4 perspectiveTransform;
    simd_float4x4 worldTransform;
    simd_float3x3 worldNormalTransform;
};

// Vertex structure with position, normal, and texture coordinates for textured rendering
struct metal_textured_vertex {
    float position[3];
    float normal[3];
    float texcoord[2];
};

// Main context structure - use void* for ARC compatibility
struct metal_context {
    void *device;           // id<MTLDevice>
    void *commandQueue;     // id<MTLCommandQueue>
    void *layer;            // CAMetalLayer*
    SDL_MetalView metalView;
    SDL_Window *window;
    bool windowSetup;

    // Pipeline states
    void *pipelineState;           // id<MTLRenderPipelineState>
    void *vertexBuffer;            // id<MTLBuffer>
    NSUInteger vertexCount;

    // Support for argument buffers
    void *argBuffer;               // id<MTLBuffer>
    void *positionBuffer;          // id<MTLBuffer>
    void *colorBuffer;             // id<MTLBuffer>

    // Animation support
    float angle;
    void *frameDataBuffer;         // id<MTLBuffer>
    void *frameSemaphore;          // dispatch_semaphore_t
    int frameIndex;
    void *frameDataBuffers[MAX_FRAMES_IN_FLIGHT];  // id<MTLBuffer>

    // Instancing support fields
    void *instanceDataBuffers[MAX_FRAMES_IN_FLIGHT];  // id<MTLBuffer>
    void *instanceIndexBuffer;     // id<MTLBuffer>
    void *instanceVertexBuffer;    // id<MTLBuffer>
    void *instancingPipelineState; // id<MTLRenderPipelineState>
    NSUInteger instanceIndexCount;
    NSUInteger instanceVertexCount;

    // Perspective rendering support fields
    void *perspectiveVertexBuffer;     // id<MTLBuffer>
    void *perspectiveIndexBuffer;      // id<MTLBuffer>
    void *perspectivePipelineState;    // id<MTLRenderPipelineState>
    void *perspectiveDepthStencilState; // id<MTLDepthStencilState>
    void *cameraDataBuffers[MAX_FRAMES_IN_FLIGHT]; // id<MTLBuffer>
    void *depthTexture;                // id<MTLTexture> - for depth testing
    NSUInteger perspectiveIndexCount;
    NSUInteger perspectiveVertexCount;

    // Vertex debugging support fields for colored dots on cube vertices
    void *debugVertexBuffer;           // id<MTLBuffer> - vertex positions for debugging dots
    void *debugPipelineState;          // id<MTLRenderPipelineState> - point rendering pipeline
    void *debugInstanceDataBuffers[MAX_FRAMES_IN_FLIGHT]; // id<MTLBuffer> - instance data for debug dots
    NSUInteger debugVertexCount;
    bool debugDotsEnabled;             // Flag to enable/disable debug dots rendering

    // Lighting rendering support fields
    void *lightingVertexBuffer;        // id<MTLBuffer> - vertices with normals
    void *lightingIndexBuffer;         // id<MTLBuffer> - cube indices
    void *lightingPipelineState;       // id<MTLRenderPipelineState> - lighting pipeline
    void *lightingDepthStencilState;   // id<MTLDepthStencilState> - depth state
    void *lightingInstanceDataBuffers[MAX_FRAMES_IN_FLIGHT]; // id<MTLBuffer> - instance data with normal transforms
    void *lightingCameraDataBuffers[MAX_FRAMES_IN_FLIGHT];   // id<MTLBuffer> - camera data with normal transforms
    NSUInteger lightingIndexCount;
    NSUInteger lightingVertexCount;

    // Textured rendering support fields
    void *texturedVertexBuffer;        // id<MTLBuffer> - vertices with texture coordinates
    void *texturedIndexBuffer;         // id<MTLBuffer> - textured object indices
    void *texturedPipelineState;       // id<MTLRenderPipelineState> - textured rendering pipeline
    void *texturedDepthStencilState;   // id<MTLDepthStencilState> - depth state for textured objects
    void *texturedInstanceDataBuffers[MAX_FRAMES_IN_FLIGHT]; // id<MTLBuffer> - instance data for textured objects
    void *texturedCameraDataBuffers[MAX_FRAMES_IN_FLIGHT];   // id<MTLBuffer> - camera data for textured objects
    void *checkerboardTexture;         // id<MTLTexture> - procedural checkerboard texture
    NSUInteger texturedIndexCount;
    NSUInteger texturedVertexCount;

    // Compute shader rendering support fields
    void *computePipelineState;        // id<MTLComputePipelineState> - compute pipeline for Mandelbrot generation
    void *computeRenderPipelineState;  // id<MTLRenderPipelineState> - render pipeline for compute-textured cubes
    void *computeDepthStencilState;    // id<MTLDepthStencilState> - depth state for compute-textured objects
    void *computeVertexBuffer;         // id<MTLBuffer> - vertices for compute-textured cubes
    void *computeIndexBuffer;          // id<MTLBuffer> - indices for compute-textured cubes
    void *computeInstanceDataBuffers[MAX_FRAMES_IN_FLIGHT]; // id<MTLBuffer> - instance data for compute cubes
    void *computeCameraDataBuffers[MAX_FRAMES_IN_FLIGHT];   // id<MTLBuffer> - camera data for compute cubes
    void *mandelbrotTexture;           // id<MTLTexture> - Mandelbrot texture generated by compute shader
    void *textureAnimationBuffer;      // id<MTLBuffer> - animation frame counter for compute shader
    NSUInteger computeIndexCount;
    NSUInteger computeVertexCount;
    uint animationIndex;               // Frame counter for Mandelbrot animation

    // Frame debugging support fields
    bool frameCaptureTrigger;          // Flag to trigger GPU frame capture
    bool frameCaptureInProgress;       // Flag indicating capture is in progress
    bool hasFrameCaptured;             // Flag indicating if a capture has been completed
    void *captureStartTime;            // NSDate* - time when app started for auto-capture timeout
    double autoCaptureTimeoutSecs;     // Timeout for automatic capture triggering
};

// Global context
extern metal_context *ctx;

// Debug utilities
void metal_debug_log(const char* message, ...);

// Context management functions (metal_context.m)
void metal_init_context(void);
bool metal_setup_window_context(vdynamic *win);
void metal_shutdown_context(void);

// Shader management functions (metal_shaders.m)
extern NSString *shaderSource;
extern NSString *instancingShaderSource;
extern NSString *perspectiveShaderSource;
extern NSString *debugPointShaderSource;
extern NSString *texturingShaderSource;
extern NSString *computeShaderSource;
bool metal_setup_pipeline(void);
bool metal_setup_instancing_pipeline(void);
bool metal_setup_perspective_pipeline(void);
bool metal_setup_debug_point_pipeline(void);
bool metal_setup_textured_pipeline(void);
bool metal_setup_compute_pipeline(void);

// Buffer management functions (metal_buffers.m)
vdynamic* metal_alloc_buffer_impl(int size, int flags);
void metal_dispose_buffer_impl(vdynamic *buffer);
bool metal_update_buffer_impl(vdynamic *buffer, void *data, int size, int offset);
bool metal_setup_frame_data(void);

// Basic rendering functions (metal_rendering.m)
bool metal_begin_render_impl(int r, int g, int b, int a);
bool metal_create_triangle_impl(float* positions, float* colors, int vertexCount);
bool metal_render_triangle_impl(int r, int g, int b, int a);

// Advanced rendering functions (metal_advanced.m)
bool metal_create_triangle_with_argbuffers_impl(float* positions, float* colors, int vertexCount);
bool metal_render_triangle_with_argbuffers_impl(int r, int g, int b, int a);
bool metal_create_instanced_rectangles_impl(void);
bool metal_render_instanced_rectangles_impl(int r, int g, int b, int a);

// Perspective rendering functions (metal_perspective.m)
bool metal_create_perspective_cubes_impl(void);
bool metal_render_perspective_cubes_impl(int r, int g, int b, int a);
bool metal_enable_debug_dots_impl(bool enable);

// Lighting rendering functions (metal_lighting.m)
bool metal_create_lighting_cubes_impl(void);
bool metal_render_lighting_cubes_impl(int r, int g, int b, int a);

// Textured rendering functions (metal_texturing.m)
bool metal_create_textured_cubes_impl(void);
bool metal_render_textured_cubes_impl(int r, int g, int b, int a);

// Compute shader rendering functions (metal_compute.m)
bool metal_create_compute_cubes_impl(void);
bool metal_render_compute_cubes_impl(int r, int g, int b, int a);
bool metal_generate_mandelbrot_texture_impl(void);

// Frame debugging functions (metal_frame_debugging.m)
bool metal_trigger_frame_capture_impl(void);
bool metal_check_auto_capture_impl(void);
bool metal_init_frame_debugging_impl(void);
bool metal_stop_frame_capture_and_open_impl(void);

// Utility functions
simd_float3 addFloat3(simd_float3 a, simd_float3 b);

#endif // METAL_H
