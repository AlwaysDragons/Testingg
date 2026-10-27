import SwiftUI

/// Settings for the life dashboard. The existing Forge settings (Hevy, Apple Health, coach) open from here unchanged.
struct LifeSettingsView: View {
    @Environment(LifeStore.self) private var store
    @Environment(CloudSync.self) private var cloud
    @State private var showLegacySettings = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Areas") { AreasSettingsView() }
                    NavigationLink("Features") { FeaturesSettingsView() }
                    NavigationLink("Reminders and notifications") { RemindersSettingsView() }
                    if store.isEnabled(.calendar) { NavigationLink("Calendar") { CalendarSettingsView() } }
                }
                .listRowBackground(DS.Palette.surface)
                Section {
                    Button("Training, Hevy and Apple Health") { showLegacySettings = true }
                    NavigationLink("Cloud sync") { CloudSettingsView() }
                } footer: {
                    Text(cloud.isSignedIn ? "Signed in. Changes sync in real time." : "Not signed in.")
                }
                .listRowBackground(DS.Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .dsScreen()
            .navigationTitle("Settings")
            .sheet(isPresented: $showLegacySettings) { LegacySettingsSheet() }
        }
    }
}

/// The existing Forge Settings screen, presented as-is.
private struct LegacySettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(CloudSync.self) private var cloud
    var body: some View {
        SettingsView()
            .environment(model)
            .environment(cloud)
            .tint(Theme.accent)
            .environment(\.colorScheme, .dark)
    }
}

/// Reorder, pin, hide, recolor and delete areas.
struct AreasSettingsView: View {
    @Environment(LifeStore.self) private var store
    @State private var editing: Area?
    @State private var showNew = false

    var body: some View {
        List {
            Section {
                ForEach(store.areas) { area in
                    HStack(spacing: DS.Space.m) {
                        Image(systemName: area.symbol)
                            .foregroundStyle(DS.Palette.area(hex: area.color, kind: area.kind))
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(area.name).font(DS.Typo.body).foregroundStyle(area.hidden ? DS.Palette.secondary : DS.Palette.primary)
                            Text(area.hidden ? "Hidden" : area.pinned ? "On Home" : "Not on Home")
                                .font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editing = area }
                    .swipeActions(edge: .trailing) {
                        Button(area.hidden ? "Show" : "Hide", systemImage: area.hidden ? "eye" : "eye.slash") {
                            Task { await store.updateArea(area, ["hidden": .bool(!area.hidden)]) }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button(area.pinned ? "Unpin" : "Pin", systemImage: area.pinned ? "pin.slash" : "pin") {
                            Task { await store.updateArea(area, ["pinned": .bool(!area.pinned)]) }
                        }
                        .tint(DS.Palette.accent)
                    }
                }
                .onMove { from, to in
                    var ordered = store.areas
                    ordered.move(fromOffsets: from, toOffset: to)
                    Task { await store.reorder(ordered) }
                }
            } footer: {
                Text("Drag to reorder Home. Swipe to pin or hide.")
            }
            .listRowBackground(DS.Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .dsScreen()
        .navigationTitle("Areas")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .bottomBar) { Button("New area", systemImage: "plus") { showNew = true } }
        }
        .sheet(item: $editing) { AreaEditor(area: $0) }
        .sheet(isPresented: $showNew) { AreaEditor(area: nil) }
    }
}

/// Every feature beyond the core starts off; switch on what you want.
struct FeaturesSettingsView: View {
    @Environment(LifeStore.self) private var store

    var body: some View {
        Form {
            Section {
                ForEach(Feature.allCases) { feature in
                    Toggle(feature.title, isOn: Binding(
                        get: { store.isEnabled(feature) },
                        set: { on in Task { await store.setFeature(feature, on) } }
                    ))
                }
            } footer: {
                Text("Features stay out of sight until you turn them on.")
            }
            .listRowBackground(DS.Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .dsScreen()
        .navigationTitle("Features")
        .disabled(store.settings == nil)
    }
}
