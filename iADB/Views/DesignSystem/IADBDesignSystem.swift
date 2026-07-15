import SwiftUI

private struct IADBIncreasedContrastPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var iadbIncreasedContrastPreview: Bool {
        get { self[IADBIncreasedContrastPreviewKey.self] }
        set { self[IADBIncreasedContrastPreviewKey.self] = newValue }
    }
}

/// Shared visual language for iADB's precision-utility interface.
///
/// The system deliberately uses semantic Apple colors and text styles so it
/// adapts to Dark Mode, increased contrast, and Dynamic Type without a custom
/// theme layer fighting the platform.
enum IADBDesign {
    static let spacing4: CGFloat = 4
    static let spacing8: CGFloat = 8
    static let spacing12: CGFloat = 12
    static let spacing16: CGFloat = 16
    static let spacing20: CGFloat = 20
    static let spacing24: CGFloat = 24
    static let spacing32: CGFloat = 32
    static let compactSpacing: CGFloat = 8
    static let spacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 20
    static let contentPadding: CGFloat = 16
    static let cardRadius: CGFloat = 16
    static let controlRadius: CGFloat = 10
    static let heroRadius: CGFloat = 22
    static let minimumHitTarget: CGFloat = 44
    static let selectionAnimationDuration: TimeInterval = 0.18
}

private struct IADBSelectionHighlightModifier: ViewModifier {
    let isSelected: Bool
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var accessibilityContrast

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(isSelected ? selectedOpacity : 0))
            }
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, IADBDesign.spacing8)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: IADBDesign.selectionAnimationDuration),
                value: isSelected
            )
    }

    private var selectedOpacity: Double {
        accessibilityContrast == .increased ? 0.2 : 0.11
    }
}

struct IADBScreenBackground: View {
    var body: some View {
        Color(uiColor: .systemGroupedBackground)
            .ignoresSafeArea()
    }
}

struct IADBCard<Content: View>: View {
    let content: Content
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.iadbIncreasedContrastPreview) private var previewIncreasedContrast

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(IADBDesign.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: IADBDesign.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: IADBDesign.cardRadius, style: .continuous)
                    .stroke(
                        Color.primary.opacity(usesIncreasedContrast ? 0.3 : 0.08),
                        lineWidth: usesIncreasedContrast ? 1 : 0.5
                    )
            }
    }

    private var usesIncreasedContrast: Bool {
        accessibilityContrast == .increased || previewIncreasedContrast
    }
}

struct IADBSectionHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(
        _ title: LocalizedStringResource,
        subtitle: LocalizedStringResource? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = String(localized: title)
        self.subtitle = subtitle.map { String(localized: $0) }
        self.trailing = trailing()
    }

    init(
        localizedTitle: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = localizedTitle
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: IADBDesign.spacing) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .accessibilityElement(children: .contain)
    }
}

extension IADBSectionHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringResource, subtitle: LocalizedStringResource? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }

    init(localizedTitle: String, subtitle: String? = nil) {
        self.init(localizedTitle: localizedTitle, subtitle: subtitle) { EmptyView() }
    }
}

struct IADBStatusBadge: View {
    enum Kind {
        case neutral
        case progress
        case success
        case warning
        case error

        fileprivate var color: Color {
            switch self {
            case .neutral: .secondary
            case .progress: .accentColor
            case .success: .green
            case .warning: .orange
            case .error: .red
            }
        }

        fileprivate var symbol: String {
            switch self {
            case .neutral: "circle"
            case .progress: "antenna.radiowaves.left.and.right"
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }
    }

    let title: String
    let kind: Kind

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.color)
            Text(title)
                .foregroundStyle(.primary)
        }
        .font(.caption.weight(.semibold))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(accessibilityStatus)")
    }

    private var accessibilityStatus: String {
        switch kind {
        case .neutral: String(localized: "Status")
        case .progress: String(localized: "In progress")
        case .success: String(localized: "Success")
        case .warning: String(localized: "Warning")
        case .error: String(localized: "Error")
        }
    }
}

struct IADBIconTile: View {
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        Image(systemName: symbol)
            .font(.title3.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 44, height: 44)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct LabeledMetric: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color = .accentColor
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.iadbIncreasedContrastPreview) private var previewIncreasedContrast

    init(
        title: LocalizedStringResource,
        value: String,
        symbol: String,
        tint: Color = .accentColor
    ) {
        self.title = String(localized: title)
        self.value = value
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IADBDesign.compactSpacing) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(tint)
            Text(value.isEmpty ? "—" : value)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: IADBDesign.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: IADBDesign.cardRadius, style: .continuous)
                .stroke(
                    Color.primary.opacity(usesIncreasedContrast ? 0.3 : 0.08),
                    lineWidth: usesIncreasedContrast ? 1 : 0.5
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(title), \(value.isEmpty ? String(localized: "not available") : value)"
        )
    }

    private var usesIncreasedContrast: Bool {
        accessibilityContrast == .increased || previewIncreasedContrast
    }
}

struct IADBCallout: View {
    let title: String
    let message: String
    let symbol: String
    var tint: Color = .accentColor

    init(
        title: LocalizedStringResource,
        message: String,
        symbol: String,
        tint: Color = .accentColor
    ) {
        self.title = String(localized: title)
        self.message = message
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .top, spacing: IADBDesign.spacing) {
            IADBIconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// A consistent, non-overlapping selected state for list and table rows.
    /// The leading marker keeps the state distinguishable without relying on
    /// color alone, while Reduce Motion removes the transition automatically.
    func iadbSelectionHighlight(
        isSelected: Bool,
        cornerRadius: CGFloat = IADBDesign.controlRadius
    ) -> some View {
        modifier(
            IADBSelectionHighlightModifier(
                isSelected: isSelected,
                cornerRadius: cornerRadius
            )
        )
    }

    func iadbReadableWidth(maxWidth: CGFloat = 720) -> some View {
        frame(maxWidth: maxWidth, alignment: .center)
            .frame(maxWidth: .infinity)
    }

    func iadbWorkspaceWidth() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
