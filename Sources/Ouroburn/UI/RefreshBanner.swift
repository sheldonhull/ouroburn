import AppKit

/// Pill-shaped banner that floats above the popover content during a poll. Hidden when idle
/// so it doesn't clutter the layout. Visible on the first cold launch (where the parser may
/// take a couple minutes) so the user can tell the app is working rather than wedged.
@MainActor
final class RefreshBanner: NSView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = Theme.surfaceMuted.withAlphaComponent(0.92).cgColor
        layer?.borderColor = Theme.divider.cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = Theme.accentBlue.cgColor
        layer?.shadowRadius = 8
        layer?.shadowOpacity = 0.25
        layer?.shadowOffset = .zero
        translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        label.font = Theme.bodyFont(size: 11)
        label.textColor = Theme.textPrimary
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(spinner)
        addSubview(label)
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func setState(_ state: RefreshState) {
        if state.isRefreshing {
            label.stringValue = state.message
            spinner.startAnimation(nil)
            isHidden = false
        } else {
            spinner.stopAnimation(nil)
            isHidden = true
        }
    }
}
