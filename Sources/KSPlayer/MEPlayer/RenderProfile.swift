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

public final class KSRenderProfile {
    public static let shared = KSRenderProfile()

    public struct Snapshot {
        /// 解码器每秒交付到出帧队列的视频帧数（≈60 说明解码跟得上）
        public var decodedFPS: Double = 0
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
    private var decodedFrames = 0
    private var draws = 0
    private var newFrameDraws = 0
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

    public func noteDecodedFrame() {
        mutate { profile in
            profile.decodedFrames += 1
        }
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
        snapshot.decodedFPS = Double(decodedFrames) / elapsed
        snapshot.drawFPS = Double(draws) / elapsed
        snapshot.newFrameRatio = draws > 0 ? Double(newFrameDraws) / Double(draws) : 0
        snapshot.textureMs = texture.averageMs
        snapshot.encodeMs = encode.averageMs
        snapshot.drawableWaitMs = drawableWait.averageMs
        snapshot.gpuMs = gpu.averageMs
        snapshot.tickMs = tick.averageMs
        latest = snapshot
        windowStart = now
        decodedFrames = 0
        draws = 0
        newFrameDraws = 0
        texture.reset()
        encode.reset()
        drawableWait.reset()
        gpu.reset()
        tick.reset()
    }
}
