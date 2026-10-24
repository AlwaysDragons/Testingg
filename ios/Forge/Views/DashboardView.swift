import SwiftUI
import Charts

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    if model.demoMode { demoBanner }
                    if let err = model.errorMessage { errorBanner(err) }
                    readinessCard
                    todayCard
                    briefCard
                    statsGrid
                    volumeChart
                    if !model.analysis.recentPRs.isEmpty { prCard }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable { await model.refreshAll() }
            .screen()
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.day.string(from: Date()).uppercased())
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary).tracking(1)
                Text(greeting).font(.system(.largeTitle, design: .rounded, weight: .bold))
            }
            Spacer()
            if model.isSyncing {
                ProgressView().tint(.white)
            }
        }
        .padding(.top, 12)
    }

    private var demoBanner: some View {
        Card(padding: 12) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars").foregroundStyle(Theme.amber)
                Text("Showing sample data. Add your Hevy key in Settings to load your real workouts.")
                    .font(.footnote).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func errorBanner(_ msg: String) -> some View {
        Card(padding: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                Text(msg).font(.footnote)
            }
        }
    }

    // MARK: Readiness

    private var readinessCard: some View {
        Card(padding: 20) {
            if let r = model.readiness {
                HStack(spacing: 20) {
                    ZStack {
                        Ring(progress: Double(r.score) / 100, color: Theme.readiness(r.score))
                        VStack(spacing: 0) {
                            Text("\(r.score)").font(.system(size: 40, weight: .bold, design: .rounded))
                            Text(r.label.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(Theme.readiness(r.score)).tracking(1)
                        }
                    }
                    .frame(width: 120, height: 120)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Readiness").font(.headline)
                        Text(r.advice).font(.subheadline).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider().overlay(Theme.stroke).padding(.vertical, 10)
                VStack(spacing: 10) {
                    ForEach(r.factors) { f in
                        HStack {
                            Text(f.name).font(.subheadline.weight(.medium))
                            Spacer()
                            Text(f.detail).font(.caption).foregroundStyle(Theme.secondary)
                            Text(f.value).font(.subheadline.weight(.semibold).monospacedDigit()).frame(minWidth: 70, alignment: .trailing)
                            Circle().fill(Theme.readiness(f.score)).frame(width: 8, height: 8)
                        }
                    }
                }
            } else {
                Label("Connect Apple Health in Settings to see your readiness score.", systemImage: "heart.text.square")
                    .font(.subheadline).foregroundStyle(Theme.secondary)
            }
        }
    }

    // MARK: Today plan

    @ViewBuilder private var todayCard: some View {
        if let today = model.plan.first {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TODAY AT ONELIFE").font(.caption2.weight(.bold)).foregroundStyle(Theme.secondary).tracking(1)
                            Text(today.headline).font(.title3.weight(.bold))
                        }
                        Spacer()
                        Image(systemName: today.isTraining ? "dumbbell.fill" : "leaf.fill")
                            .font(.title2).foregroundStyle(Theme.color(today.focus))
                    }
                    ForEach(today.items) { item in
                        HStack(spacing: 12) {
                            ModalityIcon(modality: item.modality, size: 34)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.modality.name).font(.subheadline.weight(.semibold))
                                Text("\(item.timing) · \(item.dose)").font(.caption).foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                    ForEach(today.notes, id: \.self) { n in
                        Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(Theme.amber)
                    }
                }
            }
        }
    }

    // MARK: AI brief

    private var briefCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("AI Coach brief", systemImage: "sparkles").font(.headline).foregroundStyle(Theme.gradient)
                    Spacer()
                    if model.isThinking { ProgressView().controlSize(.small) }
                }
                if let b = model.dailyBrief, let d = model.dailyBriefDate, Calendar.current.isDateInToday(d) {
                    MarkdownText(text: b).font(.subheadline)
                } else if model.hasClaude {
                    Button {
                        Task { await model.generateDailyBrief() }
                    } label: {
                        Text("Generate today's brief").font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Capsule().fill(Theme.gradient))
                            .foregroundStyle(.white)
                    }
                    .disabled(model.isThinking)
                } else {
                    Text("Add a Claude API key in Settings to get daily AI coaching.").font(.footnote).foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    // MARK: Stats

    private var statsGrid: some View {
        let h = model.health
        let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: cols, spacing: 12) {
            StatTile(icon: "moon.zzz.fill", label: "Sleep",
                     value: h.sleepHours.latest.map { String(format: "%.1f h", $0.value) } ?? "—",
                     sub: h.sleepHours.average(lastDays: 7).map { String(format: "7d avg %.1f h", $0) }, tint: Theme.violet)
            StatTile(icon: "waveform.path.ecg", label: "HRV",
                     value: h.hrv.latest.map { "\(Int($0.value)) ms" } ?? "—",
                     sub: h.hrv.average(lastDays: 30).map { "30d avg \(Int($0)) ms" }, tint: Theme.mint)
            StatTile(icon: "heart.fill", label: "Resting HR",
                     value: h.restingHr.latest.map { "\(Int($0.value)) bpm" } ?? "—",
                     sub: h.restingHr.average(lastDays: 30).map { "30d avg \(Int($0))" }, tint: Theme.pink)
            StatTile(icon: "figure.walk", label: "Steps",
                     value: h.steps.latest.map { Fmt.compact($0.value) } ?? "—",
                     sub: h.steps.average(lastDays: 7).map { "7d avg " + Fmt.compact($0) }, tint: Theme.accent)
            StatTile(icon: "scalemass.fill", label: "Weight",
                     value: h.bodyMassKg.latest.map { Fmt.weight($0.value, lbs: model.useLbs, decimals: 1) } ?? "—",
                     sub: h.bodyFatPct.latest.map { String(format: "%.1f%% body fat", $0.value) }, tint: Theme.amber)
            StatTile(icon: "flame.fill", label: "This week",
                     value: "\(model.analysis.workoutsThisWeek) workouts",
                     sub: String(format: "avg %.1f / week", model.analysis.avgSessionsPerWeek), tint: Theme.orange)
        }
    }

    private var volumeChart: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Weekly volume").font(.headline)
                    Spacer()
                    Text(model.useLbs ? "lb lifted" : "kg lifted").font(.caption).foregroundStyle(Theme.secondary)
                }
                Chart(model.analysis.weeks) { w in
                    BarMark(x: .value("Week", w.weekStart, unit: .weekOfYear),
                            y: .value("Volume", Fmt.weightValue(w.tonnageKg, lbs: model.useLbs)))
                        .foregroundStyle(Theme.gradient)
                        .cornerRadius(6)
                }
                .chartYAxis { AxisMarks { v in AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.compact(d)) } } } }
                .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                .frame(height: 160)
            }
        }
    }

    private var prCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Recent PRs", systemImage: "trophy.fill").font(.headline).foregroundStyle(Theme.amber)
                ForEach(model.analysis.recentPRs.prefix(5)) { pr in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(pr.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(Fmt.day.string(from: pr.date)).font(.caption).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        Text(Fmt.weight(pr.e1rm, lbs: model.useLbs)).font(.subheadline.weight(.bold).monospacedDigit())
                        Pill(text: String(format: "+%.1f%%", (pr.e1rm / pr.previousBest - 1) * 100), color: Theme.mint)
                    }
                }
            }
        }
    }
}

struct ModalityIcon: View {
    let modality: Modality
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: modality.icon)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(Theme.color(modality))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(Theme.color(modality).opacity(0.16)))
    }
}
