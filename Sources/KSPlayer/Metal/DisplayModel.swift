//
//  DisplayModel.swift
//  KSPlayer-iOS
//
//  Created by kintan on 2020/1/11.
//

import Foundation
import Metal
import simd
#if canImport(UIKit)
import UIKit
#endif

extension DisplayEnum {
    private static var planeDisplay = PlaneDisplayModel()
    private static var vrDiaplay = VRDisplayModel()
    private static var vr180Display = VR180DisplayModel()
    private static var vrBoxDiaplay = VRBoxDisplayModel()

    func set(encoder: MTLRenderCommandEncoder) {
        switch self {
        case .plane:
            DisplayEnum.planeDisplay.set(encoder: encoder)
        case .vr:
            DisplayEnum.vrDiaplay.set(encoder: encoder)
        case .vr180:
            DisplayEnum.vr180Display.set(encoder: encoder)
        case .vrBox:
            DisplayEnum.vrBoxDiaplay.set(encoder: encoder)
        }
    }

    func pipeline(planeCount: Int, bitDepth: Int32) -> MTLRenderPipelineState {
        switch self {
        case .plane:
            return DisplayEnum.planeDisplay.pipeline(planeCount: planeCount, bitDepth: bitDepth)
        case .vr:
            return DisplayEnum.vrDiaplay.pipeline(planeCount: planeCount, bitDepth: bitDepth)
        case .vr180:
            return DisplayEnum.vr180Display.pipeline(planeCount: planeCount, bitDepth: bitDepth)
        case .vrBox:
            return DisplayEnum.vrBoxDiaplay.pipeline(planeCount: planeCount, bitDepth: bitDepth)
        }
    }

    func touchesMoved(touch: UITouch) {
        switch self {
        case .vr, .vr180:
            if self == .vr {
                DisplayEnum.vrDiaplay.touchesMoved(touch: touch)
            } else {
                DisplayEnum.vr180Display.touchesMoved(touch: touch)
            }
        case .vrBox:
            DisplayEnum.vrBoxDiaplay.touchesMoved(touch: touch)
        default:
            break
        }
    }
}

private class PlaneDisplayModel {
    private lazy var yuv = MetalRender.makePipelineState(fragmentFunction: "displayYUVTexture")
    private lazy var yuvp010LE = MetalRender.makePipelineState(fragmentFunction: "displayYUVTexture", bitDepth: 10)
    private lazy var nv12 = MetalRender.makePipelineState(fragmentFunction: "displayNV12Texture")
    private lazy var p010LE = MetalRender.makePipelineState(fragmentFunction: "displayNV12Texture", bitDepth: 10)
    private lazy var bgra = MetalRender.makePipelineState(fragmentFunction: "displayTexture")
    let indexCount: Int
    let indexType = MTLIndexType.uint16
    let primitiveType = MTLPrimitiveType.triangleStrip
    let indexBuffer: MTLBuffer
    let posBuffer: MTLBuffer?
    let uvBuffer: MTLBuffer?

    fileprivate init() {
        let (indices, positions, uvs) = PlaneDisplayModel.genSphere()
        let device = MetalRender.device
        indexCount = indices.count
        indexBuffer = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt16>.size * indexCount)!
        posBuffer = device.makeBuffer(bytes: positions, length: MemoryLayout<simd_float4>.size * positions.count)
        uvBuffer = device.makeBuffer(bytes: uvs, length: MemoryLayout<simd_float2>.size * uvs.count)
    }

    private class func genSphere() -> ([UInt16], [simd_float4], [simd_float2]) {
        // 通过 Self.uvMapU 动态派发，子类（180°）可改变水平 UV 映射
        let indices: [UInt16] = [0, 1, 2, 3]
        let positions: [simd_float4] = [
            [-1.0, -1.0, 0.0, 1.0],
            [-1.0, 1.0, 0.0, 1.0],
            [1.0, -1.0, 0.0, 1.0],
            [1.0, 1.0, 0.0, 1.0],
        ]
        let uvs: [simd_float2] = [
            [0.0, 1.0],
            [0.0, 0.0],
            [1.0, 1.0],
            [1.0, 0.0],
        ]
        return (indices, positions, uvs)
    }

    func set(encoder: MTLRenderCommandEncoder) {
        encoder.setFrontFacing(.clockwise)
        encoder.setVertexBuffer(posBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uvBuffer, offset: 0, index: 1)
        encoder.drawIndexedPrimitives(type: primitiveType, indexCount: indexCount, indexType: indexType, indexBuffer: indexBuffer, indexBufferOffset: 0)
    }

    func pipeline(planeCount: Int, bitDepth: Int32) -> MTLRenderPipelineState {
        switch planeCount {
        case 3:
            if bitDepth == 10 {
                return yuvp010LE
            } else {
                return yuv
            }
        case 2:
            if bitDepth == 10 {
                return p010LE
            } else {
                return nv12
            }
        case 1:
            return bgra
        default:
            return bgra
        }
    }
}

@MainActor
private class SphereDisplayModel {
    private lazy var yuv = MetalRender.makePipelineState(fragmentFunction: "displayYUVTexture", isSphere: true)
    private lazy var yuvp010LE = MetalRender.makePipelineState(fragmentFunction: "displayYUVTexture", isSphere: true, bitDepth: 10)
    private lazy var nv12 = MetalRender.makePipelineState(fragmentFunction: "displayNV12Texture", isSphere: true)
    private lazy var p010LE = MetalRender.makePipelineState(fragmentFunction: "displayNV12Texture", isSphere: true, bitDepth: 10)
    private lazy var bgra = MetalRender.makePipelineState(fragmentFunction: "displayTexture", isSphere: true)
    private var fingerRotationX = Float(0)
    private var fingerRotationY = Float(0)
    fileprivate var modelViewMatrix = matrix_identity_float4x4
    let indexCount: Int
    let indexType = MTLIndexType.uint16
    let primitiveType = MTLPrimitiveType.triangle
    let indexBuffer: MTLBuffer
    let posBuffer: MTLBuffer?
    let uvBuffer: MTLBuffer?
    /// 水平 UV 映射钩子：默认恒等；180° 半球模式重写为 (u-0.5)*2
    class func uvMapU(_ u: Float) -> Float { u }

    @MainActor
    fileprivate required init() {
        let (indices, positions, uvs) = Self.genSphere()
        let device = MetalRender.device
        indexCount = indices.count
        indexBuffer = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt16>.size * indexCount)!
        posBuffer = device.makeBuffer(bytes: positions, length: MemoryLayout<simd_float4>.size * positions.count)
        uvBuffer = device.makeBuffer(bytes: uvs, length: MemoryLayout<simd_float2>.size * uvs.count)
        #if canImport(UIKit) && canImport(CoreMotion)
        if KSOptions.enableSensor {
            MotionSensor.shared.start()
        }
        #endif
    }

    func set(encoder: MTLRenderCommandEncoder) {
        encoder.setFrontFacing(.clockwise)
        encoder.setVertexBuffer(posBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uvBuffer, offset: 0, index: 1)
        #if canImport(UIKit) && canImport(CoreMotion)
        if let yaw = KSOptions.vrYaw, let pitch = KSOptions.vrPitch {
            modelViewMatrix = matrix_identity_float4x4.rotateX(radians: pitch).rotateY(radians: yaw)
        } else if KSOptions.enableSensor, let matrix = MotionSensor.shared.matrix() {
            modelViewMatrix = matrix
        }
        #endif
    }

    @MainActor
    func touchesMoved(touch: UITouch) {
        #if canImport(UIKit)
        let view = touch.view
        #else
        let view: UIView? = nil
        #endif
        var distX = Float(touch.location(in: view).x - touch.previousLocation(in: view).x)
        var distY = Float(touch.location(in: view).y - touch.previousLocation(in: view).y)
        distX *= 0.005
        distY *= 0.005
        fingerRotationX -= distY * 60 / 100
        fingerRotationY -= distX * 60 / 100
        modelViewMatrix = matrix_identity_float4x4.rotateX(radians: fingerRotationX).rotateY(radians: fingerRotationY)
    }

    func reset() {
        fingerRotationX = 0
        fingerRotationY = 0
        modelViewMatrix = matrix_identity_float4x4
    }

    private class func genSphere() -> ([UInt16], [simd_float4], [simd_float2]) {
        // 通过 Self.uvMapU 动态派发，子类（180°）可改变水平 UV 映射
        let slicesCount = UInt16(200)
        let parallelsCount = slicesCount / 2
        let indicesCount = Int(slicesCount) * Int(parallelsCount) * 6
        var indices = [UInt16](repeating: 0, count: indicesCount)
        var positions = [simd_float4]()
        var uvs = [simd_float2]()
        var runCount = 0
        let radius = Float(1.0)
        let step = (2.0 * Float.pi) / Float(slicesCount)
        var i = UInt16(0)
        while i <= parallelsCount {
            var j = UInt16(0)
            while j <= slicesCount {
                let vertex0 = radius * sinf(step * Float(i)) * cosf(step * Float(j))
                let vertex1 = radius * cosf(step * Float(i))
                let vertex2 = radius * sinf(step * Float(i)) * sinf(step * Float(j))
                let vertex3 = Float(1.0)
                let vertex4 = Float(j) / Float(slicesCount)
                let vertex5 = Float(i) / Float(parallelsCount)
                positions.append([vertex0, vertex1, vertex2, vertex3])
                uvs.append([Self.uvMapU(vertex4), vertex5])
                if i < parallelsCount, j < slicesCount {
                    indices[runCount] = i * (slicesCount + 1) + j
                    runCount += 1
                    indices[runCount] = UInt16((i + 1) * (slicesCount + 1) + j)
                    runCount += 1
                    indices[runCount] = UInt16((i + 1) * (slicesCount + 1) + (j + 1))
                    runCount += 1
                    indices[runCount] = UInt16(i * (slicesCount + 1) + j)
                    runCount += 1
                    indices[runCount] = UInt16((i + 1) * (slicesCount + 1) + (j + 1))
                    runCount += 1
                    indices[runCount] = UInt16(i * (slicesCount + 1) + (j + 1))
                    runCount += 1
                }
                j += 1
            }
            i += 1
        }
        return (indices, positions, uvs)
    }

    func pipeline(planeCount: Int, bitDepth: Int32) -> MTLRenderPipelineState {
        switch planeCount {
        case 3:
            if bitDepth == 10 {
                return yuvp010LE
            } else {
                return yuv
            }
        case 2:
            if bitDepth == 10 {
                return p010LE
            } else {
                return nv12
            }
        case 1:
            return bgra
        default:
            return bgra
        }
    }
}

private class VRDisplayModel: SphereDisplayModel {
    private var modelViewProjectionMatrix = matrix_identity_float4x4
    private var appliedFov: Float = 0

    override required init() {
        super.init()
    }

    /// FOV 或窗口尺寸变化时重建投影矩阵
    func updateProjectionIfNeeded() {
        let fov = KSOptions.vrFov
        let size = KSOptions.sceneSize
        let aspect = Float(size.width / size.height)
        if fov != appliedFov || lastAspect != aspect {
            appliedFov = fov
            lastAspect = aspect
            let projectionMatrix = simd_float4x4(perspective: fov, aspect: aspect, nearZ: 0.1, farZ: 400.0)
            let viewMatrix = simd_float4x4(lookAt: SIMD3<Float>.zero, center: [0, 0, -1000], up: [0, 1, 0])
            modelViewProjectionMatrix = projectionMatrix * viewMatrix
        }
    }
    private var lastAspect: Float = 0

    override func set(encoder: MTLRenderCommandEncoder) {
        updateProjectionIfNeeded()
        super.set(encoder: encoder)
        var matrix = modelViewProjectionMatrix * modelViewMatrix
        let matrixBuffer = MetalRender.device.makeBuffer(bytes: &matrix, length: MemoryLayout<simd_float4x4>.size)
        encoder.setVertexBuffer(matrixBuffer, offset: 0, index: 2)
        encoder.drawIndexedPrimitives(type: primitiveType, indexCount: indexCount, indexType: indexType, indexBuffer: indexBuffer, indexBufferOffset: 0)
    }
}

private class VRBoxDisplayModel: SphereDisplayModel {
    private var modelViewProjectionMatrixLeft = matrix_identity_float4x4
    private var modelViewProjectionMatrixRight = matrix_identity_float4x4
    private var appliedFov: Float = 0
    override required init() {
        super.init()
    }

    private func updateProjectionIfNeeded() {
        let fov = KSOptions.vrFov
        if fov != appliedFov {
            appliedFov = fov
            let size = KSOptions.sceneSize
            let aspect = Float(size.width / size.height) / 2
            let viewMatrixLeft = simd_float4x4(lookAt: [-0.012, 0, 0], center: [0, 0, -1000], up: [0, 1, 0])
            let viewMatrixRight = simd_float4x4(lookAt: [0.012, 0, 0], center: [0, 0, -1000], up: [0, 1, 0])
            let projectionMatrix = simd_float4x4(perspective: fov, aspect: aspect, nearZ: 0.1, farZ: 400.0)
            modelViewProjectionMatrixLeft = projectionMatrix * viewMatrixLeft
            modelViewProjectionMatrixRight = projectionMatrix * viewMatrixRight
        }
    }

    override func set(encoder: MTLRenderCommandEncoder) {
        updateProjectionIfNeeded()
        super.set(encoder: encoder)
        // 视口单位是 drawable 像素，必须用 vrDrawableSize（含 nativeScale 与渲染缩放），
        // 用 sceneSize 点坐标会把两眼画面缩到左下角一小块
        let layerSize = KSOptions.vrDrawableSize
        let width = Double(layerSize.width / 2)
        [(modelViewProjectionMatrixLeft, MTLViewport(originX: 0, originY: 0, width: width, height: Double(layerSize.height), znear: 0, zfar: 0)),
         (modelViewProjectionMatrixRight, MTLViewport(originX: width, originY: 0, width: width, height: Double(layerSize.height), znear: 0, zfar: 0))].forEach { modelViewProjectionMatrix, viewport in
            encoder.setViewport(viewport)
            var matrix = modelViewProjectionMatrix * modelViewMatrix
            let matrixBuffer = MetalRender.device.makeBuffer(bytes: &matrix, length: MemoryLayout<simd_float4x4>.size)
            encoder.setVertexBuffer(matrixBuffer, offset: 0, index: 2)
            encoder.drawIndexedPrimitives(type: primitiveType, indexCount: indexCount, indexType: indexType, indexBuffer: indexBuffer, indexBufferOffset: 0)
        }
    }
}

/// VR180：等距柱状 180°×180° 内容铺满前半球。
/// 球面网格正面中心在 u=0.75（-z 方向），前半球对应 u∈[0.5,1.0]，
/// 将视频纹理 u∈[0,1] 线性映射到该区间；后半球采样边缘（不可见区域）。
private final class VR180DisplayModel: VRDisplayModel {
    override class func uvMapU(_ u: Float) -> Float {
        (u - 0.5) * 2
    }
}
