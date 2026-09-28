#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

struct SplatVertexOut {
    float4 position [[position]];
    float2 local;       // pixel offset from splat center
    float3 conic;       // (a, b, c) of inverse 2D covariance
    float4 color;       // premultiplied? no, rgb * opacity in fragment
    float  opacity;
};

static inline float3x3 quaternionToMatrix(float4 q) {
    // q = (x, y, z, w)
    float x = q.x, y = q.y, z = q.z, w = q.w;
    float xx = x*x, yy = y*y, zz = z*z;
    float xy = x*y, xz = x*z, yz = y*z;
    float wx = w*x, wy = w*y, wz = w*z;
    return float3x3(
        float3(1.0 - 2.0*(yy + zz), 2.0*(xy + wz),       2.0*(xz - wy)),
        float3(2.0*(xy - wz),       1.0 - 2.0*(xx + zz), 2.0*(yz + wx)),
        float3(2.0*(xz + wy),       2.0*(yz - wx),       1.0 - 2.0*(xx + yy))
    );
}

vertex SplatVertexOut splat_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant GPUSplat *splats   [[buffer(0)]],
    constant uint     *indices  [[buffer(1)]],
    constant SplatUniforms &u   [[buffer(2)]]
) {
    GPUSplat s = splats[indices[iid]];

    // Build world-space covariance Σ = R S Sᵀ Rᵀ
    float3x3 R = quaternionToMatrix(s.rotation);
    float3x3 S = float3x3(
        float3(s.scale.x, 0, 0),
        float3(0, s.scale.y, 0),
        float3(0, 0, s.scale.z)
    );
    float3x3 M = R * S;
    float3x3 Sigma = M * transpose(M);

    // View-space mean
    float4 meanView4 = u.view * float4(s.position, 1.0);
    float3 t = meanView4.xyz;

    // Behind camera? Cull by emitting degenerate quad.
    if (t.z >= -0.05) {
        SplatVertexOut o;
        o.position = float4(0, 0, 2, 1); // outside clip range
        o.local = float2(0);
        o.conic = float3(1, 0, 1);
        o.color = float4(0);
        o.opacity = 0;
        return o;
    }

    // World→view rotation (upper 3x3 of view matrix). Apple uses column-major,
    // so view[i] is the i-th column.
    float3x3 W = float3x3(u.view[0].xyz, u.view[1].xyz, u.view[2].xyz);
    float3x3 SigmaView = W * Sigma * transpose(W);

    // Perspective Jacobian J (2x3) at view-space mean.
    // We use Apple's right-handed view space (camera looks down -Z).
    // Pixel coords: x_pix = -fx * t.x / t.z, y_pix = -fy * t.y / t.z
    // J = [[ -fx/t.z,  0,        fx*t.x/t.z² ],
    //      [  0,      -fy/t.z,   fy*t.y/t.z² ]]
    float invZ  = 1.0 / t.z;
    float invZ2 = invZ * invZ;
    float a = -u.focal.x * invZ;
    float b =  u.focal.x * t.x * invZ2;
    float c = -u.focal.y * invZ;
    float d =  u.focal.y * t.y * invZ2;

    // Σ_2D = J Σ_view Jᵀ, written out scalar.
    // J = [[a, 0, b], [0, c, d]]
    float s00 = SigmaView[0][0], s01 = SigmaView[1][0], s02 = SigmaView[2][0];
    float                          s11 = SigmaView[1][1], s12 = SigmaView[2][1];
    float                                                  s22 = SigmaView[2][2];

    // Row 0 of (J Σ): [a*s00 + b*s02, a*s01 + b*s12, a*s02 + b*s22]
    float r00 = a*s00 + b*s02;
    float r01 = a*s01 + b*s12;
    float r02 = a*s02 + b*s22;
    // Row 1 of (J Σ): [c*s01 + d*s02, c*s11 + d*s12, c*s12 + d*s22]
    float r10 = c*s01 + d*s02;
    float r11 = c*s11 + d*s12;
    float r12 = c*s12 + d*s22;

    // (J Σ Jᵀ): 2x2
    float A = r00*a + r02*b;
    float B = r01*0 /* +0 */ + r02*0; // not this, redo: Σ_2D[0][1] = r0 · J^T col 1
    // Σ_2D[0][1] = r00 * 0 + r01 * c + r02 * d
    B = r01 * c + r02 * d;
    float C = r11 * c + r12 * d;

    // Low-pass / anti-alias regularization (a la 3DGS).
    A += 0.3;
    C += 0.3;

    // Inverse 2D covariance for fragment Mahalanobis.
    float det = A * C - B * B;
    if (det <= 0.0) {
        SplatVertexOut o;
        o.position = float4(0, 0, 2, 1);
        o.local = float2(0);
        o.conic = float3(1, 0, 1);
        o.color = float4(0);
        o.opacity = 0;
        return o;
    }
    float invDet = 1.0 / det;
    float3 conic = float3(C * invDet, -B * invDet, A * invDet);

    // Bounding quad: 3σ along largest principal axis.
    float mid = 0.5 * (A + C);
    float disc = max(0.0, mid * mid - det);
    float lambda = mid + sqrt(disc);
    float radiusPx = ceil(3.0 * sqrt(max(lambda, 1e-4)));

    // Quad corner offsets in pixels (vid in 0..3 for triangle strip).
    float2 corner = float2(
        (vid == 1 || vid == 3) ?  1.0 : -1.0,
        (vid == 2 || vid == 3) ?  1.0 : -1.0
    );
    float2 offsetPx = corner * radiusPx;

    // Project mean to clip space.
    float4 clipMean = u.projection * meanView4;

    // Convert pixel offset to clip-space offset at this depth.
    // ndc = clip / w, ndc.xy * 0.5 * viewport = pixels.
    // So clip offset = (offsetPx / (0.5 * viewport)) * w
    float2 clipOffset = (offsetPx / (0.5 * u.viewport)) * clipMean.w;

    SplatVertexOut o;
    o.position = float4(clipMean.xy + clipOffset, clipMean.z, clipMean.w);
    o.local    = offsetPx;
    o.conic    = conic;
    o.color    = s.color;
    o.opacity  = s.opacity;
    return o;
}

fragment float4 splat_fragment(SplatVertexOut in [[stage_in]]) {
    // Mahalanobis distance: dᵀ Σ⁻¹ d, with conic = (a, b, c) for [[a,b],[b,c]].
    float2 d = in.local;
    float power = -0.5 * (in.conic.x * d.x * d.x + in.conic.z * d.y * d.y)
                  - in.conic.y * d.x * d.y;
    if (power > 0.0) discard_fragment();

    float alpha = min(0.99, in.opacity * exp(power));
    if (alpha < 1.0 / 255.0) discard_fragment();

    // Premultiplied output for back-to-front blending with
    // (ONE, ONE_MINUS_SRC_ALPHA).
    return float4(in.color.rgb * alpha, alpha);
}
