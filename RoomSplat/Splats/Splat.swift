import Foundation
import simd

/// Swift-side mirror of the GPU splat. Layout-compatible with `GPUSplat` in ShaderTypes.h.
struct Splat: Equatable {
    var position: SIMD3<Float>
    var opacity: Float
    var scale: SIMD3<Float>
    var _pad0: Float = 0
    var rotation: SIMD4<Float>   // (x, y, z, w)
    var color: SIMD4<Float>      // rgba

    init(position: SIMD3<Float>,
         scale: SIMD3<Float>,
         rotation: SIMD4<Float> = SIMD4(0, 0, 0, 1),
         color: SIMD3<Float>,
         opacity: Float = 1.0) {
        self.position = position
        self.scale = scale
        self.rotation = rotation
        self.color = SIMD4(color, 1)
        self.opacity = opacity
    }
}

extension Splat {
    /// Stride matching `GPUSplat` (80 bytes).
    static var stride: Int { MemoryLayout<Splat>.stride }
}

enum SplatMath {
    /// Quaternion (x, y, z, w) from a rotation that maps +Z to `normal`.
    static func quaternion(alignZTo normal: SIMD3<Float>) -> SIMD4<Float> {
        let n = simd_normalize(normal)
        let z = SIMD3<Float>(0, 0, 1)
        let dot = simd_dot(z, n)
        if dot > 0.9999 { return SIMD4(0, 0, 0, 1) }
        if dot < -0.9999 {
            // 180° around X
            return SIMD4(1, 0, 0, 0)
        }
        let axis = simd_normalize(simd_cross(z, n))
        let angle = acos(dot)
        let s = sin(angle / 2)
        return SIMD4(axis.x * s, axis.y * s, axis.z * s, cos(angle / 2))
    }

    /// Quaternion (x, y, z, w) for rotation around Y axis by `angle` radians.
    static func quaternion(yaw angle: Float) -> SIMD4<Float> {
        let s = sin(angle / 2)
        return SIMD4(0, s, 0, cos(angle / 2))
    }

    static func quaternionMultiply(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
        // Hamilton product, components ordered (x, y, z, w).
        let ax = a.x, ay = a.y, az = a.z, aw = a.w
        let bx = b.x, by = b.y, bz = b.z, bw = b.w
        return SIMD4(
            aw*bx + ax*bw + ay*bz - az*by,
            aw*by - ax*bz + ay*bw + az*bx,
            aw*bz + ax*by - ay*bx + az*bw,
            aw*bw - ax*bx - ay*by - az*bz
        )
    }
}
