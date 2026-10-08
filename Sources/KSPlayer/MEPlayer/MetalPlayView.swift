//
//  MetalPlayView.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/11.
//

import AVFoundation
import Combine
import CoreMedia
#if canImport(MetalKit)
import MetalKit
#endif
public protocol DisplayLayerDelegate: NSObjectProtocol {
    func change(displayLayer: AVSampleBufferDisplayLayer)
}

public protocol VideoOutput: FrameOutput {
    var displayLayerDelegate: DisplayLayerDelegate? { get set }
    var options: KSOptions { get set }
    var displayLayer: AVSampleBufferDisplayLayer { get }
    var pixelBuffer: PixelBufferProtocol? { get }
    init(options: KSOptions)
    func invalidate()
    func readNextFrame()
}

public final class MetalPlayView: UIView, VideoOutput {
    public var displayLayer: AVSampleBufferDisplayLayer {
        displayView.displayLayer
    }

    private var isDovi: Bool = false
    private var formatDescription: CMFormatDescription? {
        didSet {
            options.updateVideo(refreshRate: fps, isDovi: isDovi, formatDescription: formatDescription)
        }
    }

    private var fps = Float(60) {
        didSet {
            if fps != oldValue {
                if KSOptions.preferredFrame {
                    let preferredFramesPerSecond = ceil(fps)
                    if #available(iOS 15.0, tvOS 15.0, macOS 14.0, *) {
                        if options.display == .plane {
                            displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: preferredFramesPerSecond, maximum: 2 * preferredFramesPerSecond, __preferred: preferredFramesPerSecond)
                        } else {
                            // VR 球面：渲染帧率与视频帧率解耦，视角转动始终 60-120Hz
                            displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, __preferred: 120)
                        }
                    } else {
                        displayLink.preferredFramesPerSecond = Int(preferredFramesPerSecond) << 1
                    }
                }
                options.updateVideo(refreshRate: fps, isDovi: isDovi, formatDescription: formatDescription)
            }
        }
    }

    public private(set) var pixelBuffer: PixelBufferProtocol?
    /// 用displayLink会导致锁屏无法draw，
    /// 用DispatchSourceTimer的话，在播放4k视频的时候repeat的时间会变长,
    /// 用MTKView的draw(in:)也是不行，会卡顿
    private var displayLink: CADisplayLink!
//    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    public var options: KSOptions
    public weak var renderSource: OutputRenderSourceDelegate?
    // AVSampleBufferAudioRenderer AVSampleBufferRenderSynchronizer AVSampleBufferDisplayLayer
    var displayView = AVSampleBufferDisplayView() {
        didSet {
            displayLayerDelegate?.change(displayLayer: displayView.displayLayer)
        }
    }

    private let metalView = MetalView()
    private var lastVRSize = CGSize(width: 1280, height: 720)
    public weak var displayLayerDelegate: DisplayLayerDelegate?
    public init(options: KSOptions) {
        self.options = options
        super.init(frame: .zero)
        addSubview(displayView)
        addSubview(metalView)
        metalView.isHidden = true
        //        displayLink = CADisplayLink(block: renderFrame)
        displayLink = CADisplayLink(target: self, selector: #selector(renderFrame))
        if options.display != .plane, #available(iOS 15.0, tvOS 15.0, macOS 14.0, *) {
            displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, __preferred: 120)
        }
        // 一定要用common。不然在视频上面操作view的话，那就会卡顿了。
        displayLink.add(to: .main, forMode: .common)
        pause()
    }

    public func play() {
        displayLink.isPaused = false
    }

    public func pause() {
        displayLink.isPaused = true
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        subview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            subview.leftAnchor.constraint(equalTo: leftAnchor),
            subview.topAnchor.constraint(equalTo: topAnchor),
            subview.bottomAnchor.constraint(equalTo: bottomAnchor),
            subview.rightAnchor.constraint(equalTo: rightAnchor),
        ])
    }

    override public var contentMode: UIViewContentMode {
        didSet {
            metalView.contentMode = contentMode
            switch contentMode {
            case .scaleToFill:
                displayView.displayLayer.videoGravity = .resize
            case .scaleAspectFit, .center:
                displayView.displayLayer.videoGravity = .resizeAspect
            case .scaleAspectFill:
                displayView.displayLayer.videoGravity = .resizeAspectFill
            default:
                break
            }
        }
    }

    #if canImport(UIKit)
    override public func touchesMoved(_ touches: Set<UITouch>, with: UIEvent?) {
        if options.display == .plane {
            super.touchesMoved(touches, with: with)
        } else {
            options.display.touchesMoved(touch: touches.first!)
        }
    }
    #else
    override public func touchesMoved(with event: NSEvent) {
        if options.display == .plane {
            super.touchesMoved(with: event)
        } else {
            options.display.touchesMoved(touch: event.allTouches().first!)
        }
    }
    #endif

    public func flush() {
        pixelBuffer = nil
        if displayView.isHidden {
            metalView.clear()
        } else {
            displayView.displayLayer.flushAndRemoveImage()
        }
    }

    public func invalidate() {
        displayLink.invalidate()
    }

    public func readNextFrame() {
        draw(force: true)
    }

//    deinit {
//        print()
//    }
}

extension MetalPlayView {
    @objc private func renderFrame() {
        draw(force: false)
    }

    private func draw(force: Bool) {
        autoreleasepool {
            guard let frame = renderSource?.getVideoOutputRender(force: force) else {
                // VR 球面：没有新视频帧也用上一帧重绘，视角转动与视频帧率解耦
                if options.display != .plane, displayView.isHidden, let pixelBuffer, !KSOptions.vrPauseRerender {
                    metalView.draw(pixelBuffer: pixelBuffer, display: options.display, size: lastVRSize)
                }
                return
            }
            pixelBuffer = frame.corePixelBuffer
            guard let pixelBuffer else {
                return
            }
            isDovi = frame.isDovi
            fps = frame.fps
            let cmtime = frame.cmtime
            let par = pixelBuffer.size
            let sar = pixelBuffer.aspectRatio
            if let pixelBuffer = pixelBuffer.cvPixelBuffer, options.isUseDisplayLayer() {
                if displayView.isHidden {
                    displayView.isHidden = false
                    metalView.isHidden = true
                    metalView.clear()
                }
                if let dar = options.customizeDar(sar: sar, par: par) {
                    pixelBuffer.aspectRatio = CGSize(width: dar.width, height: dar.height * par.width / par.height)
                }
                checkFormatDescription(pixelBuffer: pixelBuffer)
                set(pixelBuffer: pixelBuffer, time: cmtime)
            } else {
                if !displayView.isHidden {
                    displayView.isHidden = true
                    metalView.isHidden = false
                    displayView.displayLayer.flushAndRemoveImage()
                }
                let size: CGSize
                if options.display == .plane {
                    if let dar = options.customizeDar(sar: sar, par: par) {
                        size = CGSize(width: par.width, height: par.width * dar.height / dar.width)
                    } else {
                        size = CGSize(width: par.width, height: par.height * sar.height / sar.width)
                    }
                } else {
                    // sceneSize 是窗口点坐标；drawableSize 需要物理像素，
                    // 乘 nativeScale 才不会按 1x 低分辨率渲染（清晰度劣化根因）
                    // vrRenderScale 再降一档用于换回 GPU 余量（8K 硬解丢帧）
                    let scale = (window?.screen.nativeScale ?? 1) * CGFloat(max(0.25, min(1, KSOptions.vrRenderScale)))
                    size = CGSize(width: max(1, (KSOptions.sceneSize.width * scale).rounded()),
                                  height: max(1, (KSOptions.sceneSize.height * scale).rounded()))
                    lastVRSize = size
                    KSOptions.vrDrawableSize = size
                }
                checkFormatDescription(pixelBuffer: pixelBuffer)
                #if !os(tvOS)
                if #available(iOS 16, *) {
                    metalView.metalLayer.edrMetadata = frame.edrMetadata
                }
                #endif
                metalView.draw(pixelBuffer: pixelBuffer, display: options.display, size: size)
            }
            renderSource?.setVideo(time: cmtime, position: frame.position)
        }
    }

    private func checkFormatDescription(pixelBuffer: PixelBufferProtocol) {
        if formatDescription == nil || !pixelBuffer.matche(formatDescription: formatDescription!) {
            if formatDescription != nil {
                displayView.removeFromSuperview()
                displayView = AVSampleBufferDisplayView()
                displayView.frame = frame
                addSubview(displayView)
            }
            formatDescription = pixelBuffer.formatDescription
        }
    }

    private func set(pixelBuffer: CVPixelBuffer, time: CMTime) {
        guard let formatDescription else { return }
        displayView.enqueue(imageBuffer: pixelBuffer, formatDescription: formatDescription, time: time)
    }
}

class MetalView: UIView {
    private let render = MetalRender()
    #if canImport(UIKit)
    override public class var layerClass: AnyClass { CAMetalLayer.self }
    #endif
    var metalLayer: CAMetalLayer {
        // swiftlint:disable force_cast
        layer as! CAMetalLayer
        // swiftlint:enable force_cast
    }

    init() {
        super.init(frame: .zero)
        #if !canImport(UIKit)
        layer = CAMetalLayer()
        #endif
        metalLayer.device = MetalRender.device
        metalLayer.framebufferOnly = true
//        metalLayer.displaySyncEnabled = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func clear() {
        if let drawable = metalLayer.nextDrawable() {
            render.clear(drawable: drawable)
        }
    }

    func draw(pixelBuffer: PixelBufferProtocol, display: DisplayEnum, size: CGSize) {
        metalLayer.drawableSize = size
        metalLayer.pixelFormat = KSOptions.colorPixelFormat(bitDepth: pixelBuffer.bitDepth)
        let colorspace = pixelBuffer.colorspace
        if colorspace != nil, metalLayer.colorspace != colorspace {
            metalLayer.colorspace = colorspace
            KSLog("[video] CAMetalLayer colorspace \(String(describing: colorspace))")
            #if !os(tvOS)
            if #available(iOS 16.0, *) {
                if let name = colorspace?.name, name != CGColorSpace.sRGB {
                    #if os(macOS)
                    metalLayer.wantsExtendedDynamicRangeContent = window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0 > 1.0
                    #else
                    metalLayer.wantsExtendedDynamicRangeContent = true
                    #endif
                } else {
                    metalLayer.wantsExtendedDynamicRangeContent = false
                }
                KSLog("[video] CAMetalLayer wantsExtendedDynamicRangeContent \(metalLayer.wantsExtendedDynamicRangeContent)")
            }
            #endif
        }
        guard let drawable = metalLayer.nextDrawable() else {
            KSLog("[video] CAMetalLayer not readyForMoreMediaData")
            return
        }
        render.draw(pixelBuffer: pixelBuffer, display: display, drawable: drawable)
    }
}

class AVSampleBufferDisplayView: UIView {
    #if canImport(UIKit)
    override public class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    #endif
    var displayLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable force_cast
        layer as! AVSampleBufferDisplayLayer
        // swiftlint:enable force_cast
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if !canImport(UIKit)
        layer = AVSampleBufferDisplayLayer()
        #endif
        var controlTimebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &controlTimebase)
        if let controlTimebase {
            displayLayer.controlTimebase = controlTimebase
            CMTimebaseSetTime(controlTimebase, time: .zero)
            CMTimebaseSetRate(controlTimebase, rate: 1.0)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func enqueue(imageBuffer: CVPixelBuffer, formatDescription: CMVideoFormatDescription, time: CMTime) {
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        //        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescription: formatDescription, sampleTiming: [timing], sampleBufferOut: &sampleBuffer)
        if let sampleBuffer {
            if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary], let dic = attachmentsArray.first {
                dic[kCMSampleAttachmentKey_DisplayImmediately] = true
            }
            if displayLayer.isReadyForMoreMediaData {
                displayLayer.enqueue(sampleBuffer)
            } else {
                KSLog("[video] AVSampleBufferDisplayLayer not readyForMoreMediaData. video time \(time), controlTime \(displayLayer.timebase.time) ")
                displayLayer.enqueue(sampleBuffer)
            }
            if #available(macOS 11.0, iOS 14, tvOS 14, *) {
                if displayLayer.requiresFlushToResumeDecoding {
                    KSLog("[video] AVSampleBufferDisplayLayer requiresFlushToResumeDecoding so flush")
                    displayLayer.flush()
                }
            }
            if displayLayer.status == .failed {
                KSLog("[video] AVSampleBufferDisplayLayer status failed so flush")
                displayLayer.flush()
                //                    if let error = displayLayer.error as NSError?, error.code == -11847 {
                //                        displayLayer.stopRequestingMediaData()
                //                    }
            }
        }
    }
}

#if os(macOS)
import CoreVideo

class CADisplayLink {
    private let displayLink: CVDisplayLink
    private var runloop: RunLoop?
    private var mode = RunLoop.Mode.default
    public var preferredFramesPerSecond = 60
    @available(macOS 12.0, *)
    public var preferredFrameRateRange: CAFrameRateRange {
        get {
            CAFrameRateRange()
        }
        set {}
    }

    public var timestamp: TimeInterval {
        var timeStamp = CVTimeStamp()
        if CVDisplayLinkGetCurrentTime(displayLink, &timeStamp) == kCVReturnSuccess, (timeStamp.flags & CVTimeStampFlags.hostTimeValid.rawValue) != 0 {
            return TimeInterval(timeStamp.hostTime / NSEC_PER_SEC)
        }
        return 0
    }

    public var duration: TimeInterval {
        CVDisplayLinkGetActualOutputVideoRefreshPeriod(displayLink)
    }

    public var targetTimestamp: TimeInterval {
        duration + timestamp
    }

    public var isPaused: Bool {
        get {
            !CVDisplayLinkIsRunning(displayLink)
        }
        set {
            if newValue {
                CVDisplayLinkStop(displayLink)
            } else {
                CVDisplayLinkStart(displayLink)
            }
        }
    }

    public init(target: NSObject, selector: Selector) {
        var displayLink: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        self.displayLink = displayLink!
        CVDisplayLinkSetOutputHandler(self.displayLink) { [weak self] _, _, _, _, _ in
            guard let self else { return kCVReturnSuccess }
            self.runloop?.perform(selector, target: target, argument: self, order: 0, modes: [self.mode])
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(self.displayLink)
    }

    public init(block: @escaping (() -> Void)) {
        var displayLink: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        self.displayLink = displayLink!
        CVDisplayLinkSetOutputHandler(self.displayLink) { _, _, _, _, _ in
            block()
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(self.displayLink)
    }

    open func add(to runloop: RunLoop, forMode mode: RunLoop.Mode) {
        self.runloop = runloop
        self.mode = mode
    }

    public func invalidate() {
        isPaused = true
        runloop = nil
        CVDisplayLinkSetOutputHandler(displayLink) { _, _, _, _, _ in
            kCVReturnError
        }
    }
}
#endif
