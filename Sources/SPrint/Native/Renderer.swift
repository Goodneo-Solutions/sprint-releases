import CSPrint
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Draws PDF and HTML pages for the core: a PDF's first page through Core
/// Graphics, an HTML page through an off-screen WKWebView laid out at the
/// printer's width (one point per dot). The core then scales, dithers and
/// encodes the page, so the printer gets the Go core's pixels.
enum PageRenderer {
    /// Draws `image` (or the PDF page) into a white RGB bitmap `width` pixels wide.
    static func png(width: Int, height: Int, draw: (CGContext) -> Void) -> Data? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(ctx)
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    static func pdf(_ data: Data, widthDots: Int) throws -> Data {
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider),
              let page = doc.page(at: 1)
        else { throw SPrintError(message: "the PDF has no page") }
        let box = page.getBoxRect(.mediaBox)
        let width = widthDots > 0 ? widthDots : Int(box.width * 203 / 72)
        let height = max(1, Int((box.height * CGFloat(width) / box.width).rounded()))
        let scale = CGFloat(width) / box.width
        guard let png = png(width: width, height: height, draw: { ctx in
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
        }) else { throw SPrintError(message: "the PDF page could not be drawn") }
        return png
    }

    static func html(_ html: String, baseURL: String, widthDots: Int, heightDots: Int) throws -> Data {
        if Thread.isMainThread {
            throw SPrintError(message: "HTML is rendered on the main thread: call print from a background task")
        }
        let width = widthDots > 0 ? widthDots : 576
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<Data, SPrintError> = .failure(SPrintError(message: "HTML rendering timed out"))
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                HTMLSnapshot.shared.render(html: html, baseURL: URL(string: baseURL), width: width, height: heightDots) {
                    result = $0
                    done.signal()
                }
            }
        }
        if done.wait(timeout: .now() + 90) == .timedOut { throw SPrintError(message: "HTML rendering timed out") }
        return try result.get()
    }
}

/// The one off-screen web view (main thread only).
@MainActor
final class HTMLSnapshot: NSObject, WKNavigationDelegate {
    static let shared = HTMLSnapshot()
    private var pending: [(WKWebView, Int, Int, (Result<Data, SPrintError>) -> Void)] = []

    func render(html: String, baseURL: URL?, width: Int, height: Int, done: @escaping (Result<Data, SPrintError>) -> Void) {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: max(height, 10)))
        view.navigationDelegate = self
        pending.append((view, width, height, done))
        view.loadHTMLString(html, baseURL: baseURL)
    }

    private func finish(_ view: WKWebView, _ r: Result<Data, SPrintError>) {
        guard let i = pending.firstIndex(where: { $0.0 === view }) else { return }
        let done = pending.remove(at: i).3
        done(r)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard let entry = pending.first(where: { $0.0 === webView }) else { return }
            let (width, fixedHeight) = (entry.1, entry.2)
            webView.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") { value, _ in
                MainActor.assumeIsolated {
                    let content = (value as? NSNumber)?.intValue ?? 0
                    let height = fixedHeight > 0 ? fixedHeight : min(max(content, 1), 20000)
                    webView.frame = CGRect(x: 0, y: 0, width: width, height: height)
                    let config = WKSnapshotConfiguration()
                    config.rect = CGRect(x: 0, y: 0, width: width, height: height)
                    config.snapshotWidth = NSNumber(value: width)
                    webView.takeSnapshot(with: config) { image, error in
                        MainActor.assumeIsolated {
                            guard let image, let cg = Self.cgImage(image) else {
                                self.finish(webView, .failure(SPrintError(message: "render html: \(error?.localizedDescription ?? "no image")")))
                                return
                            }
                            let png = PageRenderer.png(width: width, height: height) { ctx in
                                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
                            }
                            self.finish(webView, png.map { .success($0) } ?? .failure(SPrintError(message: "render html: no image")))
                        }
                    }
                }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { finish(webView, .failure(SPrintError(message: "render html: \(message)"))) }
    }

    #if canImport(UIKit)
    static func cgImage(_ image: UIImage) -> CGImage? { image.cgImage }
    #else
    static func cgImage(_ image: NSImage) -> CGImage? { image.cgImage(forProposedRect: nil, context: nil, hints: nil) }
    #endif
}

private let renderCallback: sprint_render_cb = { kind, data, len, baseURL, width, height, png, pngLen, err, _ in
    let bytes = data.map { Data(bytes: $0, count: len) } ?? Data()
    do {
        let out: Data
        if kind == 0 {
            out = try PageRenderer.pdf(bytes, widthDots: Int(width))
        } else {
            out = try PageRenderer.html(String(decoding: bytes, as: UTF8.self), baseURL: baseURL.map { String(cString: $0) } ?? "",
                                        widthDots: Int(width), heightDots: Int(height))
        }
        let p = malloc(out.count)!.assumingMemoryBound(to: UInt8.self)
        out.copyBytes(to: p, count: out.count)
        png?.pointee = p
        pngLen?.pointee = out.count
        return 0
    } catch {
        err?.pointee = strdup(String(describing: error))
        return 1
    }
}

/// The platform layer the core uses on Apple devices.
public enum NativeLayer {
    /// Registers the page renderer (PDF through Core Graphics, HTML through
    /// WebKit) and, on iOS, the Bluetooth LE transport (CoreBluetooth) and the
    /// mDNS browser and advertiser of LAN peer printing (Bonjour) with the
    /// core. Call once at start-up. On macOS the core keeps its own Bluetooth,
    /// BLE and USB transports and its own mDNS (see ``useBonjourForPeers(_:)``);
    /// the renderer replaces its headless-browser one.
    /// Print from a background task: HTML is drawn on the main thread.
    public static func register() {
        _ = sprint_set_renderer(renderCallback, nil)
        #if os(iOS)
        BLETransport.register()
        BonjourMDNS.register(true)
        #endif
    }

    /// Browses and advertises LAN peers through Bonjour (true) or through the
    /// core's own mDNS (false; macOS only — iOS has no other). iOS uses
    /// Bonjour from ``register()``; a sandboxed macOS app may prefer it too,
    /// as the system's mDNS service then does the multicast.
    public static func useBonjourForPeers(_ on: Bool = true) {
        BonjourMDNS.register(on)
    }
}
