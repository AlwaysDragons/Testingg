import ActivityKit
import SwiftUI
import WidgetKit

// Home Screen, Lock Screen and StandBy widgets + the focus timer Live Activity.
// Data comes from the snapshot the app writes into the App Group (`WidgetSnapshot`).

@main
struct ForgeWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        HabitsWidget()
        FocusLiveActivity()
    }
}

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: Date(), snapshot: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview ? .placeholder : (WidgetSnapshot.load() ?? .placeholder)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetSnapshot.load() ?? .placeholder)
        // The app reloads timelines whenever data changes; this is only a fallback refresh.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

private func accent(_ hex: String) -> Color {
    let rgb = RGB(hex: hex) ?? RGB(red: 0.36, green: 0.55, blue: 1)
    return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
}

// MARK: - Today widget (small, medium, Lock Screen, StandBy)

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ForgeToday", provider: SnapshotProvider()) { entry in
            TodayWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "forge://home"))
        }
        .configurationDisplayName("Today")
        .description("What's due and how your areas are doing.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(counts)
        case .accessoryCircular:
            if let r = snapshot.readiness {
                Gauge(value: Double(r), in: 0...100) { Image(systemName: "heart") } currentValueLabel: { Text("\(r)") }
                    .gaugeStyle(.accessoryCircular)
            } else {
                VStack(spacing: 0) {
                    Text("\(snapshot.dueToday + snapshot.overdue)").font(.title3.weight(.semibold))
                    Text("due").font(.caption2)
                }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(counts).font(.headline).widgetAccentable()
                Text(snapshot.line).font(.caption).lineLimit(2)
            }
        case .systemMedium:
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Today").font(.caption).foregroundStyle(.secondary)
                    Text(snapshot.line).font(.subheadline).lineLimit(4)
                    Spacer(minLength: 0)
                    Text(counts).font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(snapshot.areas.prefix(2)) { tile($0) }
                }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                if let first = snapshot.areas.first {
                    tile(first)
                } else {
                    Text("Today").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(counts).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var counts: String {
        var parts = ["\(snapshot.dueToday) due"]
        if snapshot.overdue > 0 { parts.append("\(snapshot.overdue) overdue") }
        if snapshot.remindersDue > 0 { parts.append("\(snapshot.remindersDue) reminders") }
        return parts.joined(separator: " · ")
    }

    private func tile(_ a: WidgetSnapshot.AreaTile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(a.name, systemImage: a.symbol).font(.caption).foregroundStyle(accent(a.accentHex)).lineLimit(1)
            Text(a.value).font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(a.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

// MARK: - Habits widget (one-tap check-off)

struct HabitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ForgeHabits", provider: SnapshotProvider()) { entry in
            HabitsWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Habits")
        .description("Check off today's habits.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct HabitsWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Habits").font(.caption).foregroundStyle(.secondary)
            if snapshot.habits.isEmpty {
                Text("No habits yet").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(snapshot.habits.prefix(4)) { h in
                Button(intent: LogHabitIntent(habitId: h.id)) {
                    HStack(spacing: 6) {
                        Image(systemName: h.doneToday ? "checkmark.circle.fill" : "circle")
                        Text(h.title).lineLimit(1).strikethrough(h.doneToday)
                        Spacer(minLength: 0)
                    }
                    .font(.subheadline)
                    .foregroundStyle(h.doneToday ? .secondary : .primary)
                }
                .buttonStyle(.plain)
                .disabled(h.doneToday)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Focus timer Live Activity

struct FocusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            HStack {
                VStack(alignment: .leading) {
                    Text("Focus").font(.caption).foregroundStyle(.secondary)
                    Text(context.attributes.areaName).font(.headline)
                }
                Spacer()
                Text(timerInterval: Date()...max(Date(), context.state.endsAt), countsDown: true)
                    .font(.system(.title, design: .rounded, weight: .semibold)).monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(accent(context.attributes.accentHex))
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label(context.attributes.areaName, systemImage: "timer").font(.caption) }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date()...max(Date(), context.state.endsAt), countsDown: true).monospacedDigit().frame(width: 64)
                }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(accent(context.attributes.accentHex))
            } compactTrailing: {
                Text(timerInterval: Date()...max(Date(), context.state.endsAt), countsDown: true).monospacedDigit().frame(width: 44)
            } minimal: {
                Image(systemName: "timer")
            }
        }
    }
}
