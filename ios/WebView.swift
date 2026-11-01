import SwiftUI
import WebKit

struct WebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.userContentController.add(context.coordinator.bridge, name: "sonekk")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.043, green: 0.051, blue: 0.071, alpha: 1)
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false

        context.coordinator.bridge.webView = webView

        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator {
        let bridge = Bridge()
    }
}

@main
struct SonekkChatApp: App {
    var body: some Scene {
        WindowGroup {
            WebView()
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
                .statusBarHidden(false)
        }
    }
}
