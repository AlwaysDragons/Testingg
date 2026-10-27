import SwiftUI

// Reusable components for every new screen. Built only from `DS` tokens.

/// A card: one primary idea, up to ~3 data points.
struct DSCard<Content: View>: View {
    var padding: CGFloat = DS.Space.m
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) { content }
            .dsCard(padding: padding)
    }
}

/// One large number, one label, one optional small secondary line.
struct StatView: View {
    let value: String
    let label: String
    var secondary: String? = nil
    var valueColor: Color = DS.Palette.primary

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(value)
                .font(DS.Typo.hero)
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(label)
                .font(DS.Typo.body)
                .foregroundStyle(DS.Palette.primary)
                .lineLimit(1)
            if let secondary {
                Text(secondary)
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Palette.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A slim single-color progress ring.
struct ProgressRing: View {
    /// 0...1
    let progress: Double
    var accent: Color = DS.Palette.accent
    var lineWidth: CGFloat = 5
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().stroke(accent.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(DS.Motion.spring, value: progress)
        .accessibilityLabel("\(Int((min(1, max(0, progress)) * 100).rounded())) percent")
    }
}

/// A minimal line of recent values (no axes, no labels).
struct TrendLine: View {
    let values: [Double]
    var accent: Color = DS.Palette.accent

    var body: some View {
        GeometryReader { geo in
            let pts = Self.points(values, in: geo.size)
            Path { p in
                guard let first = pts.first else { return }
                p.move(to: first)
                for pt in pts.dropFirst() { p.addLine(to: pt) }
            }
            .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 28)
        .accessibilityHidden(true)
    }

    static func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
        guard values.count > 1, let lo = values.min(), let hi = values.max() else { return [] }
        let span = hi - lo == 0 ? 1 : hi - lo
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) * step, y: size.height - CGFloat((v - lo) / span) * size.height)
        }
    }
}

/// One status indicator max per card.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}

/// Section title in sentence case, with one optional text action.
struct SectionHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(DS.Typo.bodyEmphasis)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Palette.secondary)
            }
        }
        .padding(.horizontal, DS.Space.xs)
        .padding(.top, DS.Space.s)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Calm empty state with one optional action.
struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: symbol)
                .font(.title2.weight(DS.symbolWeight))
                .foregroundStyle(DS.Palette.secondary)
            Text(title).font(DS.Typo.bodyEmphasis)
            if let message {
                Text(message)
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Palette.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(DS.Typo.body)
                    .padding(.top, DS.Space.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Space.l)
    }
}

/// A list row with at most one visible trailing element.
struct ListRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var accent: Color = DS.Palette.secondary
    var isDone = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: DS.Space.m) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.body.weight(DS.symbolWeight))
                    .foregroundStyle(accent)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Typo.body)
                    .strikethrough(isDone)
                    .foregroundStyle(isDone ? DS.Palette.secondary : DS.Palette.primary)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle).font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: DS.Space.s)
            trailing
        }
        .padding(.vertical, DS.Space.s)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension ListRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, symbol: String? = nil, accent: Color = DS.Palette.secondary, isDone: Bool = false) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, accent: accent, isDone: isDone) { EmptyView() }
    }
}

/// Trailing value text for a `ListRow`.
struct RowValue: View {
    let text: String
    var color: Color = DS.Palette.secondary
    var body: some View {
        Text(text).font(DS.Typo.caption).foregroundStyle(color).monospacedDigit()
    }
}

/// Primary full-width action button (one per screen).
struct PrimaryButtonStyle: ButtonStyle {
    var accent: Color = DS.Palette.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Typo.bodyEmphasis)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Space.m - 2)
            .foregroundStyle(.white)
            .background(accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .animation(DS.Motion.quick, value: configuration.isPressed)
    }
}

// MARK: - Gallery (Previews in light and dark)

struct DesignGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                SectionHeader(title: "Areas", actionTitle: "Edit") {}
                HStack(spacing: DS.Space.m) {
                    DSCard {
                        HStack {
                            Image(systemName: "dumbbell").foregroundStyle(DS.Palette.area(hex: nil, kind: "gym"))
                            Spacer()
                            StatusDot(color: DS.Palette.positive)
                        }
                        StatView(value: "3/4", label: "Gym", secondary: "workouts this week")
                        ProgressRing(progress: 0.75, accent: DS.Palette.area(hex: nil, kind: "gym"))
                    }
                    DSCard {
                        HStack {
                            Image(systemName: "bed.double").foregroundStyle(DS.Palette.area(hex: "#4FB3D9"))
                            Spacer()
                        }
                        StatView(value: "7.4h", label: "Sleep", secondary: "7-day average")
                        TrendLine(values: [6.8, 7.1, 7.9, 6.5, 7.4, 8.0, 7.2], accent: DS.Palette.area(hex: "#4FB3D9"))
                    }
                }
                SectionHeader(title: "Today")
                DSCard(padding: DS.Space.m) {
                    ListRow(title: "Call the bank", subtitle: "Finance · 10:00", symbol: "circle")
                    ListRow(title: "Stretch 10 min", subtitle: "Habits", symbol: "checkmark.circle.fill", accent: DS.Palette.positive, isDone: true)
                    ListRow(title: "Rent", symbol: "creditcard") { RowValue(text: "Due in 2 days", color: DS.Palette.warning) }
                }
                DSCard { EmptyState(symbol: "tray", title: "Inbox is empty", message: "Captures you add land here.", actionTitle: "Capture") {} }
                Button("Save") {}.buttonStyle(PrimaryButtonStyle())
            }
            .padding(DS.Space.m)
        }
        .dsScreen()
    }
}

#Preview("Light") { DesignGallery().preferredColorScheme(.light) }
#Preview("Dark") { DesignGallery().preferredColorScheme(.dark) }
