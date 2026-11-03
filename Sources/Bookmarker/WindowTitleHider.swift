import SwiftUI
import AppKit

// Measure the toolbar's real position instead of guessing native toolbar margins.
struct WindowTitleHider: NSViewRepresentable {
    var measuresTrailingEdge = false
    let positionChanged: (CGFloat) -> Void
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {
        view.positionChanged = positionChanged
        view.measuresTrailingEdge = measuresTrailingEdge
        view.configureWindow()
        view.reportPosition()
    }
    static func dismantleNSView(_ view: Surface, coordinator: ()) { view.removeDivider() }
    final class Surface: NSView {
        var positionChanged: ((CGFloat) -> Void)?
        var measuresTrailingEdge = false
        private var lastLeading: CGFloat?
        private var divider: DividerSurface?
        func removeDivider() { divider?.removeFromSuperview(); divider = nil }
        private func updateDivider(at x: CGFloat) {
            guard measuresTrailingEdge, let host = window?.contentView?.superview else { return }
            if divider?.superview !== host {
                removeDivider()
                let line = DividerSurface()
                host.addSubview(line, positioned: .above, relativeTo: nil)
                divider = line
            }
            let point = host.convert(NSPoint(x: x, y: 0), from: nil)
            let pixel = 1 / (window?.backingScaleFactor ?? 2)
            let frame = CGRect(x: (point.x / pixel).rounded() * pixel, y: 0, width: pixel, height: host.bounds.height)
            if divider?.frame != frame { divider?.frame = frame }
        }
        func configureWindow() {
            guard let window else { return }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if window.title != " " { window.title = " " }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configureWindow(); reportPosition() }
        override func layout() { super.layout(); reportPosition() }
        func reportPosition() {
            guard window != nil else { return }
            let frame = convert(bounds, to: nil)
            let leading = measuresTrailingEdge ? frame.maxX : frame.minX
            updateDivider(at: leading)
            guard leading != lastLeading else { return }
            lastLeading = leading
            DispatchQueue.main.async { [weak self] in self?.positionChanged?(leading) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private final class DividerSurface: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}
