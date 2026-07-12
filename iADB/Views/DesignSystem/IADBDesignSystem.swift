import SwiftUI

/// Shared visual language for iADB's precision-utility interface.
///
/// The system deliberately uses semantic Apple colors and text styles so it
/// adapts to Dark Mode, increased contrast, and Dynamic Type without a custom
/// theme layer fighting the platform.
enum IADBDesign {
    static let compactSpacing: CGFloat = 8
    static let spacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 20
    static let contentPadding: CGFloat = 16
    static let cardRadius: CGFloat = 16
    static let controlRadius: CGFloat = 10
}

struct IADBScreenBackground: View {
    var body: some View {
        Color(uiColor: .systemGroupedBackground)
            .ignoresSafeArea()
    }
}

struct IADBCard<Content: View>: View {
    let content: Content

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
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
    }
}

struct IADBSectionHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
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
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
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
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(kind.color.opacity(0.12), in: Capsule())
            .accessibilityElement(children: .combine)
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

struct IADBMetricCard: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color = .accentColor
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: IADBDesign.compactSpacing) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(tint)
            Text(value.isEmpty ? "—" : value)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.8)
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
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value.isEmpty ? "not available" : value)")
    }
}

struct IADBCallout: View {
    let title: String
    let message: String
    let symbol: String
    var tint: Color = .accentColor

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
    func iadbContentWidth() -> some View {
        frame(maxWidth: 980, alignment: .center)
            .frame(maxWidth: .infinity)
    }
}
