import AppKit

/// Minimal "still working" indicator. Tiny ghost-rim chip with just a spinner and an optional
/// status word — no banner, no chrome. Sits in the footer corner so it never obscures content.
@MainActor
final class RefreshBanner: NSView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = Theme.surface.withAlphaComponent(0.55).cgColor
        Theme.applyGhostRim(layer!, color: Theme.accentBlue, rimAlpha: 0.22, glowRadius: 8, glowAlpha: 0.28)
        translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        label.font = Theme.bodyFont(size: 10)
        label.textColor = Theme.textSecondary
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(spinner)
        addSubview(label)
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    func setState(_ state: RefreshState) {
        // Routine 60s polls are surfaced by the pulse orb in the hero panel — surfacing them
        // again as a footer chip just adds visual noise. Show the chip only for the first cold
        // load (the multi-minute parse) so the user sees *why* the popover is empty on launch.
        let isColdStart = state.message.lowercased().contains("first")
        if state.isRefreshing, isColdStart {
            label.stringValue = shortMessage(from: state.message)
            spinner.startAnimation(nil)
            isHidden = false
        } else {
            spinner.stopAnimation(nil)
            isHidden = true
        }
    }

    /// Trim verbose poll messages to a single word so the chip stays small.
    private func shortMessage(from raw: String) -> String {
        if raw.lowercased().contains("first") { return "warming up" }
        if raw.lowercased().contains("parsing") { return "parsing" }
        if raw.isEmpty { return "syncing" }
        return raw.split(separator: " ").prefix(2).joined(separator: " ")
    }
}
