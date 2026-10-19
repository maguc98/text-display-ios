import SwiftUI
import WebKit

@main
struct TextDisplayApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        LocalWebView()
            .ignoresSafeArea()
            .statusBarHidden(true) // 隐藏顶部状态栏，全屏沉浸
    }
}

struct LocalWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        
        // 开启 WebGL 硬件加速（提升网页渲染性能）
        let preferences = WKPreferences()
        preferences.setValue(true, forKey: "webGLEnabled")
        configuration.preferences = preferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        // 禁用安全区留白，让网页彻底贴合屏幕边缘
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        // 加载本地网页
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
