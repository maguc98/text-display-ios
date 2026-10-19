import SwiftUI
import WebKit

@main
struct TextDisplayApp: App {
    var body: some Scene {
        WindowGroup {
            MainSwitcherView()
                .ignoresSafeArea()
                .statusBarHidden(true)
        }
    }
}

// 控制切换：默认显示原生版，双击左上角切回网页版
struct MainSwitcherView: View {
    @State private var showNative = true
    
    var body: some View {
        ZStack {
            if showNative {
                NativePosterView()
                    // 双击左上角切回网页
                    .onTapGesture(count: 2) {
                        withAnimation { showNative = false }
                    }
            } else {
                LocalWebView()
                    // 双击左上角切回原生
                    .onTapGesture(count: 2) {
                        withAnimation { showNative = true }
                    }
            }
        }
    }
}

// ==========================================
// 以下是纯 SwiftUI 原生版海报排版
// ==========================================

struct PosterWord: Identifiable {
    let id = UUID()
    let text: String
    var x: CGFloat
    var y: CGFloat
    var size: CGFloat
    var rotation: Double
    var isHero: Bool
    var delay: Double
}

struct NativePosterView: View {
    @State private var words: [PosterWord] = []
    @State private var cameraOffset: CGSize = .zero
    @State private var currentIndex: Int = 0
    @State private var timer: Timer?
    
    let screenW = UIScreen.main.bounds.width
    let screenH = UIScreen.main.bounds.height
    let text = "晚风刚好，你也在"
    
    var body: some View {
        ZStack {
            // 1. 纯原生 Canvas 绘制网格和几何装饰
            Canvas { context, size in
                // 绘制网格线
                var path = Path()
                for i in 1..<10 {
                    path.move(to: CGPoint(x: size.width * CGFloat(i)/10, y: 0))
                    path.addLine(to: CGPoint(x: size.width * CGFloat(i)/10, y: size.height))
                }
                for j in 1..<18 {
                    path.move(to: CGPoint(x: 0, y: size.height * CGFloat(j)/18))
                    path.addLine(to: CGPoint(x: size.width, y: size.height * CGFloat(j)/18))
                }
                context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
                
                // 随机点缀圆环
                let rng = SeededRandom(seed: 42) // 固定随机种子，防止每帧闪烁
                for _ in 0..<6 {
                    let r = CGFloat(rng.next(in: 20...80))
                    let cx = CGFloat(rng.next(in: 0...size.width))
                    let cy = CGFloat(rng.next(in: 0...size.height))
                    let circle = Path(ellipseIn: CGRect(x: cx-r, y: cy-r, width: r*2, height: r*2))
                    context.stroke(circle, with: .color(.white.opacity(0.2)), lineWidth: 1)
                }
                
                // 绘制几条倾斜的弧线
                let arc1 = Path { p in
                    p.move(to: CGPoint(x: -50, y: size.height * 0.3))
                    p.addCurve(to: CGPoint(x: size.width + 50, y: size.height * 0.4),
                               control1: CGPoint(x: size.width * 0.4, y: size.height * 0.1),
                               control2: CGPoint(x: size.width * 0.6, y: size.height * 0.6))
                }
                context.stroke(arc1, with: .color(.white.opacity(0.15)), lineWidth: 1.5)
            }
            .background(
                RadialGradient(colors: [Color(red: 0.15, green: 0.08, blue: 0.2), Color.black],
                               center: .center, startRadius: 0, endRadius: screenW)
            )
            
            // 2. 文字层（跟随着镜头偏移）
            ZStack {
                ForEach(words) { word in
                    Text(word.text)
                        .font(.system(size: word.size, weight: word.isHero ? .black : .medium))
                        .foregroundColor(word.isHero ? .white : .white.opacity(0.6))
                        // 原生发光效果（极快，完全由 GPU 处理）
                        .shadow(color: word.isHero ? .blue.opacity(0.6) : .clear, radius: 15)
                        .rotationEffect(.degrees(word.rotation))
                        // 原生飞入特效：从远处变大飞入，同时模糊到清晰
                        .transition(.asymmetric(
                            insertion: .offset(x: CGFloat.random(in: -300...300), y: CGFloat.random(in: -300...300))
                                        .combined(with: .scale(scale: 1.5))
                                        .combined(with: .opacity),
                            removal: .opacity
                        ))
                        .position(x: word.x, y: word.y)
                }
            }
            // 镜头跟随弹簧动画（纯原生物理引擎，不消耗 CPU 运算）
            .offset(x: cameraOffset.width, y: cameraOffset.height)
            .animation(.spring(response: 1.2, dampingFraction: 0.75), value: cameraOffset)
        }
        .onAppear {
            startPoster()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }
    
    // 排版与运镜逻辑
    func startPoster() {
        words.removeAll()
        let chars = text.map { String($0) }
        
        // 自动排版算法
        for (index, char) in chars.enumerated() {
            // 前两个作为 Hero 大字
            let isHero = index < 2
            
            // 大字大，小字小，形成对比
            let fontSize = isHero ? CGFloat.random(in: 65...90) : CGFloat.random(in: 22...36)
            
            // 散落在屏幕中心附近
            let posX = screenW/2 + CGFloat.random(in: -120...120)
            let posY = screenH/2 + CGFloat.random(in: -180...180)
            
            let word = PosterWord(
                text: char,
                x: posX,
                y: posY,
                size: fontSize,
                rotation: Double.random(in: -15...15),
                isHero: isHero,
                delay: Double(index) * 0.15 // 逐字出场延迟
            )
            words.append(word)
        }
        
        // 触发入场：延迟触发让原生 transition 动起来
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.spring(response: 1.0, dampingFraction: 0.8)) {
                // 改变状态触发动画
            }
        }
        
        // 启动原生定时器，模拟镜头跟拍
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            guard !words.isEmpty else { return }
            let targetWord = words[currentIndex % words.count]
            
            // 计算让目标文字居中的偏移量
            let targetX = screenW/2 - targetWord.x
            let targetY = screenH/2 - targetWord.y
            
            // 加上一点点随机浮动，产生“镜头呼吸感”
            let driftX = CGFloat.random(in: -30...30)
            let driftY = CGFloat.random(in: -30...30)
            
            // 触发原生的物理弹簧动画
            withAnimation(.spring(response: 1.2, dampingFraction: 0.7)) {
                cameraOffset = CGSize(width: targetX + driftX, height: targetY + driftY)
            }
            
            currentIndex += 1
        }
    }
}

// 固定的随机数生成器，防止 Canvas 每帧闪烁
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let val = Double(state >> 33) / Double(1 << 31)
        return range.lowerBound + CGFloat(val) * (range.upperBound - range.lowerBound)
    }
}

// ==========================================
// 原有的网页容器，保持原样
// ==========================================
struct LocalWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        
        // 开启 WebGL 极致加速
        let preferences = WKPreferences()
        preferences.setValue(true, forKey: "webGLEnabled")
        configuration.preferences = preferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
