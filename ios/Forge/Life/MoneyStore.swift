import Foundation
import Observation

struct BudgetStatus: Decodable, Equatable, Sendable {
    struct Category: Decodable, Equatable, Sendable, Hashable { var category: String; var spent: Double; var budget: Double?; var left: Double? }
    var month: String
    var currency: String?
    var monthlyBudget: Double?
    var spent: Double
    var daysLeft: Int?
    var subscriptionsMonthly: Double?
    var categories: [Category]
}

struct Subscription: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var amount: Double
    var currency: String
    var billingCycle: String
    var renewsOn: String?
    var reminderId: UUID?

    /// Cost per month, for the total.
    var monthly: Double {
        switch billingCycle {
        case "weekly": return amount * 52 / 12
        case "quarterly": return amount / 3
        case "yearly": return amount / 12
        default: return amount
        }
    }
}

/// Expenses, budgets, subscriptions and savings goals. Budgets and the currency live in the finance area's config.
@Observable
@MainActor
final class MoneyStore {
    private(set) var status: BudgetStatus?
    private(set) var subscriptions: [Subscription] = []
    var lastError: String?
    private var client: SupabaseClient?

    func connect(_ client: SupabaseClient?) async {
        self.client = client
        guard let client else { status = nil; subscriptions = []; return }
        // Moves past renewals forward and refreshes their reminders.
        let _: Int? = try? await LifeRepository(client: client).rpc("ai_roll_subscriptions")
        await reload()
    }

    func reload() async {
        guard let client else { return }
        let repo = LifeRepository(client: client)
        status = try? await repo.rpc("ai_budget_status")
        subscriptions = (try? await repo.get("subscriptions", ["select": "id,name,amount,currency,billing_cycle,renews_on,reminder_id", "order": "renews_on.asc.nullslast"])) ?? []
    }

    func addExpense(amount: Double, category: String, note: String?) async {
        guard let client else { return }
        do {
            let _: JSONValue = try await LifeRepository(client: client).rpc("ai_log_expense", [
                "p_amount": .number(amount), "p_category": .string(category), "p_note": .of(note?.nilIfBlank),
            ])
            lastError = nil
        } catch { lastError = error.localizedDescription }
        await reload()
    }

    func saveSubscription(name: String, amount: Double, cycle: String, renewsOn: Date) async {
        guard let client else { return }
        do {
            let _: JSONValue = try await LifeRepository(client: client).rpc("ai_upsert_subscription", ["p": .object([
                "name": .string(name), "amount": .number(amount), "billing_cycle": .string(cycle), "renews_on": .string(LifeCoding.dayString(renewsOn)),
            ])])
            lastError = nil
        } catch { lastError = error.localizedDescription }
        await reload()
    }

    func delete(_ s: Subscription) async {
        guard let client else { return }
        let _: JSONValue? = try? await LifeRepository(client: client).rpc("ai_delete_subscription", ["p_id": .of(s.id)])
        await reload()
    }

    var subscriptionsMonthly: Double { subscriptions.map(\.monthly).reduce(0, +) }
}

/// Savings goals are items in the finance area with data {"target_amount": 1000, "saved_amount": 250}.
enum Savings {
    static func isGoal(_ item: Item) -> Bool { item.data["target_amount"]?.double != nil }
    static func target(_ item: Item) -> Double { item.data["target_amount"]?.double ?? 0 }
    static func saved(_ item: Item) -> Double { item.data["saved_amount"]?.double ?? 0 }
    static func progress(_ item: Item) -> Double { target(item) > 0 ? min(1, saved(item) / target(item)) : 0 }

    /// Fields to save after adding `amount` (also keeps the item's progress in step).
    static func adding(_ amount: Double, to item: Item) -> Row {
        let saved = max(0, Self.saved(item) + amount)
        let pct = target(item) > 0 ? Int((min(1, saved / target(item)) * 100).rounded()) : 0
        var fields: Row = ["data": item.data.setting("saved_amount", .number(saved)), "progress": .int(pct)]
        if pct >= 100 { fields["status"] = .string("done"); fields["completed_at"] = .of(Date()) }
        return fields
    }
}

extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

extension LifeStore {
    /// The first finance area (expenses land here), created as "Money" on first use.
    func financeArea() async -> Area? {
        if let a = areas.first(where: { $0.kind == "finance" }) { return a }
        return await createArea(name: "Money", kind: "finance", icon: "creditcard", color: "#F2A93B")
    }
}
