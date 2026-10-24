import SwiftUI
import Charts

struct TrainingView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("", selection: $tab) {
                        Text("Overview").tag(0)
                        Text("Lifts").tag(1)
                        Text("History").tag(2)
                    }
                    .pickerStyle(.segmented)
                    switch tab {
                    case 0: overview
                    case 1: lifts
                    default: history
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable { await model.refreshAll() }
            .screen()
            .navigationTitle("Training")
            .navigationDestination(for: LiftStat.self) { LiftDetailView(lift: $0) }
            .navigationDestination(for: HevyWorkout.self) { WorkoutDetailView(workout: $0) }
        }
    }

    // MARK: Overview

    private var overview: some View {
        let a = model.analysis
        return VStack(spacing: 14) {
            HStack(spacing: 12) {
                StatTile(icon: "calendar", label: "Per week", value: String(format: "%.1f", a.avgSessionsPerWeek), sub: "sessions", tint: Theme.accent)
                StatTile(icon: "timer", label: "Avg time", value: "\(Int(a.avgDurationMin))m", sub: "per session", tint: Theme.violet)
                StatTile(icon: "number", label: "Total", value: "\(a.totalWorkouts)", sub: "workouts", tint: Theme.mint)
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Weekly hard sets").font(.headline)
                        Spacer()
                        Text("target 10–20").font(.caption).foregroundStyle(Theme.secondary)
                    }
                    Chart {
                        RectangleMark(xStart: .value("Low", 10.0), xEnd: .value("High", 20.0))
                            .foregroundStyle(Theme.mint.opacity(0.08))
                        ForEach(a.volume) { v in
                            BarMark(x: .value("Sets", v.avg4w), y: .value("Muscle", v.group.display))
                                .foregroundStyle(color(for: v.avg4w))
                                .cornerRadius(5)
                                .annotation(position: .trailing) {
                                    Text(String(format: "%.0f", v.avg4w)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.secondary)
                                }
                        }
                    }
                    .chartXScale(domain: 0...max(24, (a.volume.map(\.avg4w).max() ?? 0) + 4))
                    .frame(height: CGFloat(a.volume.count) * 28)
                    Text("4-week average. Primary muscle = 1 set, secondary = ½ set.").font(.caption2).foregroundStyle(Theme.secondary)
                }
            }
            if !a.stalled.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Stalled lifts", systemImage: "pause.circle.fill").font(.headline).foregroundStyle(Theme.amber)
                        ForEach(a.stalled.prefix(6)) { l in
                            NavigationLink(value: l) {
                                HStack {
                                    Text(l.title).font(.subheadline).lineLimit(1)
                                    Spacer()
                                    Text(Fmt.weight(l.bestE1RM, lbs: model.useLbs)).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.secondary)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        Text("No e1RM progress in the last 3 sessions. Ask the Coach for a plateau plan.").font(.caption2).foregroundStyle(Theme.secondary)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Days since trained").font(.headline)
                    HStack(spacing: 10) {
                        ForEach([TrainingCategory.push, .pull, .legs, .core], id: \.self) { c in
                            let days = a.lastTrained[c].map { Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: $0), to: Calendar.current.startOfDay(for: Date())).day ?? 0 }
                            VStack(spacing: 4) {
                                Text(days.map { "\($0)" } ?? "—").font(.system(.title2, design: .rounded, weight: .bold))
                                Text(c.display).font(.caption).foregroundStyle(Theme.color(c))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.color(c).opacity(0.1)))
                        }
                    }
                }
            }
        }
    }

    private func color(for sets: Double) -> Color {
        sets < 8 ? Theme.orange : sets <= 22 ? Theme.mint : Theme.amber
    }

    // MARK: Lifts

    private var lifts: some View {
        LazyVStack(spacing: 10) {
            ForEach(model.analysis.lifts) { l in
                NavigationLink(value: l) {
                    Card(padding: 14) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(l.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(l.group.display).font(.caption).foregroundStyle(Theme.color(l.group.category))
                                    Text("· \(l.points.count) sessions").font(.caption).foregroundStyle(Theme.secondary)
                                }
                            }
                            Spacer()
                            Sparkline(points: l.points.suffix(12).map(\.e1rm))
                                .frame(width: 60, height: 26)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(Fmt.weight(l.bestE1RM, lbs: model.useLbs)).font(.subheadline.weight(.bold).monospacedDigit())
                                if let t = l.trendPct {
                                    Text(String(format: "%+.1f%%", t)).font(.caption.weight(.semibold))
                                        .foregroundStyle(t > 0.5 ? Theme.mint : t < -0.5 ? Theme.orange : Theme.secondary)
                                } else {
                                    Text("e1RM").font(.caption).foregroundStyle(Theme.secondary)
                                }
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: History

    private var history: some View {
        LazyVStack(spacing: 10) {
            ForEach(model.workouts.prefix(150)) { w in
                NavigationLink(value: w) {
                    Card(padding: 14) {
                        HStack(spacing: 12) {
                            let cat = model.resolver.category(of: w)
                            RoundedRectangle(cornerRadius: 3).fill(Theme.color(cat)).frame(width: 4, height: 40)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(w.title).font(.subheadline.weight(.semibold))
                                Text(Fmt.day.string(from: w.startTime)).font(.caption).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text("\(w.workingSetCount) sets · \(Int(w.durationMinutes))m").font(.caption.weight(.medium))
                                Text(Fmt.weight(w.tonnageKg, lbs: model.useLbs)).font(.caption).foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct Sparkline: View {
    let points: [Double]
    var body: some View {
        Chart(Array(points.enumerated()), id: \.offset) { item in
            LineMark(x: .value("i", item.offset), y: .value("v", item.element))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Theme.gradient)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: (points.min() ?? 0) * 0.97...(points.max() ?? 1) * 1.01)
    }
}

struct LiftDetailView: View {
    @Environment(AppModel.self) private var model
    let lift: LiftStat

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    StatTile(icon: "trophy.fill", label: "Best e1RM", value: Fmt.weight(lift.bestE1RM, lbs: model.useLbs), tint: Theme.amber)
                    StatTile(icon: "chart.line.uptrend.xyaxis", label: "4-wk trend",
                             value: lift.trendPct.map { String(format: "%+.1f%%", $0) } ?? "—",
                             sub: lift.isStalled ? "Stalled" : "Progressing", tint: lift.isStalled ? Theme.orange : Theme.mint)
                }
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Estimated 1RM").font(.headline)
                        Chart(lift.points) { p in
                            AreaMark(x: .value("Date", p.date), y: .value("e1RM", Fmt.weightValue(p.e1rm, lbs: model.useLbs)))
                                .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.catmullRom)
                            LineMark(x: .value("Date", p.date), y: .value("e1RM", Fmt.weightValue(p.e1rm, lbs: model.useLbs)))
                                .foregroundStyle(Theme.gradient)
                                .interpolationMethod(.catmullRom)
                                .lineStyle(StrokeStyle(lineWidth: 3))
                            PointMark(x: .value("Date", p.date), y: .value("e1RM", Fmt.weightValue(p.e1rm, lbs: model.useLbs)))
                                .foregroundStyle(.white).symbolSize(18)
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 220)
                    }
                }
                SectionTitle(title: "Sessions")
                ForEach(lift.points.reversed()) { p in
                    Card(padding: 12) {
                        HStack {
                            Text(Fmt.day.string(from: p.date)).font(.subheadline)
                            Spacer()
                            Text("Top set " + Fmt.set(p.topSet, lbs: model.useLbs)).font(.subheadline.monospacedDigit())
                            Text(Fmt.weight(p.e1rm, lbs: model.useLbs)).font(.caption).foregroundStyle(Theme.secondary).frame(width: 64, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .screen()
        .navigationTitle(lift.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WorkoutDetailView: View {
    @Environment(AppModel.self) private var model
    let workout: HevyWorkout

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    StatTile(icon: "timer", label: "Duration", value: "\(Int(workout.durationMinutes))m", tint: Theme.violet)
                    StatTile(icon: "square.stack.3d.up.fill", label: "Sets", value: "\(workout.workingSetCount)", tint: Theme.accent)
                    StatTile(icon: "scalemass.fill", label: "Volume", value: Fmt.compact(Fmt.weightValue(workout.tonnageKg, lbs: model.useLbs)), tint: Theme.mint)
                }
                ForEach(Array(workout.exercises.enumerated()), id: \.offset) { _, e in
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(e.title).font(.headline)
                                Spacer()
                                Pill(text: model.resolver.primary(e).display, color: Theme.color(model.resolver.primary(e).category))
                            }
                            ForEach(Array(e.sets.enumerated()), id: \.offset) { i, s in
                                HStack {
                                    Text(s.type == "warmup" ? "W" : "\(i + 1)")
                                        .font(.caption.weight(.bold)).frame(width: 22)
                                        .foregroundStyle(s.type == "warmup" ? Theme.amber : Theme.secondary)
                                    Text(Fmt.set(s, lbs: model.useLbs)).font(.subheadline.monospacedDigit())
                                    Spacer()
                                    if let r = s.rpe { Text("RPE \(r, specifier: "%.0f")").font(.caption).foregroundStyle(Theme.secondary) }
                                    if let e1 = s.e1RM, s.type != "warmup" {
                                        Text("e1RM " + Fmt.weight(e1, lbs: model.useLbs)).font(.caption).foregroundStyle(Theme.secondary)
                                    }
                                }
                            }
                            if let n = e.notes, !n.isEmpty { Text(n).font(.caption).foregroundStyle(Theme.secondary) }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .screen()
        .navigationTitle(workout.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
