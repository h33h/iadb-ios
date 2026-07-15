import SwiftUI
import UIKit

@MainActor
func announceAccessibility(_ message: String) {
    UIAccessibility.post(notification: .announcement, argument: message)
}

private struct AdaptiveSheetHeightModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content
            .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
            .presentationDragIndicator(.visible)
    }
}

extension View {
    func iadbAdaptiveSheetHeight() -> some View {
        modifier(AdaptiveSheetHeightModifier())
    }

    /// Installs a non-cancelling window gesture that resigns first responder
    /// only when the tap starts outside an editable UIKit control. Buttons,
    /// row selection, context menus, and navigation continue receiving taps.
    func iadbDismissKeyboardOnOutsideTap() -> some View {
        background {
            KeyboardDismissTapInstaller()
                .frame(width: 0, height: 0)
        }
    }
}

private struct KeyboardDismissTapInstaller: UIViewRepresentable {
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var installedWindow: UIWindow?

        lazy var recognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(didTapOutsideField))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        @objc private func didTapOutsideField() {
            installedWindow?.endEditing(true)
        }

        func install(in window: UIWindow?) {
            guard installedWindow !== window else { return }
            uninstall()
            installedWindow = window
            window?.addGestureRecognizer(recognizer)
        }

        func uninstall() {
            installedWindow?.removeGestureRecognizer(recognizer)
            installedWindow = nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            var touchedView = touch.view
            while let view = touchedView {
                if view is UITextField || view is UITextView {
                    return false
                }
                touchedView = view.superview
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            context.coordinator.install(in: view.window)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.install(in: uiView.window)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.uninstall()
    }
}

/// Aligns workspace context with frequent actions and stacks them when width
/// or Dynamic Type no longer permits a single row.
struct WorkspaceToolbar<Context: View, Actions: View>: View {
    let context: Context
    let actions: Actions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        @ViewBuilder context: () -> Context,
        @ViewBuilder actions: () -> Actions
    ) {
        self.context = context()
        self.actions = actions()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: IADBDesign.spacing16) {
                    context
                    Spacer(minLength: IADBDesign.spacing12)
                    actions
                }
                stacked
            }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: IADBDesign.spacing12) {
            context
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A dense label/value row that becomes stacked at accessibility text sizes.
/// Technical values stay selectable and expose an explicit copy alternative.
struct TechnicalRow: View {
    let label: String
    let value: String
    var icon: String?
    var monospacedValue = false
    var allowsCopy = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        label: LocalizedStringResource,
        value: String,
        icon: String? = nil,
        monospacedValue: Bool = false,
        allowsCopy: Bool = false
    ) {
        self.label = String(localized: label)
        self.value = value
        self.icon = icon
        self.monospacedValue = monospacedValue
        self.allowsCopy = allowsCopy
    }

    init(
        localizedLabel: String,
        value: String,
        icon: String? = nil,
        monospacedValue: Bool = false,
        allowsCopy: Bool = false
    ) {
        self.label = localizedLabel
        self.value = value
        self.icon = icon
        self.monospacedValue = monospacedValue
        self.allowsCopy = allowsCopy
    }

    var body: some View {
        HStack(alignment: .top, spacing: IADBDesign.spacing8) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: IADBDesign.spacing4) {
                        labelView
                        valueView
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: IADBDesign.spacing12) {
                        labelView
                        Spacer(minLength: IADBDesign.spacing12)
                        valueView
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .layoutPriority(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(label), \(value.isEmpty ? String(localized: "not available") : value)"
            )
            .accessibilityAction(named: "Copy \(label)") {
                guard allowsCopy, !value.isEmpty else { return }
                UIPasteboard.general.string = value
                announceAccessibility(String(localized: "\(label) copied"))
            }

            if allowsCopy, !value.isEmpty {
                Button {
                    UIPasteboard.general.string = value
                    announceAccessibility(String(localized: "\(label) copied"))
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(
                            width: IADBDesign.minimumHitTarget,
                            height: IADBDesign.minimumHitTarget
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Copy \(label)")
            }
        }
        .padding(.vertical, IADBDesign.spacing8)
    }

    private var labelView: some View {
        HStack(alignment: .firstTextBaseline, spacing: IADBDesign.spacing8) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                    .accessibilityHidden(true)
            }
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var valueView: some View {
        if monospacedValue {
            Text(value.isEmpty ? "—" : value)
                .font(.subheadline.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(value.isEmpty ? "—" : value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Compact disclosure for filters; its summary remains visible without a tall
/// persistent control panel.
struct FilterSummaryButton<MenuContent: View>: View {
    let title: String
    let summary: String
    let activeCount: Int
    let menuContent: MenuContent

    init(
        _ title: LocalizedStringResource = "Filter",
        summary: String,
        activeCount: Int,
        @ViewBuilder menuContent: () -> MenuContent
    ) {
        self.title = String(localized: title)
        self.summary = summary
        self.activeCount = activeCount
        self.menuContent = menuContent()
    }

    var body: some View {
        Menu {
            menuContent
        } label: {
            HStack(spacing: IADBDesign.spacing8) {
                Image(systemName: activeCount > 0
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(summary)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                if activeCount > 0 {
                    Text(activeCount, format: .number)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.14), in: Capsule())
                        .accessibilityLabel("\(activeCount) active filters")
                }
            }
            .padding(.horizontal, IADBDesign.spacing12)
            .frame(minHeight: IADBDesign.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("\(title), \(summary)")
        .accessibilityValue(
            activeCount == 0
                ? String(localized: "No active filters")
                : String(localized: "\(activeCount) active")
        )
    }
}

/// Field chrome with a persistent semantic label and optional inline error.
/// The caller retains focus, keyboard and reducer ownership of the field.
struct InlineValidatedField<Field: View>: View {
    let label: String
    let symbol: String
    let validationMessage: String?
    let field: Field

    init(
        _ label: LocalizedStringResource,
        symbol: String,
        validationMessage: String? = nil,
        @ViewBuilder field: () -> Field
    ) {
        self.label = String(localized: label)
        self.symbol = symbol
        self.validationMessage = validationMessage
        self.field = field()
    }

    init(
        localizedLabel: String,
        symbol: String,
        validationMessage: String? = nil,
        @ViewBuilder field: () -> Field
    ) {
        self.label = localizedLabel
        self.symbol = symbol
        self.validationMessage = validationMessage
        self.field = field()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IADBDesign.spacing4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: IADBDesign.spacing12) {
                    fieldLabel
                    Spacer(minLength: IADBDesign.spacing12)
                    field
                        .multilineTextAlignment(.trailing)
                }
                VStack(alignment: .leading, spacing: IADBDesign.spacing8) {
                    fieldLabel
                    field
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: IADBDesign.minimumHitTarget)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error, \(validationMessage)")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var fieldLabel: some View {
        Label(label, systemImage: symbol)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

struct BulkActionItem: Identifiable {
    enum Emphasis {
        case secondary
        case primary
        case destructive
    }

    let id: String
    let title: String
    let symbol: String?
    let emphasis: Emphasis
    var isEnabled = true
    let action: () -> Void

    init(
        id: String,
        title: LocalizedStringResource,
        symbol: String?,
        emphasis: Emphasis,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = String(localized: title)
        self.symbol = symbol
        self.emphasis = emphasis
        self.isEnabled = isEnabled
        self.action = action
    }
}

/// Persistent selection summary with explicit alternatives to swipe or context
/// menu gestures. Compact screens keep actions in one horizontally scrollable
/// toolbar so the bar never covers most of the list.
struct BulkActionBar: View {
    let selectionCount: Int
    let selectionLabel: String
    let actions: [BulkActionItem]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        selectionCount: Int,
        selectionLabel: String,
        actions: [BulkActionItem]
    ) {
        self.selectionCount = selectionCount
        self.selectionLabel = selectionLabel
        self.actions = actions
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityCompact
            } else if horizontalSizeClass == .compact {
                compactToolbar
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: IADBDesign.spacing12) {
                        summary
                        Spacer(minLength: IADBDesign.spacing8)
                        ForEach(actions) { item in actionButton(item) }
                    }
                    stacked
                }
            }
        }
        .padding(.horizontal, IADBDesign.spacing16)
        .padding(.vertical, IADBDesign.spacing8)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private var compactToolbar: some View {
        HStack(spacing: IADBDesign.spacing8) {
            summary
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 0)

            ScrollView(.horizontal) {
                HStack(spacing: IADBDesign.spacing8) {
                    ForEach(actions) { item in
                        compactActionButton(item)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A vertically stacked button for every action can consume the entire
    /// workspace at Accessibility XXXL. Keep the persistent selection context
    /// and expose the same named actions through a native, 44 pt menu instead.
    private var accessibilityCompact: some View {
        HStack(spacing: IADBDesign.spacing12) {
            summary
            Spacer(minLength: IADBDesign.spacing8)
            Menu {
                ForEach(actions) { item in
                    Button(
                        role: item.emphasis == .destructive ? .destructive : nil,
                        action: item.action
                    ) {
                        if let symbol = item.symbol {
                            Label(item.title, systemImage: symbol)
                        } else {
                            Text(item.title)
                        }
                    }
                    .disabled(!item.isEnabled)
                }
            } label: {
                Label("Bulk Actions", systemImage: "ellipsis.circle")
                    .frame(minHeight: IADBDesign.minimumHitTarget)
            }
            .buttonStyle(.bordered)
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: IADBDesign.spacing8) {
            summary
            ForEach(actions) { item in
                actionButton(item)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(selectionLabel)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func actionButton(_ item: BulkActionItem) -> some View {
        let button = Button(
            role: item.emphasis == .destructive ? .destructive : nil,
            action: item.action
        ) {
            if let symbol = item.symbol {
                Label(item.title, systemImage: symbol)
                    .frame(minHeight: IADBDesign.minimumHitTarget)
            } else {
                Text(item.title)
                    .frame(minHeight: IADBDesign.minimumHitTarget)
            }
        }
        switch item.emphasis {
        case .primary:
            button
                .buttonStyle(.borderedProminent)
                .disabled(!item.isEnabled)
        case .secondary:
            button
                .buttonStyle(.bordered)
                .disabled(!item.isEnabled)
        case .destructive:
            button
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!item.isEnabled)
        }
    }

    @ViewBuilder
    private func compactActionButton(_ item: BulkActionItem) -> some View {
        let button = Button(
            role: item.emphasis == .destructive ? .destructive : nil,
            action: item.action
        ) {
            Image(systemName: item.symbol ?? "xmark.circle")
                .frame(
                    width: IADBDesign.minimumHitTarget,
                    height: IADBDesign.minimumHitTarget
                )
                .contentShape(Rectangle())
        }
        .accessibilityLabel(item.title)

        switch item.emphasis {
        case .primary:
            button
                .buttonStyle(.borderedProminent)
                .disabled(!item.isEnabled)
        case .secondary:
            button
                .buttonStyle(.bordered)
                .disabled(!item.isEnabled)
        case .destructive:
            button
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!item.isEnabled)
        }
    }
}

enum DetailInspectorState: Equatable {
    case empty(title: LocalizedStringResource, message: LocalizedStringResource, symbol: String)
    case loading(title: LocalizedStringResource)
    case content
}

/// Inspector body states only; navigation and selection remain owned by the
/// workspace reducer and shell.
struct DetailInspector<Content: View>: View {
    let state: DetailInspectorState
    let content: Content

    init(
        state: DetailInspectorState,
        @ViewBuilder content: () -> Content
    ) {
        self.state = state
        self.content = content()
    }

    var body: some View {
        switch state {
        case .empty(let title, let message, let symbol):
            ContentUnavailableView(
                String(localized: title),
                systemImage: symbol,
                description: Text(message)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading(let title):
            VStack(spacing: IADBDesign.spacing12) {
                ProgressView()
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case .content:
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
