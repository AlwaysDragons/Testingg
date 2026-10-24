import SwiftUI

struct RecoveryView: View {
    @Environment(AppModel.self) private var model
    @State private var selected = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    dayStrip
                    if model.plan.indices.contains(selected) { dayDetail(model.plan[selected]) }
                    weeklyTotals
                    science
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .screen()
            .navigationTitle("Recovery")
        }
    }

    private var dayStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.plan.enumerated()), id: \.offset) { i, d in
                    Button { withAnimation(.snappy) { selected = i } } label: {
                        VStack(spacing: 6) {
                            Text(i == 0 ? "Today" : Fmt.shortDay.string(from: d.date))
                                .font(.caption.weight(.semibold))
                            Text("\(Calendar.current.component(.day, from: d.date))")
                                .font(.system(.title3, design: .rounded, weight: .bold))
                            Circle().fill(d.isTraining ? Theme.color(d.focus) : Theme.ice).frame(width: 6, height: 6)
                        }
                        .frame(width: 58, height: 82)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(selected == i ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.card)))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 4)
    }

    private func dayDetail(_ d: DayPlan) -> some View {
        VStack(spacing: 12) {
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Fmt.day.string(from: d.date).uppercased()).font(.caption2.weight(.bold)).foregroundStyle(Theme.secondary).tracking(1)
                        Text(d.headline).font(.title2.weight(.bold))
                        Text(d.isTraining ? "Lift first, then recover. No cold today." : "Contrast therapy day — heat, cold, repeat.")
                            .font(.subheadline).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    let total = d.items.reduce(0) { $0 + $1.minutes }
                    VStack {
                        Text("\(total)").font(.system(.title, design: .rounded, weight: .bold))
                        Text("min").font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
            }
            ForEach(d.items) { item in
                Card {
                    HStack(alignment: .top, spacing: 14) {
                        ModalityIcon(modality: item.modality, size: 46)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(item.modality.name).font(.headline)
                                Spacer()
                                Pill(text: item.timing, color: Theme.color(item.modality))
                            }
                            Text(item.dose).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.color(item.modality))
                            Text(item.why).font(.footnote).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            ForEach(d.notes, id: \.self) { n in
                Card(padding: 12) {
                    Label(n, systemImage: "lightbulb.fill").font(.footnote).foregroundStyle(Theme.amber)
                }
            }
        }
    }

    private struct DoseTarget: Identifiable {
        var id: Modality { modality }
        let modality: Modality
        let minutes: Int
        let note: String
    }

    private var weeklyTotals: some View {
        let targets: [DoseTarget] = [
            .init(modality: .sauna, minutes: 57, note: "~57 min/wk linked to cardiovascular benefits"),
            .init(modality: .coldPlunge, minutes: 11, note: "~11 min/wk, rest days only"),
            .init(modality: .compression, minutes: 60, note: "after leg days"),
            .init(modality: .hydroMassage, minutes: 45, note: "stress + tension relief"),
            .init(modality: .hotTub, minutes: 30, note: "mobility + sleep")
        ]
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("This week's dose").font(.headline)
                ForEach(targets.filter { model.amenities.contains($0.modality) }) { t in
                    let m = t.modality
                    let mins = model.plan.reduce(0) { $0 + $1.minutes(of: m) }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: m.icon).foregroundStyle(Theme.color(m)).frame(width: 20)
                            Text(m.name).font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(mins) / \(t.minutes) min").font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
                        }
                        ProgressView(value: min(1, Double(mins) / Double(t.minutes))).tint(Theme.color(m))
                        Text(t.note).font(.caption2).foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
    }

    private var science: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Why this order", systemImage: "brain.head.profile").font(.headline)
                bullet("Cold water right after lifting reduces muscle growth over time — so cold goes on rest days, or at least 6 h away from training.")
                bullet("Sauna after lifting is fine and adds heart-health benefits. Hydrate and add electrolytes.")
                bullet("Compression sleeves work best after leg days and the day after (peak soreness).")
                bullet("A hot tub 60–90 min before bed helps you fall asleep as your core temperature drops.")
                bullet("Skip heat or cold if you feel unwell, and check with a doctor if you have heart or blood pressure issues.")
            }
        }
    }

    private func bullet(_ t: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Theme.accent).frame(width: 5, height: 5).padding(.top, 7)
            Text(t).font(.footnote).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
