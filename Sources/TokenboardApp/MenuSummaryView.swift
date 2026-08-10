import AppKit

struct MenuSummaryContent: Equatable, Sendable {
    let contextTitle: String
    let visualRecencyTitle: String
    let accessibilityRecencyTitle: String
    let tokenTitle: String
    let apiValueTitle: String

    var accessibilitySummary: String {
        "\(contextTitle). \(tokenTitle). \(apiValueTitle). \(accessibilityRecencyTitle)."
    }

    func updatingRecency(
        visualTitle: String,
        accessibilityTitle: String
    ) -> MenuSummaryContent {
        MenuSummaryContent(
            contextTitle: contextTitle,
            visualRecencyTitle: visualTitle,
            accessibilityRecencyTitle: accessibilityTitle,
            tokenTitle: tokenTitle,
            apiValueTitle: apiValueTitle
        )
    }
}

@MainActor
final class MenuSummaryView: NSView {
    private enum Metrics {
        static let width: CGFloat = 280
        static let height: CGFloat = 76
        static let horizontalInset: CGFloat = 14
        static let verticalInset: CGFloat = 10
        static let contextSpacing: CGFloat = 8
        static let lineSpacing: CGFloat = 5
    }

    private let contextLabel = NSTextField(labelWithString: "")
    private let recencyLabel = NSTextField(labelWithString: "")
    private let tokenLabel = NSTextField(labelWithString: "")
    private let apiValueLabel = NSTextField(labelWithString: "")
    private(set) var content: MenuSummaryContent

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.width, height: Metrics.height)
    }

    init(content: MenuSummaryContent) {
        self.content = content
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: Metrics.width,
            height: Metrics.height
        ))
        configureLayout()
        update(content: content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func update(content: MenuSummaryContent) {
        self.content = content
        contextLabel.stringValue = content.contextTitle.uppercased()
        recencyLabel.stringValue = content.visualRecencyTitle.uppercased()
        tokenLabel.stringValue = content.tokenTitle
        apiValueLabel.stringValue = content.apiValueTitle
        setAccessibilityLabel(content.accessibilitySummary)
    }

    func updateRecency(visualTitle: String, accessibilityTitle: String) {
        update(content: content.updatingRecency(
            visualTitle: visualTitle,
            accessibilityTitle: accessibilityTitle
        ))
    }

    private func configureLayout() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        contextLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        recencyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        tokenLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        apiValueLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        contextLabel.textColor = .tertiaryLabelColor
        recencyLabel.textColor = .tertiaryLabelColor
        tokenLabel.textColor = .labelColor
        apiValueLabel.textColor = .secondaryLabelColor

        for label in [contextLabel, recencyLabel, tokenLabel, apiValueLabel] {
            label.lineBreakMode = .byClipping
            label.maximumNumberOfLines = 1
            label.usesSingleLineMode = true
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let contextRow = NSStackView(views: [contextLabel, spacer, recencyLabel])
        contextRow.orientation = .horizontal
        contextRow.alignment = .centerY
        contextRow.spacing = Metrics.contextSpacing

        let stack = NSStackView(views: [contextRow, tokenLabel, apiValueLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.lineSpacing
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalInset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.verticalInset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.verticalInset),
            contextRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
}
