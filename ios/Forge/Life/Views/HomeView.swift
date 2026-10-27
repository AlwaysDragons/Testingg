import SwiftUI

/// Glance view: greeting + briefing line, Today strip, pinned area cards. Detail is one tap deeper.
struct HomeView: View {
    @Environment(LifeStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(CloudSync.self) private var cloud
    @Environment(BriefingService.self) private var briefing
    @Environment(CaptureStore.self) private var captures
    @State private var showNewArea = false
    @State private var showCloud = false
    @State private var briefingExpanded = false

    private let columns = [GridItem(.flexible(), spacing: DS.Space.m), GridItem(.flexible(), spacing: DS.Space.m)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    header
                    if !cloud.isSignedIn {
                        DSCard {
                            EmptyState(symbol: "icloud", title: "Connect your dashboard",
                                       message: "Sign in to Supabase to sync areas, tasks and metrics.",
                                       actionTitle: "Set up") { showCloud = true }
                        }
                    } else if store.hasLoaded && store.homeAreas.isEmpty {
                        DSCard {
                            EmptyState(symbol: "square.grid.2x2", title: "No areas on Home",
                                       message: "Pin an area or create one to see it here.",
                                       actionTitle: "New area") { showNewArea = true }
                        }
                    } else {
                        TodayStrip(today: store.today)
                        LazyVGrid(columns: columns, spacing: DS.Space.m) {
                            ForEach(store.homeAreas) { area in
                                NavigationLink(value: area.id) {
                                    AreaCard(area: area, hero: hero(for: area))
                                }
                                .buttonStyle(.plain)
                                .contextMenu { cardMenu(area) }
                            }
                        }
                    }
                    if let error = store.lastError {
                        Text(error).font(DS.Typo.caption).foregroundStyle(DS.Palette.critical)
                    }
                }
                .padding(.horizontal, DS.Space.m)
                .padding(.bottom, DS.Space.m)
            }
            .dsScreen()
            .safeAreaInset(edge: .bottom) { if cloud.isSignedIn { ChatBar() } }
            .refreshable {
                await model.refreshAll()   // existing Hevy + Health refresh (also pushes to Supabase)
                await store.reloadAll()
                await briefing.refreshIfNeeded(cloud.supabase, force: true)
            }
            .navigationDestination(for: UUID.self) { id in
                if let area = store.area(id) { AreaDetailView(area: area) }
            }
            .toolbar {
                if store.isEnabled(.capture) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { captures.open() } label: { Image(systemName: "plus").fontWeight(DS.symbolWeight) }
                            .accessibilityLabel("Capture")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if store.isEnabled(.capture) {
                            NavigationLink { InboxView() } label: {
                                Label(captures.inbox.isEmpty ? "Inbox" : "Inbox (\(captures.inbox.count))", systemImage: "tray")
                            }
                        }
                        Button("New area", systemImage: "plus") { showNewArea = true }
                    } label: {
                        Image(systemName: "ellipsis").fontWeight(DS.symbolWeight)
                    }
                    .accessibilityLabel("More")
                }
            }
            .sheet(isPresented: $showNewArea) { AreaEditor(area: nil) }
            .sheet(isPresented: $showCloud) { NavigationStack { CloudSettingsView() } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(Summaries.greeting()).font(DS.Typo.title)
            Text(briefingText)
                .font(DS.Typo.body)
                .foregroundStyle(DS.Palette.secondary)
                .lineLimit(briefingExpanded ? nil : 2)
                .onTapGesture { withAnimation(DS.Motion.spring) { briefingExpanded.toggle() } }
            if briefingExpanded, let detail = briefing.today?.detail, !detail.isEmpty {
                Text(detail).font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary).transition(.opacity)
            }
        }
        .padding(.top, DS.Space.s)
    }

    /// The AI briefing (Phase 6) when available, else a local summary.
    private var briefingText: String {
        briefing.today?.text ?? Summaries.line(store.today)
    }

    private func hero(for area: Area) -> Summaries.Hero {
        let gym = area.kind == "gym" ? (model.analysis.workoutsThisWeek, max(1, model.trainingDays.count)) : nil
        return Summaries.hero(store.data(for: area, gym: gym))
    }

    @ViewBuilder
    private func cardMenu(_ area: Area) -> some View {
        Button("Unpin from Home", systemImage: "pin.slash") {
            Task { await store.updateArea(area, ["pinned": .bool(false)]) }
        }
        Button("Hide", systemImage: "eye.slash") {
            Task { await store.updateArea(area, ["hidden": .bool(true)]) }
        }
    }
}

/// What's due, overdue, reminders and habits left, in one quiet line of numbers.
struct TodayStrip: View {
    let today: Summaries.Today

    var body: some View {
        HStack(spacing: 0) {
            cell(today.dueToday, "due", color: DS.Palette.primary)
            cell(today.overdue, "overdue", color: today.overdue > 0 ? DS.Palette.critical : DS.Palette.primary)
            cell(today.remindersDue, "reminders", color: DS.Palette.primary)
            cell(today.habitsLeft, "habits left", color: DS.Palette.primary)
        }
        .dsCard(padding: DS.Space.m)
    }

    private func cell(_ n: Int, _ label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(DS.Typo.bodyEmphasis).monospacedDigit().foregroundStyle(n == 0 ? DS.Palette.secondary : color)
            Text(label).font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Icon, name, one hero stat, a slim ring or sparkline, one status dot.
struct AreaCard: View {
    let area: Area
    let hero: Summaries.Hero

    var body: some View {
        let accent = DS.Palette.area(hex: area.color, kind: area.kind)
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Image(systemName: area.symbol).font(.body.weight(DS.symbolWeight)).foregroundStyle(accent)
                Text(area.name).font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if let color = statusColor { StatusDot(color: color) }
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hero.value).font(DS.Typo.hero).lineLimit(1).minimumScaleFactor(0.5).contentTransition(.numericText())
                    Text(hero.secondary ?? hero.label).font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let p = hero.progress { ProgressRing(progress: p, accent: accent, lineWidth: 4, size: 28) }
            }
            if hero.progress == nil, hero.trend.count > 1 { TrendLine(values: hero.trend, accent: accent) }
        }
        .frame(minHeight: 128, alignment: .topLeading)
        .dsCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(area.name), \(hero.value) \(hero.secondary ?? hero.label)")
    }

    private var statusColor: Color? {
        switch hero.status {
        case .none: return nil
        case .good: return DS.Palette.positive
        case .behind: return DS.Palette.warning
        case .overdue: return DS.Palette.critical
        }
    }
}

/// Today's AI briefing, cached on device for the day (written in Phase 6).
enum BriefingCache {
    struct Entry: Codable { var day: String; var text: String; var detail: String? }
    private static let key = "life.briefing"

    static func today(now: Date = Date()) -> Entry? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let e = try? JSONDecoder().decode(Entry.self, from: data),
              e.day == LifeCoding.dayString(now) else { return nil }
        return e
    }

    static func save(_ text: String, detail: String? = nil, now: Date = Date()) {
        let e = Entry(day: LifeCoding.dayString(now), text: text, detail: detail)
        if let data = try? JSONEncoder().encode(e) { UserDefaults.standard.set(data, forKey: key) }
    }
}

#Preview("Light") {
    AreaCard(area: .preview, hero: .init(value: "3/4", label: "workouts this week", progress: 0.75, status: .good))
        .padding().dsScreen().preferredColorScheme(.light)
}

#Preview("Dark") {
    AreaCard(area: .preview, hero: .init(value: "7.4h", label: "sleep hours", trend: [6.9, 7.2, 8, 6.4, 7.4]))
        .padding().dsScreen().preferredColorScheme(.dark)
}

extension Area {
    static let preview = Area(id: UUID(), name: "Gym", icon: nil, color: nil, kind: "gym", config: .emptyObject,
                              sortOrder: 0, pinned: true, hidden: false, createdAt: Date(), updatedAt: Date())
}
