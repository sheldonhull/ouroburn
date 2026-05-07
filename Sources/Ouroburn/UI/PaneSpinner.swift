import AppKit

/// Compact loading state for a single popover pane. Pairs an NSProgressIndicator with a small
/// label so the user knows *what* is loading rather than seeing a bare spinner.
@MainActor
final class PaneSpinner: NSView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    init(message: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = Theme.backgroundDeep.withAlphaComponent(0.85).cgColor
        layer?.borderColor = Theme.divider.cgColor
        layer?.borderWidth = 1

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = message
        label.font = Theme.bodyFont(size: 11)
        label.textColor = Theme.textSecondary
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
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    func setLoading(_ loading: Bool) {
        if loading {
            spinner.startAnimation(nil)
            isHidden = false
        } else {
            spinner.stopAnimation(nil)
            isHidden = true
        }
    }
}
