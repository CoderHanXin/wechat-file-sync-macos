import AppKit

/// Keep the small settings palette adaptive without adding a theme preference.
private func settingsColor(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
        NSColor(white: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light, alpha: 1)
    }
}

final class SettingsSurface: NSView {
    enum Kind { case content, sidebar, group }
    private let kind: Kind
    init(_ kind: Kind) { self.kind = kind; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor
        switch kind {
        case .content: color = settingsColor(1, 0.105)
        case .sidebar: color = settingsColor(0.953, 0.14)
        case .group: color = settingsColor(0.969, 0.155)
        }
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: kind == .group ? 10 : 0, yRadius: kind == .group ? 10 : 0).fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// A settings navigation row, with an explicit selection background rather than a toolbar button bezel.
final class SettingsNavigationButton: NSButton {
    private let symbol: String
    init(title: String, symbol: String, target: AnyObject?, action: Selector) {
        self.symbol = symbol
        super.init(frame: .zero)
        self.title = title; self.target = target; self.action = action
        setButtonType(.pushOnPushOff); isBordered = false; focusRingType = .exterior
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 168, height: 38) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        if selected {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let iconColor: NSColor = selected ? .white : .systemBlue
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [iconColor]))
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)?.draw(in: NSRect(x: 11, y: (bounds.height - 17) / 2, width: 17, height: 17))
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .medium),
            .foregroundColor: selected ? NSColor.white : NSColor.labelColor])
        text.draw(at: NSPoint(x: 37, y: (bounds.height - text.size().height) / 2))
    }
}

final class SettingsDocument: NSView {
    override var isFlipped: Bool { true }
}
