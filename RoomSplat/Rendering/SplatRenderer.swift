import Foundation
import Metal
import MetalKit
import simd

final class SplatRenderer: NSObject {

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!

    private(set) var splats: [Splat] = []
    private var splatBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var indices: [UInt32] = []

    var clearColor: MTLClearColor = MTLClearColorMake(0.04, 0.05, 0.07, 1.0)

    /// World-space target the camera orbits around.
    var orbitTarget: SIMD3<Float> = .zero
    /// Camera spherical coords.
    var orbitYaw:   Float = 0.6
    var orbitPitch: Float = -0.35
    var orbitRadius: Float = 4.5

    init(device: MTLDevice, colorPixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        super.init()
        buildPipeline(colorPixelFormat: colorPixelFormat, depthPixelFormat: depthPixelFormat)
        buildDepthState()
    }

    // MARK: - Public

    func setSplats(_ splats: [Splat]) {
        self.splats = splats
        if !splats.isEmpty {
            splatBuffer = device.makeBuffer(bytes: splats,
                                            length: splats.count * Splat.stride,
                                            options: .storageModeShared)
            indices = (0..<UInt32(splats.count)).map { $0 }
            indexBuffer = device.makeBuffer(length: indices.count * MemoryLayout<UInt32>.stride,
                                            options: .storageModeShared)
        } else {
            splatBuffer = nil
            indexBuffer = nil
            indices = []
        }
        recenterOrbit()
    }

    /// Aim the orbit camera at the splat cloud's centroid and pull back to fit it.
    private func recenterOrbit() {
        guard !splats.isEmpty else {
            orbitTarget = .zero
            orbitRadius = 4.5
            return
        }
        var lo = splats[0].position
        var hi = splats[0].position
        for s in splats {
            lo = simd_min(lo, s.position)
            hi = simd_max(hi, s.position)
        }
        orbitTarget = (lo + hi) * 0.5
        let extent = simd_length(hi - lo)
        orbitRadius = max(2.0, extent * 0.9)
    }

    // MARK: - Setup

    private func buildPipeline(colorPixelFormat: MTLPixelFormat,
                               depthPixelFormat: MTLPixelFormat) {
        let lib = device.makeDefaultLibrary()!
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "splat_vertex")
        desc.fragmentFunction = lib.makeFunction(name: "splat_fragment")

        let color = desc.colorAttachments[0]!
        color.pixelFormat = colorPixelFormat
        color.isBlendingEnabled = true
        // Premultiplied back-to-front: out = src + (1 - src.a) * dst
        color.rgbBlendOperation = .add
        color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        desc.depthAttachmentPixelFormat = depthPixelFormat

        pipeline = try! device.makeRenderPipelineState(descriptor: desc)
    }

    private func buildDepthState() {
        let d = MTLDepthStencilDescriptor()
        // We sort on CPU and blend; don't write depth, but still test so AR/real
        // geometry can occlude. For the splat-only viewer there's no AR depth,
        // so this is effectively a no-op.
        d.isDepthWriteEnabled = false
        d.depthCompareFunction = .always
        depthState = device.makeDepthStencilState(descriptor: d)
    }

    // MARK: - Per-frame

    func render(view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else { return }

        rpd.colorAttachments[0].clearColor = clearColor
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        defer {
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }

        guard let splatBuffer, let indexBuffer, !splats.isEmpty else { return }

        // Camera + matrices
        let drawableSize = view.drawableSize
        let viewport = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        let aspect = viewport.x / viewport.y

        let cameraPos = orbitCameraPosition()
        let viewMatrix = lookAt(eye: cameraPos, center: orbitTarget, up: SIMD3(0, 1, 0))
        let fovY: Float = .pi / 3 // 60°
        let projection = perspective(fovYRadians: fovY, aspect: aspect, near: 0.05, far: 100)
        let vp = projection * viewMatrix

        // Pixel focal lengths derived from FOV + viewport.
        let fy = 0.5 * viewport.y / tan(fovY * 0.5)
        let fx = fy // square pixels
        let focal = SIMD2<Float>(fx, fy)

        // Sort splats back-to-front by view-space depth.
        sortIndices(viewMatrix: viewMatrix)

        // Upload sorted indices.
        let idxPtr = indexBuffer.contents().bindMemory(to: UInt32.self, capacity: indices.count)
        for i in 0..<indices.count { idxPtr[i] = indices[i] }

        var uniforms = SplatUniforms(
            view: viewMatrix,
            projection: projection,
            viewProjection: vp,
            focal: focal,
            viewport: viewport,
            cameraPos: cameraPos,
            _pad0: 0
        )

        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setVertexBuffer(splatBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(indexBuffer, offset: 0, index: 1)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<SplatUniforms>.stride, index: 2)

        enc.drawPrimitives(type: .triangleStrip,
                           vertexStart: 0,
                           vertexCount: 4,
                           instanceCount: splats.count)
    }

    private func sortIndices(viewMatrix: simd_float4x4) {
        // Project each splat's position into view space; sort by z ascending
        // (most negative = farthest, drawn first).
        var keys = [Float](repeating: 0, count: splats.count)
        for i in 0..<splats.count {
            let p = splats[i].position
            let v = viewMatrix * SIMD4<Float>(p.x, p.y, p.z, 1)
            keys[i] = v.z
        }
        // Stable enough; small N. Sort by ascending z.
        indices.sort { keys[Int($0)] < keys[Int($1)] }
    }

    private func orbitCameraPosition() -> SIMD3<Float> {
        let cp = cos(orbitPitch)
        let dir = SIMD3<Float>(
            sin(orbitYaw) * cp,
            sin(orbitPitch),
            cos(orbitYaw) * cp
        )
        return orbitTarget + dir * orbitRadius
    }
}

// MARK: - Math

private func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let f = simd_normalize(center - eye)
    let s = simd_normalize(simd_cross(f, up))
    let u = simd_cross(s, f)

    var M = matrix_identity_float4x4
    M.columns.0 = SIMD4( s.x,  u.x, -f.x, 0)
    M.columns.1 = SIMD4( s.y,  u.y, -f.y, 0)
    M.columns.2 = SIMD4( s.z,  u.z, -f.z, 0)
    M.columns.3 = SIMD4(
        -simd_dot(s, eye),
        -simd_dot(u, eye),
         simd_dot(f, eye),
         1
    )
    return M
}

private func perspective(fovYRadians fovy: Float, aspect: Float,
                         near: Float, far: Float) -> simd_float4x4 {
    let yScale = 1 / tan(fovy * 0.5)
    let xScale = yScale / aspect
    let zRange = near - far
    var M = simd_float4x4(0)
    M.columns.0 = SIMD4(xScale, 0, 0, 0)
    M.columns.1 = SIMD4(0, yScale, 0, 0)
    M.columns.2 = SIMD4(0, 0, (far + near) / zRange, -1)
    M.columns.3 = SIMD4(0, 0, (2 * far * near) / zRange, 0)
    return M
}
