import SwiftUI

/// Money overview inside the finance area: this month, budget rings, subscriptions, savings goals.
struct MoneySection: View {
    @Environment(LifeStore.self) private var store
    @Environment(MoneyStore.self) private var money
    let area: Area
    @State private var showExpense = false
    @State private var showSubscription = false
    @State private var showGoal = false
    @State private var addingTo: Item?

    private var currency: String { money.status?.currency ?? area.config["currency"]?.string ?? "USD" }
    private var accent: Color { DS.Palette.area(hex: area.color, kind: area.kind) }

    var body: some View {
        monthSection
        budgetsSection
        subscriptionsSection
        savingsSection
            .sheet(isPresented: $showExpense) { ExpenseSheet(categories: categories) }
            .sheet(isPresented: $showSubscription) { SubscriptionSheet() }
            .sheet(isPresented: $showGoal) { SavingsGoalSheet(area: area) }
            .sheet(item: $addingTo) { AddSavingsSheet(goal: $0, currency: currency) }
    }

    private var categories: [String] {
        let fromBudgets = area.config["budgets"]?.object.keys.map { $0 } ?? []
        let used = money.status?.categories.map(\.category) ?? []
        return Array(Set(fromBudgets + used + ["food", "groceries", "transport", "fun", "home", "bills", "other"])).sorted()
    }

    @ViewBuilder
    private var monthSection: some View {
        let s = money.status
        Section {
            StatView(value: Summaries.money(s?.spent ?? 0, currency), label: "Spent this month",
                     secondary: s?.monthlyBudget.map { "of \(Summaries.money($0, currency)) · \(s?.daysLeft ?? 0) days left" })
            Button("Add expense") { showExpense = true }
        }
        .listRowBackground(DS.Palette.surface)
    }

    @ViewBuilder
    private var budgetsSection: some View {
        let budgeted = (money.status?.categories ?? []).filter { $0.budget != nil }
        if !budgeted.isEmpty {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88))], spacing: DS.Space.m) {
                    ForEach(budgeted, id: \.self) { c in budgetRing(c) }
                }
                .padding(.vertical, DS.Space.s)
            } header: { SectionHeader(title: "Budgets") }
            .listRowBackground(DS.Palette.surface)
        }
    }

    private func budgetRing(_ c: BudgetStatus.Category) -> some View {
        let budget = c.budget ?? 0
        let over = c.spent > budget
        return VStack(spacing: DS.Space.xs) {
            ProgressRing(progress: budget > 0 ? c.spent / budget : 0, accent: over ? DS.Palette.critical : accent, lineWidth: 5, size: 48)
            Text(c.category.capitalizedFirst).font(DS.Typo.caption)
            Text(Summaries.money(c.left ?? 0, currency) + " left").font(DS.Typo.caption)
                .foregroundStyle(over ? DS.Palette.critical : DS.Palette.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var subscriptionsSection: some View {
        Section {
            ForEach(money.subscriptions) { sub in
                ListRow(title: sub.name, subtitle: sub.renewsOn.flatMap(LifeCoding.parse).map { "Renews " + $0.formatted(date: .abbreviated, time: .omitted) }) {
                    RowValue(text: Summaries.money(sub.amount, sub.currency) + " / " + cycleLabel(sub.billingCycle))
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) { Task { await money.delete(sub) } }
                }
            }
            Button("Add subscription") { showSubscription = true }
        } header: {
            SectionHeader(title: money.subscriptions.isEmpty ? "Subscriptions" : "Subscriptions · \(Summaries.money(money.subscriptionsMonthly, currency)) a month")
        }
        .listRowBackground(DS.Palette.surface)
    }

    @ViewBuilder
    private var savingsSection: some View {
        let goals = store.items(in: area).filter { Savings.isGoal($0) }
        Section {
            ForEach(goals) { g in
                Button { addingTo = g } label: {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        HStack {
                            Text(g.title).font(DS.Typo.body)
                            Spacer()
                            Text("\(Summaries.money(Savings.saved(g), currency)) of \(Summaries.money(Savings.target(g), currency))")
                                .font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary).monospacedDigit()
                        }
                        ProgressView(value: Savings.progress(g)).tint(accent)
                    }
                    .padding(.vertical, DS.Space.xs)
                }
                .buttonStyle(.plain)
            }
            Button("New savings goal") { showGoal = true }
        } header: { SectionHeader(title: "Savings") }
        .listRowBackground(DS.Palette.surface)
    }

    private func cycleLabel(_ c: String) -> String {
        switch c { case "weekly": return "wk"; case "quarterly": return "qtr"; case "yearly": return "yr"; default: return "mo" }
    }
}

private struct ExpenseSheet: View {
    @Environment(MoneyStore.self) private var money
    @Environment(LifeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let categories: [String]
    @State private var amount = ""
    @State private var category = "food"
    @State private var note = ""

    private var parsed: Double? { Double(amount.replacingOccurrences(of: ",", with: ".")) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Amount", text: $amount).keyboardType(.decimalPad).font(DS.Typo.title)
                    Picker("Category", selection: $category) {
                        ForEach(categories, id: \.self) { c in Text(c.capitalizedFirst).tag(c) }
                    }
                    TextField("Note", text: $note)
                }
                .listRowBackground(DS.Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .dsScreen()
            .navigationTitle("Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let v = parsed else { return }
                        let c = category, n = note
                        Task {
                            await money.addExpense(amount: v, category: c, note: n)
                            await store.reload(["metrics"])
                            dismiss()
                        }
                    }
                    .disabled((parsed ?? 0) <= 0)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct SubscriptionSheet: View {
    @Environment(MoneyStore.self) private var money
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var amount = ""
    @State private var cycle = "monthly"
    @State private var renews = Date()
    private let cycles: [String] = ["weekly", "monthly", "quarterly", "yearly"]

    private var parsed: Double? { Double(amount.replacingOccurrences(of: ",", with: ".")) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Amount", text: $amount).keyboardType(.decimalPad)
                    Picker("Billed", selection: $cycle) {
                        ForEach(cycles, id: \.self) { c in Text(c.capitalizedFirst).tag(c) }
                    }
                    DatePicker("Next renewal", selection: $renews, displayedComponents: .date)
                } footer: { Text("You'll get a reminder 2 days before it renews.") }
                .listRowBackground(DS.Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .dsScreen()
            .navigationTitle("Subscription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let v = parsed else { return }
                        let n = name, c = cycle, r = renews
                        Task { await money.saveSubscription(name: n, amount: v, cycle: c, renewsOn: r); dismiss() }
                    }
                    .disabled(name.isEmpty || parsed == nil)
                }
            }
        }
    }
}

private struct SavingsGoalSheet: View {
    @Environment(LifeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let area: Area
    @State private var title = ""
    @State private var target = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What are you saving for?", text: $title)
                    TextField("Target amount", text: $target).keyboardType(.decimalPad)
                }
                .listRowBackground(DS.Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .dsScreen()
            .navigationTitle("Savings goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let t = Double(target.replacingOccurrences(of: ",", with: ".")), t > 0 else { return }
                        let name = title
                        Task {
                            await store.perform { repo in
                                let _: Item = try await repo.createItem(areaId: area.id, title: name, data: .object(["target_amount": .number(t), "saved_amount": .number(0)]))
                            }
                            await store.reload(["items"])
                            dismiss()
                        }
                    }
                    .disabled(title.isEmpty || Double(target.replacingOccurrences(of: ",", with: ".")) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct AddSavingsSheet: View {
    @Environment(LifeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let goal: Item
    let currency: String
    @State private var amount = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Amount to add (negative to withdraw)", text: $amount).keyboardType(.numbersAndPunctuation)
                } footer: {
                    Text("\(Summaries.money(Savings.saved(goal), currency)) of \(Summaries.money(Savings.target(goal), currency)) saved.")
                }
                .listRowBackground(DS.Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .dsScreen()
            .navigationTitle(goal.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let v = Double(amount.replacingOccurrences(of: ",", with: ".")) else { return }
                        let fields = Savings.adding(v, to: goal)
                        if fields["status"] != nil { DS.Haptics.success() }
                        Task { await store.update(goal, fields); dismiss() }
                    }
                    .disabled(Double(amount.replacingOccurrences(of: ",", with: ".")) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
