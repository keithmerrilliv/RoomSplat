#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// One Gaussian splat. 80 bytes, 16-byte aligned.
typedef struct {
    simd_float3 position;   // mean in world space
    float       opacity;    // [0,1]
    simd_float3 scale;      // axis lengths (sigma) in world units
    float       _pad0;
    simd_float4 rotation;   // unit quaternion (x, y, z, w)
    simd_float4 color;      // rgba (a unused, opacity above)
} GPUSplat;

typedef struct {
    matrix_float4x4 view;
    matrix_float4x4 projection;
    matrix_float4x4 viewProjection;
    simd_float2     focal;       // pixel focal lengths (fx, fy)
    simd_float2     viewport;    // pixels (w, h)
    simd_float3     cameraPos;   // world space
    float           _pad0;
} SplatUniforms;

#endif
