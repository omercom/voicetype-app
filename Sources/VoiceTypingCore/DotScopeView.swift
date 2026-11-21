import AppKit
import Metal
import QuartzCore
import simd

struct DotScopeUniforms {
    var resolution: SIMD2<Float>
    var backingScale: Float
    var width: Float
    var height: Float
    var opacity: Float
    var scale: Float
    var softness: Float
    var pitch: Float
    var columns: Float
    var rows: Float
    var glow: Float
    var grid: Float
    var live: Float
    var cool: Float
    var dotsOnly: Float
    var ripplePhase: Float
    var rippleIntensity: Float
    var rimShimmerPhase: Float
    var harmonicHeat: Float
    var base: SIMD4<Float>
    var core: SIMD4<Float>
    var plate: SIMD4<Float>
    var rim: SIMD4<Float>
    var shadow: SIMD4<Float>
}

enum DotScopeMetalPipeline {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    static let commandQueue: MTLCommandQueue? = device?.makeCommandQueue()
    static let pipelineState: MTLRenderPipelineState? = buildPipeline()

    static func warmAsync() {
        DispatchQueue.global(qos: .utility).async {
            _ = pipelineState
            _ = commandQueue
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Varyings {
        float4 position [[position]];
        float2 uv;
    };

    struct DotUniforms {
        float2 resolution;
        float backingScale;
        float width;
        float height;
        float opacity;
        float scale;
        float softness;
        float pitch;
        float columns;
        float rows;
        float glow;
        float grid;
        float live;
        float cool;
        float dotsOnly;
        float ripplePhase;
        float rippleIntensity;
        float rimShimmerPhase;
        float harmonicHeat;
        float4 base;
        float4 core;
        float4 plate;
        float4 rim;
        float4 shadow;
    };

    static float sstep(float edge0, float edge1, float x) {
        float t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    static float rounded_box(float2 point, float2 halfSize, float radius) {
        float2 q = abs(point) - halfSize + radius;
        return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
    }

    static float coverage(float dist, float softness) {
        return sstep(softness, -softness, dist);
    }

    static void composite(thread float4& dst, float3 color, float alphaIn) {
        float alpha = clamp(alphaIn, 0.0, 1.0);
        dst = float4(color * alpha + dst.rgb * (1.0 - alpha), alpha + dst.a * (1.0 - alpha));
    }

    static float4 dithered(float4 resultIn, float2 pos) {
        float4 result = resultIn;
        if (result.a > 0.0) {
            float2 pixel = floor(pos);
            float n1 = fract(52.9829189 * fract(dot(pixel, float2(0.06711056, 0.00583715))));
            float n2 = fract(52.9829189 * fract(dot(pixel + float2(1.0, 0.0), float2(0.06711056, 0.00583715))));
            float dither = ((n1 - n2) / 255.0) * result.a;
            result = float4(clamp(result.rgb + float3(dither), float3(0.0), float3(result.a)), result.a);
        }
        return result;
    }

    vertex Varyings dot_scope_vertex(uint vid [[vertex_id]]) {
        float2 positions[3] = {
            float2(-1.0, -1.0),
            float2(3.0, -1.0),
            float2(-1.0, 3.0)
        };
        float2 p = positions[vid];
        Varyings out;
        out.position = float4(p, 0.0, 1.0);
        out.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
        return out;
    }

    fragment float4 dot_scope_fragment(
        Varyings in [[stage_in]],
        constant DotUniforms& u [[buffer(0)]],
        constant float2* dots [[buffer(1)]]
    ) {
        float2 position = in.uv * u.resolution;
        float scale = max(u.scale, 0.001);
        float2 point = ((in.uv * u.resolution - u.resolution * 0.5) / max(u.backingScale, 1.0)) / scale;
        float pixel = 1.0 / (max(u.backingScale, 1.0) * scale);
        float softness = max(u.softness, 0.0);
        float aa = pixel * 0.75 + softness * 0.72;
        float2 halfSize = float2(u.width, u.height) * 0.5;
        float radius = u.height * 0.5;
        float dist = rounded_box(point, halfSize, radius);
        bool dotsOnly = u.dotsOnly > 0.5;

        float4 result = float4(0.0);
        float shape = dotsOnly ? 1.0 : coverage(dist, aa);

        if (!dotsOnly) {
            float shadowDist = rounded_box(point - float2(0.0, 2.2), halfSize, radius);
            composite(result, u.shadow.rgb, u.shadow.a * (0.5 - 0.5 * tanh(shadowDist / 5.5)));
            composite(result, u.plate.rgb, u.plate.a * shape);

            // Çift aşamalı cam kenar ışığı (Hex rim + hareketli speküler parıltı)
            float rimMask = coverage(abs(dist) - 0.35, aa);
            float angle = atan2(point.y, point.x);
            float glint = 0.5 + 0.5 * cos(angle - u.rimShimmerPhase);
            float glintStrength = pow(glint, 5.0) * (0.14 + 0.24 * max(u.cool, u.live));
            float3 rimColor = mix(u.rim.rgb, u.core.rgb, 0.45 * glintStrength);
            composite(result, rimColor, (u.rim.a + glintStrength) * rimMask);
        }

        // Anizotropik yatay fosfor halesi (vokal enerji ve işlemeye duyarlı)
        if (!dotsOnly && u.glow > 0.01) {
            float2 scaled = float2(point.x / (36.0 + 24.0 * u.glow), point.y / (12.0 + 5.0 * u.glow));
            float t = clamp(length(scaled), 0.0, 1.0);
            float strength = (0.16 + 0.12 * u.harmonicHeat) * min(1.35, u.glow);
            float3 middle = mix(u.base.rgb, u.core.rgb, 0.55);
            composite(result, mix(middle, u.base.rgb, t), strength * (1.0 - t) * shape);
        }

        // Akustik dalga halkası (konuşma başlangıcında ve tamamlama anında merkezden yayılır)
        if (u.rippleIntensity > 0.005) {
            float rNorm = abs(point.x) / max(halfSize.x, 1.0);
            float yNorm = abs(point.y) / max(halfSize.y, 1.0);
            float ringDist = abs(rNorm - u.ripplePhase);
            float ringAlpha = u.rippleIntensity * 0.14 * exp(-(ringDist * ringDist) / 0.015) * (1.0 - 0.4 * yNorm);
            composite(result, u.core.rgb, ringAlpha * shape);
        }

        int columns = int(u.columns + 0.5);
        int rows = int(u.rows + 0.5);
        float pitch = u.pitch;
        float2 centerOffset = float2(float(columns) - 1.0, float(rows) - 1.0) * 0.5;
        int i0 = int(round(point.x / pitch + centerOffset.x));
        int j0 = int(round(point.y / pitch + centerOffset.y));

        float unlit = 0.075;
        float full = 0.96;
        float curve = 0.86;
        float presence = 0.55 + 0.45 * max(u.live, u.cool);

        for (int dj = -1; dj <= 1; dj++) {
            for (int di = -1; di <= 1; di++) {
                int i = i0 + di;
                int j = j0 + dj;
                if (i < 0 || j < 0 || i >= columns || j >= rows) {
                    continue;
                }
                float2 center = (float2(float(i), float(j)) - centerOffset) * pitch;
                float cap = -rounded_box(center, halfSize, radius);
                float mask = dotsOnly ? 1.0 : sstep(1.2, 4.4, cap);
                if (mask <= 0.0) {
                    continue;
                }
                float2 val = dots[j * columns + i];
                float power = max(val.x, 1e-5);
                float fresh = val.y;
                float rowRatio = abs(center.y) / max(halfSize.y, 1.0);
                float floorAlpha = unlit * (1.0 - 0.65 * sstep(0.35, 0.95, rowRatio)) * presence * u.grid;
                if (dotsOnly) {
                    floorAlpha = (j == rows / 2) ? 0.22 * presence * u.grid : 0.04 * presence * u.grid;
                }
                float alpha = floorAlpha + (full - floorAlpha) * pow(power, curve * mix(1.4, 1.0, fresh));
                float dotRadius = (0.24 + 0.18 * pow(power, 0.6))
                    * mix(1.0, mix(0.82, 1.0, fresh), sstep(0.03, 0.2, power)) * pitch;
                float coreWeight = clamp(power * power * 1.12, 0.0, 0.92) * mix(0.35, 1.0, fresh);
                float3 color = mix(u.base.rgb, u.core.rgb, coreWeight);
                float fromCenter = length(point - center);
                if (power > 0.05) {
                    float haloStrength = dotsOnly ? 0.10 : 0.15;
                    composite(
                        result,
                        color,
                        haloStrength * power * power * mask * shape * coverage(fromCenter - dotRadius * 2.1, aa)
                    );
                }
                composite(result, color, alpha * mask * shape * coverage(fromCenter - dotRadius, aa));
            }
        }

        result *= u.opacity;
        return dithered(result, position);
    }
    """

    private static func buildPipeline() -> MTLRenderPipelineState? {
        guard let device else { return nil }
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            guard let vertexFn = library.makeFunction(name: "dot_scope_vertex"),
                  let fragmentFn = library.makeFunction(name: "dot_scope_fragment") else {
                return nil
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFn
            desc.fragmentFunction = fragmentFn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].rgbBlendOperation = .add
            desc.colorAttachments[0].alphaBlendOperation = .add
            desc.colorAttachments[0].sourceRGBBlendFactor = .one
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("[DotScopeMetal] Shader derlenemedi, CoreGraphics yedeği kullanılıyor: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Metal GPU + CoreGraphics yedekli Hex Dot Scope görünümü.
public final class DotScopeView: NSView {
    public let simulation: DotScopeSimulation
    public private(set) var stage: DotScopeStage = .recording
    public var dotsOnly: Bool = false {
        didSet { needsDisplay = true }
    }

    private var metalLayer: CAMetalLayer?
    private var dotBuffer: MTLBuffer?
    private var currentLoudnessDB: Float = -120.0
    private var lastRenderTime: TimeInterval?

    public static var isMetalAvailable: Bool {
        DotScopeMetalPipeline.pipelineState != nil && DotScopeMetalPipeline.commandQueue != nil
    }

    public static func warmMetalPipelineAsync() {
        DotScopeMetalPipeline.warmAsync()
    }

    public init(frame frameRect: NSRect, tuning: DotScopeTuning = .compactDefault, dotsOnly: Bool = false) {
        self.simulation = DotScopeSimulation(tuning: tuning)
        self.dotsOnly = dotsOnly
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setupMetalLayerIfPossible()
        simulation.advance(dt: 0.05, stage: .recording, visible: true, loudnessDB: -120.0, reduceMotion: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) kullanılmaz")
    }

    public override var isOpaque: Bool { false }

    private func setupMetalLayerIfPossible() {
        guard let device = DotScopeMetalPipeline.device,
              DotScopeMetalPipeline.pipelineState != nil else {
            return
        }
        let ml = CAMetalLayer()
        ml.device = device
        ml.pixelFormat = .bgra8Unorm
        ml.isOpaque = false
        ml.backgroundColor = NSColor.clear.cgColor
        ml.presentsWithTransaction = false
        ml.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        ml.frame = bounds
        layer?.addSublayer(ml)
        metalLayer = ml
        let bufferLength = max(MemoryLayout<SIMD2<Float>>.stride, DotScopeTuning.maxDots * MemoryLayout<SIMD2<Float>>.stride)
        dotBuffer = device.makeBuffer(length: bufferLength, options: .storageModeShared)
    }

    public override func layout() {
        super.layout()
        updateMetalDrawableSize()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMetalDrawableSize()
    }

    private func updateMetalDrawableSize() {
        guard let ml = metalLayer else { return }
        let scale = max(1.0, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ml.frame = bounds
        ml.contentsScale = scale
        let pw = max(1.0, round(bounds.width * scale))
        let ph = max(1.0, round(bounds.height * scale))
        ml.drawableSize = CGSize(width: pw, height: ph)
        CATransaction.commit()
    }

    public func configure(
        tuning: DotScopeTuning? = nil,
        processingStyle: DotScopeProcessingStyle? = nil,
        accentMode: DotScopeAccentMode? = nil,
        dotsOnly: Bool? = nil
    ) {
        var next = tuning ?? simulation.tuning
        if let processingStyle {
            next.processingStyle = processingStyle
        }
        if next != simulation.tuning {
            simulation.updateTuning(next)
        }
        if let accentMode {
            simulation.accentMode = accentMode
        }
        if let dotsOnly {
            self.dotsOnly = dotsOnly
        }
        if !isHidden {
            renderNow()
        }
    }

    public func reset(reduceMotion: Bool) {
        stage = .recording
        currentLoudnessDB = -120.0
        lastRenderTime = nil
        simulation.restart(reduceMotion: reduceMotion)
        renderNow()
    }

    public func setStage(_ nextStage: DotScopeStage) {
        stage = nextStage
        if nextStage != .recording {
            currentLoudnessDB = -120.0
        }
    }

    public func pushAudioLevel(dBFS: Float) {
        currentLoudnessDB = dBFS.isFinite ? dBFS : -120.0
    }

    public func step(dt: TimeInterval? = nil, visible: Bool = true, reduceMotion: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        let delta: Float
        if let dt {
            delta = Float(dt)
        } else if let prev = lastRenderTime {
            delta = Float(min(0.1, max(0.0, now - prev)))
        } else {
            delta = 1.0 / 60.0
        }
        lastRenderTime = now
        simulation.advance(
            dt: max(DotScopeSimulation.fixedStep, delta),
            stage: stage,
            visible: visible,
            loudnessDB: currentLoudnessDB,
            reduceMotion: reduceMotion
        )
        renderNow()
    }

    public func renderNow() {
        if window != nil, metalLayer != nil, bounds.width > 0, bounds.height > 0 {
            if renderMetalFrame() {
                return
            }
        }
        needsDisplay = true
    }

    @discardableResult
    private func renderMetalFrame() -> Bool {
        guard let ml = metalLayer,
              let pipeline = DotScopeMetalPipeline.pipelineState,
              let queue = DotScopeMetalPipeline.commandQueue else {
            return false
        }
        if ml.drawableSize.width < 1 || ml.drawableSize.height < 1 {
            updateMetalDrawableSize()
        }
        guard let drawable = ml.nextDrawable() else { return false }

        let pose = simulation.pose()
        let tuning = simulation.tuning
        let scale = Float(ml.contentsScale)
        var uniforms = DotScopeUniforms(
            resolution: SIMD2<Float>(Float(drawable.texture.width), Float(drawable.texture.height)),
            backingScale: scale,
            width: min(Float(bounds.width), pose.width),
            height: min(Float(bounds.height), pose.height),
            opacity: pose.opacity,
            scale: pose.scale,
            softness: pose.softness,
            pitch: tuning.spacing,
            columns: Float(tuning.columns),
            rows: Float(tuning.rows),
            glow: pose.glow,
            grid: pose.grid,
            live: pose.live,
            cool: pose.cool,
            dotsOnly: dotsOnly ? 1.0 : 0.0,
            ripplePhase: pose.ripplePhase,
            rippleIntensity: pose.rippleIntensity,
            rimShimmerPhase: pose.rimShimmerPhase,
            harmonicHeat: pose.harmonicHeat,
            base: SIMD4<Float>(pose.palette.base, 1.0),
            core: SIMD4<Float>(pose.palette.core, 1.0),
            plate: pose.palette.plate,
            rim: pose.palette.rim,
            shadow: pose.palette.shadow
        )

        var dotData = simulation.dots
        if dotData.isEmpty {
            dotData = [SIMD2<Float>(0, 0)]
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let cmd = queue.makeCommandBuffer(),
              let encoder = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            return false
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DotScopeUniforms>.stride, index: 0)
        if let dotBuffer {
            let stride = MemoryLayout<SIMD2<Float>>.stride
            let copyCount = min(dotData.count, dotBuffer.length / stride)
            if copyCount > 0 {
                dotData.withUnsafeBytes { raw in
                    if let src = raw.baseAddress {
                        memcpy(dotBuffer.contents(), src, copyCount * stride)
                    }
                }
            }
            encoder.setFragmentBuffer(dotBuffer, offset: 0, index: 1)
        } else {
            dotData.withUnsafeBytes { raw in
                if let ptr = raw.baseAddress {
                    encoder.setFragmentBytes(ptr, length: min(raw.count, 4096), index: 1)
                }
            }
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        return true
    }

    public override func draw(_ dirtyRect: NSRect) {
        // Ekranda aktif Metal katmanı varsa CoreGraphics ikinci kez çizmesin;
        // ancak bitmap snapshot / cacheDisplay (isDrawingToScreen == false) veya
        // Metal yokken CoreGraphics birebir görseli çizer.
        if NSGraphicsContext.current?.isDrawingToScreen == true && metalLayer != nil && window != nil {
            return
        }
        drawCoreGraphicsFallback(in: bounds)
    }

    private func drawCoreGraphicsFallback(in rect: NSRect) {
        guard rect.width > 0, rect.height > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pose = simulation.pose()
        let tuning = simulation.tuning
        let alpha = CGFloat(pose.opacity)
        guard alpha > 0.01 else { return }

        ctx.saveGState()
        ctx.setAlpha(alpha)

        let plateW = min(rect.width, CGFloat(pose.width))
        let plateH = min(rect.height, CGFloat(pose.height))
        let plateRect = CGRect(
            x: rect.midX - plateW * 0.5,
            y: rect.midY - plateH * 0.5,
            width: plateW,
            height: plateH
        )
        let corner = plateH * 0.5

        if !dotsOnly {
            let platePath = CGPath(roundedRect: plateRect, cornerWidth: corner, cornerHeight: corner, transform: nil)
            ctx.setFillColor(NSColor(
                calibratedRed: CGFloat(pose.palette.plate.x),
                green: CGFloat(pose.palette.plate.y),
                blue: CGFloat(pose.palette.plate.z),
                alpha: CGFloat(pose.palette.plate.w)
            ).cgColor)
            ctx.addPath(platePath)
            ctx.fillPath()

            ctx.setStrokeColor(NSColor(
                calibratedRed: CGFloat(pose.palette.rim.x),
                green: CGFloat(pose.palette.rim.y),
                blue: CGFloat(pose.palette.rim.z),
                alpha: CGFloat(pose.palette.rim.w)
            ).cgColor)
            ctx.setLineWidth(0.75)
            ctx.addPath(platePath)
            ctx.strokePath()
        }

        let columns = tuning.columns
        let rows = tuning.rows
        let pitch = CGFloat(tuning.spacing)
        let dots = simulation.dots
        let offsetX = CGFloat(columns - 1) * 0.5
        let offsetY = CGFloat(rows - 1) * 0.5
        let presence = 0.55 + 0.45 * max(pose.live, pose.cool)

        for j in 0..<rows {
            for i in 0..<columns {
                let idx = j * columns + i
                guard idx < dots.count else { continue }
                let val = dots[idx]
                let power = max(val.x, 1e-5)
                let fresh = val.y
                let cx = rect.midX + (CGFloat(i) - offsetX) * pitch
                let cy = rect.midY - (CGFloat(j) - offsetY) * pitch
                if !dotsOnly && !plateRect.insetBy(dx: 2.0, dy: 2.0).contains(CGPoint(x: cx, y: cy)) {
                    continue
                }

                let rowRatio = abs(cy - rect.midY) / max(1.0, plateH * 0.5)
                let floorAlpha: Float
                if dotsOnly {
                    floorAlpha = (j == rows / 2 ? 0.22 : 0.04) * presence * pose.grid
                } else {
                    floorAlpha = 0.075 * max(0.0, 1.0 - 0.65 * Float(rowRatio)) * presence * pose.grid
                }
                let dotAlpha = floorAlpha + (0.96 - floorAlpha) * pow(power, 0.86 * (1.4 - 0.4 * fresh))
                let dotRadius = CGFloat((0.24 + 0.18 * pow(power, 0.6)) * (1.0 - 0.18 * (1.0 - fresh) * min(1.0, max(0.0, (power - 0.03) / 0.17)))) * pitch
                let coreWeight = min(0.92, max(0.0, power * power * 1.12)) * (0.35 + 0.65 * fresh)
                let rgb = pose.palette.base + (pose.palette.core - pose.palette.base) * coreWeight

                if power > 0.05 {
                    let haloR = dotRadius * 2.0
                    let haloRect = CGRect(x: cx - haloR, y: cy - haloR, width: haloR * 2, height: haloR * 2)
                    ctx.setFillColor(NSColor(
                        calibratedRed: CGFloat(rgb.x),
                        green: CGFloat(rgb.y),
                        blue: CGFloat(rgb.z),
                        alpha: CGFloat((dotsOnly ? 0.10 : 0.15) * power * power)
                    ).cgColor)
                    ctx.fillEllipse(in: haloRect)
                }

                let dotRect = CGRect(x: cx - dotRadius, y: cy - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                ctx.setFillColor(NSColor(
                    calibratedRed: CGFloat(rgb.x),
                    green: CGFloat(rgb.y),
                    blue: CGFloat(rgb.z),
                    alpha: CGFloat(dotAlpha)
                ).cgColor)
                ctx.fillEllipse(in: dotRect)
            }
        }
        ctx.restoreGState()
    }
}
