import SwiftUI
import WebKit
import BookmarkCore

struct WebpageReader: View {
    let library: Library
    let bookmark: Bookmark
    @State private var html: String?
    @State private var error: String?
    @State private var retry = UUID()
    var body: some View {
        ZStack {
            // Keep one WKWebView alive while the selection changes.
            ReaderDocument(html: html).opacity(html == nil ? 0 : 1)
            if let error {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass").font(.title2)
                    Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Try Again") { retry = UUID() }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
            } else if html == nil {
                ProgressView("Loading reading view…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(bookmark.id)-\(retry)") {
            error = nil
            html = library.cachedReaderHTML(bookmark.id)
            guard html == nil else { return }
            do {
                let loaded = try await library.readerHTML(bookmark.id, cancelOnDismiss: true)
                try Task.checkCancellation()
                html = loaded
            }
            catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

private struct ReaderDocument: NSViewRepresentable {
    let html: String?
    final class Coordinator { var loadedHTML: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.setAccessibilityLabel("Saved webpage reading view")
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard let html, html != context.coordinator.loadedHTML else { return }
        context.coordinator.loadedHTML = html
        view.loadHTMLString(html, baseURL: nil)
    }
}

@MainActor final class ReadablePageLoader: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    func load(_ url: URL) async throws -> String {
        try Task.checkCancellation()
        defer { timeout?.cancel(); webView?.navigationDelegate = nil; webView?.stopLoading(); webView = nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
                let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 740, height: 900), configuration: config)
                self.webView = view; view.navigationDelegate = self
                view.load(URLRequest(url: url, timeoutInterval: 30))
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(40)) } catch { return }
                    self?.finish(.failure(ReaderError.unavailable))
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = #"""
        (() => {
            const candidates = [...document.querySelectorAll('article, main, [role="main"], .post-content, .entry-content, .article-content')];
            const root = candidates.sort((a,b) => b.innerText.length-a.innerText.length)[0] || document.body;
            if (!root) return '';
            root.querySelectorAll('script,style,nav,header,footer,aside,form,button,iframe,noscript,svg').forEach(e => e.remove());
            const text = (root.innerText || '').trim();
            const gate = (document.title + '\n' + text.slice(0,1000)).toLowerCase();
            if (/are you a robot|checking your browser|verify you are human|complet(?:e|ing) the captcha|just a moment|access denied/.test(gate)) return '';
            return text;
        })()
        """#
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            guard let text = result as? String, text.count >= 80 else { self.finish(.failure(ReaderError.noArticle)); return }
            let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            self.finish(.success("""
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
            <style>:root{color-scheme:light dark}body{margin:0;padding:24px;font:16px/1.75 -apple-system,BlinkMacSystemFont,sans-serif;overflow-wrap:anywhere}main{max-width:65ch;margin:auto;white-space:pre-wrap}</style>
            </head><body><main>\(escaped)</main></body></html>
            """))
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { finish(.failure(ReaderError.unavailable)) }
    }
    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil
        webView?.navigationDelegate = nil; webView?.stopLoading(); webView = nil
        continuation.resume(with: result)
    }
    enum ReaderError: LocalizedError {
        case unavailable, noArticle, missingBookmark
        var errorDescription: String? {
            switch self {
            case .unavailable: "Couldn’t save a readable copy. Try again when online, or use Read original."
            case .noArticle: "This page doesn’t provide readable article text. Use Read original to open it in your browser."
            case .missingBookmark: "This bookmark is no longer in the current library."
            }
        }
    }
}
