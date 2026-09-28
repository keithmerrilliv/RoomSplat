import Foundation
import RoomPlan
import simd

/// Converts a `CapturedRoom` into a cloud of Gaussian splats by sampling each
/// surface with a regular grid and turning every sample into a small,
/// flattened ellipsoid aligned with the surface.
struct SplatGenerator {

    /// Approximate surface samples per meter² (per axis: sqrt of this).
    var samplesPerMeter: Float = 14
    /// In-plane sigma for each splat, world units.
    var inPlaneSigma: Float = 0.045
    /// Normal-direction sigma (thin pancake).
    var normalSigma: Float = 0.012
    /// Color jitter amount, 0…1 of channel.
    var colorJitter: Float = 0.06

    func splats(from room: CapturedRoom) -> [Splat] {
        var rng = SystemRandomNumberGenerator()
        var out: [Splat] = []
        out.reserveCapacity(8000)

        for surface in room.walls {
            tile(surface: surface, color: Palette.wall, into: &out, rng: &rng)
        }
        for surface in room.floors {
            tile(surface: surface, color: Palette.floor, into: &out, rng: &rng)
        }
        // CapturedRoom no longer surfaces ceilings on every iOS version; guard.
        for surface in room.doors {
            tile(surface: surface, color: Palette.door, into: &out, rng: &rng)
        }
        for surface in room.windows {
            tile(surface: surface, color: Palette.window, into: &out, rng: &rng,
                 opacity: 0.55)
        }
        for surface in room.openings {
            tile(surface: surface, color: Palette.opening, into: &out, rng: &rng,
                 opacity: 0.35)
        }
        for object in room.objects {
            tileBox(transform: object.transform,
                    dimensions: object.dimensions,
                    color: Palette.color(for: object.category),
                    into: &out,
                    rng: &rng)
        }

        return out
    }

    // MARK: - Surface tiling

    private func tile(surface: CapturedRoom.Surface,
                      color: SIMD3<Float>,
                      into out: inout [Splat],
                      rng: inout SystemRandomNumberGenerator,
                      opacity: Float = 1.0) {
        let w = surface.dimensions.x
        let h = surface.dimensions.y
        if w <= 0 || h <= 0 { return }

        let nx = max(2, Int((w * samplesPerMeter).rounded()))
        let ny = max(2, Int((h * samplesPerMeter).rounded()))
        let dx = w / Float(nx - 1)
        let dy = h / Float(ny - 1)

        // Surface transform: +X = width, +Y = height, +Z = surface normal.
        let M = surface.transform

        // Splat scale: in-plane × in-plane × thin along normal.
        let scale = SIMD3<Float>(inPlaneSigma, inPlaneSigma, normalSigma)

        // Quaternion from the surface transform's upper 3x3.
        let q = quaternion(from: M)

        for j in 0..<ny {
            for i in 0..<nx {
                let lx = -w * 0.5 + Float(i) * dx
                let ly = -h * 0.5 + Float(j) * dy
                let local = SIMD4<Float>(lx, ly, 0, 1)
                let world = M * local
                let p = SIMD3<Float>(world.x, world.y, world.z)
                let c = jittered(color, amount: colorJitter, rng: &rng)
                out.append(Splat(position: p,
                                 scale: scale,
                                 rotation: q,
                                 color: c,
                                 opacity: opacity))
            }
        }
    }

    private func tileBox(transform M: simd_float4x4,
                         dimensions: SIMD3<Float>,
                         color: SIMD3<Float>,
                         into out: inout [Splat],
                         rng: inout SystemRandomNumberGenerator) {
        let half = dimensions * 0.5
        // Six faces: ±X, ±Y, ±Z. Each face has its own surface frame.
        let faces: [(normal: SIMD3<Float>,
                     u: SIMD3<Float>,
                     v: SIMD3<Float>,
                     size: SIMD2<Float>,
                     center: SIMD3<Float>)] = [
            ( SIMD3(1,0,0),  SIMD3(0,0,1),  SIMD3(0,1,0),  SIMD2(dimensions.z, dimensions.y),  SIMD3( half.x, 0, 0)),
            (-SIMD3(1,0,0),  SIMD3(0,0,-1), SIMD3(0,1,0),  SIMD2(dimensions.z, dimensions.y),  SIMD3(-half.x, 0, 0)),
            ( SIMD3(0,1,0),  SIMD3(1,0,0),  SIMD3(0,0,1),  SIMD2(dimensions.x, dimensions.z),  SIMD3(0,  half.y, 0)),
            (-SIMD3(0,1,0),  SIMD3(1,0,0),  SIMD3(0,0,-1), SIMD2(dimensions.x, dimensions.z),  SIMD3(0, -half.y, 0)),
            ( SIMD3(0,0,1),  SIMD3(1,0,0),  SIMD3(0,1,0),  SIMD2(dimensions.x, dimensions.y),  SIMD3(0, 0,  half.z)),
            (-SIMD3(0,0,1),  SIMD3(-1,0,0), SIMD3(0,1,0),  SIMD2(dimensions.x, dimensions.y),  SIMD3(0, 0, -half.z)),
        ]

        for face in faces {
            let nx = max(2, Int((face.size.x * samplesPerMeter).rounded()))
            let ny = max(2, Int((face.size.y * samplesPerMeter).rounded()))
            let dx = face.size.x / Float(nx - 1)
            let dy = face.size.y / Float(ny - 1)

            // Build a rotation matrix for the face (object-local).
            let R = simd_float3x3(columns: (face.u, face.v, face.normal))
            let Rq = quaternion(fromRotation: R)

            // World rotation = object rotation * face rotation.
            let qObj = quaternion(from: M)
            let q = SplatMath.quaternionMultiply(qObj, Rq)

            for j in 0..<ny {
                for i in 0..<nx {
                    let lx = -face.size.x * 0.5 + Float(i) * dx
                    let ly = -face.size.y * 0.5 + Float(j) * dy
                    let pLocal = face.center + face.u * lx + face.v * ly
                    let pWorld4 = M * SIMD4<Float>(pLocal, 1)
                    let p = SIMD3<Float>(pWorld4.x, pWorld4.y, pWorld4.z)
                    let c = jittered(color, amount: colorJitter, rng: &rng)
                    out.append(Splat(position: p,
                                     scale: SIMD3<Float>(inPlaneSigma, inPlaneSigma, normalSigma),
                                     rotation: q,
                                     color: c))
                }
            }
        }
    }

    // MARK: - Helpers

    private func jittered(_ c: SIMD3<Float>, amount: Float,
                          rng: inout SystemRandomNumberGenerator) -> SIMD3<Float> {
        func n() -> Float { Float.random(in: -amount...amount, using: &rng) }
        return simd_clamp(c + SIMD3(n(), n(), n()), SIMD3(repeating: 0), SIMD3(repeating: 1))
    }

    private func quaternion(from M: simd_float4x4) -> SIMD4<Float> {
        let R = simd_float3x3(columns: (
            SIMD3(M.columns.0.x, M.columns.0.y, M.columns.0.z),
            SIMD3(M.columns.1.x, M.columns.1.y, M.columns.1.z),
            SIMD3(M.columns.2.x, M.columns.2.y, M.columns.2.z)
        ))
        return quaternion(fromRotation: R)
    }

    private func quaternion(fromRotation m: simd_float3x3) -> SIMD4<Float> {
        // Shoemake's method. Columns are basis vectors.
        let m00 = m[0][0], m01 = m[1][0], m02 = m[2][0]
        let m10 = m[0][1], m11 = m[1][1], m12 = m[2][1]
        let m20 = m[0][2], m21 = m[1][2], m22 = m[2][2]
        let trace = m00 + m11 + m22
        if trace > 0 {
            let s = sqrt(trace + 1.0) * 2
            return SIMD4(
                (m21 - m12) / s,
                (m02 - m20) / s,
                (m10 - m01) / s,
                0.25 * s
            )
        } else if m00 > m11 && m00 > m22 {
            let s = sqrt(1.0 + m00 - m11 - m22) * 2
            return SIMD4(
                0.25 * s,
                (m01 + m10) / s,
                (m02 + m20) / s,
                (m21 - m12) / s
            )
        } else if m11 > m22 {
            let s = sqrt(1.0 + m11 - m00 - m22) * 2
            return SIMD4(
                (m01 + m10) / s,
                0.25 * s,
                (m12 + m21) / s,
                (m02 - m20) / s
            )
        } else {
            let s = sqrt(1.0 + m22 - m00 - m11) * 2
            return SIMD4(
                (m02 + m20) / s,
                (m12 + m21) / s,
                0.25 * s,
                (m10 - m01) / s
            )
        }
    }
}

private enum Palette {
    static let wall    = SIMD3<Float>(0.86, 0.84, 0.80)
    static let floor   = SIMD3<Float>(0.45, 0.32, 0.22)
    static let door    = SIMD3<Float>(0.30, 0.18, 0.12)
    static let window  = SIMD3<Float>(0.45, 0.70, 0.95)
    static let opening = SIMD3<Float>(0.65, 0.65, 0.65)

    static func color(for category: CapturedRoom.Object.Category) -> SIMD3<Float> {
        switch category {
        case .bed:           return SIMD3(0.85, 0.55, 0.55)
        case .sofa:          return SIMD3(0.55, 0.45, 0.85)
        case .chair:         return SIMD3(0.85, 0.75, 0.45)
        case .table:         return SIMD3(0.65, 0.45, 0.30)
        case .storage:       return SIMD3(0.55, 0.40, 0.30)
        case .refrigerator:  return SIMD3(0.85, 0.85, 0.90)
        case .stove:         return SIMD3(0.30, 0.30, 0.32)
        case .washerDryer:   return SIMD3(0.80, 0.80, 0.80)
        case .toilet:        return SIMD3(0.95, 0.95, 0.95)
        case .bathtub:       return SIMD3(0.85, 0.90, 0.95)
        case .oven:          return SIMD3(0.20, 0.20, 0.22)
        case .dishwasher:    return SIMD3(0.78, 0.78, 0.82)
        case .sink:          return SIMD3(0.80, 0.85, 0.85)
        case .fireplace:     return SIMD3(0.55, 0.30, 0.20)
        case .television:    return SIMD3(0.10, 0.10, 0.12)
        case .stairs:        return SIMD3(0.50, 0.40, 0.30)
        @unknown default:    return SIMD3(0.70, 0.70, 0.70)
        }
    }
}
