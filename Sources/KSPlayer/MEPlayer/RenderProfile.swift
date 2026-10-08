//
//  RenderProfile.swift
//  KSPlayer
//
//  分阶段耗时打点：定位高分辨率硬解掉帧到底卡在哪一段
//  （解码出帧速率 / CVPixelBuffer 取纹理 / encode+commit / 等 nextDrawable / GPU 实际执行）。
//  只做统计、不改变任何行为；App 侧读 `snapshot` 显示在诊断浮层。
//

import Foundation
import QuartzCore

/// 内部所有状态都在锁里读写，可以安全跨线程共享
public final class KSRenderProfile: @unchecked Sendable {
    public static let shared = KSRenderProfile()

    public struct Snapshot {
        /// 每秒提交给 VideoToolbox 的 packet 数（≈源帧率说明喂得上）
        public var submitFPS: Double = 0
        /// 解码器每秒交付到出帧队列的视频帧数（明显低于 submitFPS 说明卡在硬解本身）
        public var decodedFPS: Double = 0
        /// 单次 submit → 解码回调 的平均延迟
        public var decodeLatencyMs: Double = 0
        /// 取帧时出帧队列的积压深度（持续接近容量说明被消费端反压）
        public var outputQueueCount: Int = 0
        /// 每秒提交的 Metal 绘制次数（含无新帧的视角重绘）
        public var drawFPS: Double = 0
        /// 绘制里真正带新视频帧的比例
        public var newFrameRatio: Double = 0
        /// 单次 CVPixelBuffer → MTLTexture 的获取耗时
        public var textureMs: Double = 0
        /// encode + commit 的 CPU 耗时
        public var encodeMs: Double = 0
        /// 等 `nextDrawable` 的阻塞耗时
        public var drawableWaitMs: Double = 0
        /// commandBuffer 在 GPU 上的执行耗时（commit 到 completed 回调）
        public var gpuMs: Double = 0
        /// 一次 display tick 进入 draw 到离开的总耗时
        public var tickMs: Double = 0
    }

    private struct Bucket {
        private var total: Double = 0
        private var count: Int = 0
        mutating func add(_ seconds: Double) {
            total += seconds
            count += 1
        }

        var averageMs: Double { count > 0 ? total * 1000 / Double(count) : 0 }
        mutating func reset() {
            total = 0
            count = 0
        }
    }

    private let lock = NSLock()
    private var windowStart = CACurrentMediaTime()
    private var submits = 0
    private var decodedFrames = 0
    private var draws = 0
    private var newFrameDraws = 0
    private var decodeLatency = Bucket()
    private var lastOutputQueueCount = 0
    private var texture = Bucket()
    private var encode = Bucket()
    private var drawableWait = Bucket()
    private var gpu = Bucket()
    private var tick = Bucket()
    private var latest = Snapshot()

    public var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    public func noteDecodeSubmit() {
        mutate { $0.submits += 1 }
    }

    public func addDecodeLatency(_ seconds: Double) {
        mutate { $0.decodeLatency.add(seconds) }
    }

    public func noteOutputQueue(count: Int) {
        mutate { $0.lastOutputQueueCount = count }
    }

    public func noteDecodedFrame() {
        mutate { $0.decodedFrames += 1 }
    }

    public func noteDraw(newFrame: Bool) {
        mutate { profile in
            profile.draws += 1
            if newFrame {
                profile.newFrameDraws += 1
            }
        }
    }

    public func addTexture(_ seconds: Double) {
        mutate { $0.texture.add(seconds) }
    }

    public func addEncode(_ seconds: Double) {
        mutate { $0.encode.add(seconds) }
    }

    public func addDrawableWait(_ seconds: Double) {
        mutate { $0.drawableWait.add(seconds) }
    }

    public func addGPU(_ seconds: Double) {
        mutate { $0.gpu.add(seconds) }
    }

    public func addTick(_ seconds: Double) {
        mutate { $0.tick.add(seconds) }
    }

    /// 所有打点都可能在解码线程/GPU 回调线程上触发，统一加锁；窗口每满 1s 汇总一次
    private func mutate(_ body: (KSRenderProfile) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(self)
        let now = CACurrentMediaTime()
        let elapsed = now - windowStart
        guard elapsed >= 1 else { return }
        var snapshot = Snapshot()
        snapshot.submitFPS = Double(submits) / elapsed
        snapshot.decodedFPS = Double(decodedFrames) / elapsed
        snapshot.decodeLatencyMs = decodeLatency.averageMs
        snapshot.outputQueueCount = lastOutputQueueCount
        snapshot.drawFPS = Double(draws) / elapsed
        snapshot.newFrameRatio = draws > 0 ? Double(newFrameDraws) / Double(draws) : 0
        snapshot.textureMs = texture.averageMs
        snapshot.encodeMs = encode.averageMs
        snapshot.drawableWaitMs = drawableWait.averageMs
        snapshot.gpuMs = gpu.averageMs
        snapshot.tickMs = tick.averageMs
        latest = snapshot
        windowStart = now
        submits = 0
        decodedFrames = 0
        draws = 0
        newFrameDraws = 0
        decodeLatency.reset()
        texture.reset()
        encode.reset()
        drawableWait.reset()
        gpu.reset()
        tick.reset()
    }
}
