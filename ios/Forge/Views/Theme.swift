import SwiftUI

enum Theme {
    static let bg = Color(red: 0.035, green: 0.035, blue: 0.055)
    static let card = Color.white.opacity(0.055)
    static let stroke = Color.white.opacity(0.08)
    static let secondary = Color.white.opacity(0.55)
    static let accent = Color(red: 0.42, green: 0.55, blue: 1.0)
    static let violet = Color(red: 0.64, green: 0.45, blue: 1.0)
    static let mint = Color(red: 0.35, green: 0.92, blue: 0.72)
    static let amber = Color(red: 1.0, green: 0.78, blue: 0.30)
    static let orange = Color(red: 1.0, green: 0.52, blue: 0.30)
    static let ice = Color(red: 0.45, green: 0.82, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.42, blue: 0.62)

    static let gradient = LinearGradient(colors: [accent, violet], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func readiness(_ s: Int) -> Color { s >= 80 ? mint : s >= 65 ? accent : s >= 50 ? amber : orange }

    static func color(_ m: Modality) -> Color {
        switch m {
        case .sauna: return orange
        case .coldPlunge: return ice
        case .hotTub: return pink
        case .hydroMassage: return accent
        case .compression: return mint
        }
    }

    static func color(_ c: TrainingCategory?) -> Color {
        switch c {
        case .push: return orange
        case .pull: return accent
        case .legs: return mint
        case .core: return amber
        case .cardio: return pink
        default: return violet
        }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat
    let content: Content

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

struct SectionTitle: View {
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(title).font(.system(.title3, design: .rounded, weight: .bold))
            Spacer()
            if let t = trailing { Text(t).font(.footnote).foregroundStyle(Theme.secondary) }
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }
}

struct StatTile: View {
    let icon: String
    let label: String
    let value: String
    var sub: String? = nil
    var tint: Color = Theme.accent

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.caption.weight(.bold)).foregroundStyle(tint)
                    Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(Theme.secondary).tracking(0.6)
                }
                Text(value).font(.system(.title2, design: .rounded, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                if let sub { Text(sub).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1) }
            }
        }
    }
}

struct Ring: View {
    let progress: Double
    let color: Color
    var lineWidth: CGFloat = 14

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(AngularGradient(colors: [color.opacity(0.6), color], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.5), radius: 8)
        }
        .animation(.spring(response: 0.8, dampingFraction: 0.8), value: progress)
    }
}

struct Pill: View {
    let text: String
    var color: Color = Theme.accent
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

struct ScreenBackground: View {
    var body: some View {
        ZStack {
            Theme.bg
            RadialGradient(colors: [Theme.accent.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Theme.violet.opacity(0.14), .clear], center: .topTrailing, startRadius: 0, endRadius: 360)
        }
        .ignoresSafeArea()
    }
}

extension View {
    func screen() -> some View {
        self.scrollContentBackground(.hidden).background(ScreenBackground())
    }
}

/// Renders Claude's markdown (bold, bullets, line breaks).
struct MarkdownText: View {
    let text: String
    var body: some View {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let cleaned = text.replacingOccurrences(of: "\n- ", with: "\n• ").replacingOccurrences(of: "^- ", with: "• ", options: .regularExpression)
        if let a = try? AttributedString(markdown: cleaned, options: opts) {
            Text(a)
        } else {
            Text(text)
        }
    }
}
