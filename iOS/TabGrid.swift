import SwiftUI

/// Every tab, grouped by machine, with previews; then the tabs on your other
/// devices; search pinned at the bottom (docs/UI.md).
struct TabGridView: View {
    @EnvironmentObject var store: Store
    let close: () -> Void
    let search: () -> Void
    let send: (PaneTab) -> Void
    let settings: () -> Void
    let pick: (UUID) -> Void

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.tabs.count == 1 ? "1 tab" : "\(store.tabs.count) tabs").font(.title.weight(.bold))
                Spacer()
                Button(action: settings) { Image(systemName: "gearshape").font(.title3).frame(width: 44, height: 44) }
                    .accessibilityLabel("Settings")
                Button("Done", action: close).font(.headline).foregroundStyle(Palette.link).frame(minHeight: 44)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(groups, id: \.machine.name) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            SectionTitle(text: group.machine.name, color: group.machine.tint)
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(group.tabs) { tab in
                                    TabCard(tab: tab, current: tab.id == store.selected,
                                            open: { pick(tab.id) }, send: { send(tab) }, close: { store.close(tab) })
                                }
                            }
                        }
                    }
                    if store.tabs.isEmpty {
                        Text("No tabs open on this phone.").foregroundStyle(Palette.secondary)
                    }
                    OtherDevicesSection()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 100)
            }
            .refreshable { store.syncNow() }
        }
        .foregroundStyle(Palette.text)
        .background(Palette.ground.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            Button(action: search) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                    Text("Open an app on any machine")
                    Spacer()
                }
                .font(.body)
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 18)
                .frame(height: 52)
                .background(Palette.field, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.08)))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var groups: [(machine: Machine, tabs: [PaneTab])] {
        Machine.defaults.compactMap { m in
            let tabs = store.tabs.filter { $0.machine.name == m.name }
            return tabs.isEmpty ? nil : (m, tabs)
        } + orphanGroup
    }

    /// Tabs on a machine no longer in machines.json still show.
    private var orphanGroup: [(machine: Machine, tabs: [PaneTab])] {
        let known = Set(Machine.defaults.map(\.name))
        return Dictionary(grouping: store.tabs.filter { !known.contains($0.machine.name) }, by: \.machine.name)
            .compactMap { _, tabs in tabs.first.map { ($0.machine, tabs) } }
    }
}

struct SectionTitle: View {
    let text: String
    var color: Color = Palette.secondary

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text.uppercased()).font(.footnote.weight(.semibold)).tracking(0.6).foregroundStyle(Palette.secondary)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

struct TabCard: View {
    @ObservedObject var tab: PaneTab
    let current: Bool
    let open: () -> Void
    let send: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: open) {
                Palette.surface
                    .aspectRatio(0.62, contentMode: .fit)
                    .overlay {
                        // The card keeps its shape; the preview fits inside it, whatever its own shape.
                        if let image = tab.preview {
                            Image(uiImage: image).resizable().scaledToFit()
                        } else {
                            AppTile(name: tab.appName, color: tab.machine.tint, size: 52)
                        }
                    }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(current ? tab.machine.tint : Color.white.opacity(0.06),
                                                                   lineWidth: current ? 2.5 : 1))
            }
            .accessibilityLabel("Switch to \(tab.appName) on \(tab.machine.name)")
            .accessibilityIdentifier("card")
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.appName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(tab.title).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action: send) {
                    Image(systemName: "rectangle.portrait.and.arrow.forward").font(.subheadline).frame(width: 36, height: 44)
                }
                .accessibilityLabel("Open \(tab.appName) on another device")
                .accessibilityIdentifier("send")
                Button(action: close) {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 32, height: 44)
                }
                .accessibilityLabel("Close \(tab.appName)")
                .accessibilityIdentifier("close")
            }
            .foregroundStyle(Palette.text)
        }
    }
}

/// A square tinted in the machine's colour with the app's first letter.
struct AppTile: View {
    let name: String
    let color: Color
    var size: CGFloat = 40

    var body: some View {
        Text(name.prefix(1).uppercased())
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

struct OtherDevicesSection: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "On your other devices")
            if store.otherDevices.isEmpty {
                Text("Open Panes in a browser on any of your machines and its tabs show up here.")
                    .font(.subheadline).foregroundStyle(Palette.secondary)
            }
            ForEach(store.otherDevices, id: \.id) { device in
                VStack(alignment: .leading, spacing: 0) {
                    Text(device.name).font(.footnote).foregroundStyle(Palette.secondary).padding(.vertical, 10)
                    if device.tabs.isEmpty {
                        Text("No tabs open").font(.subheadline).foregroundStyle(Palette.secondary).padding(.bottom, 12)
                    }
                    ForEach(Array(device.tabs.enumerated()), id: \.offset) { _, ref in
                        Divider().overlay(Color.white.opacity(0.06))
                        HStack(spacing: 10) {
                            Circle().fill(Machine.named(ref.machine)?.tint ?? Palette.secondary).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ref.app).font(.subheadline.weight(.medium))
                                Text([ref.machine, ref.title].compactMap { $0 }.filter { $0 != ref.app }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button(store.existing(ref) == nil ? "Open here" : "Switch") { store.open(ref) }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(Palette.raised, in: Capsule())
                                .accessibilityLabel("\(store.existing(ref) == nil ? "Open" : "Switch to") \(ref.app) from \(device.name)")
                        }
                        .frame(minHeight: 54)
                    }
                }
                .padding(.horizontal, 14)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}

struct SendSheet: View {
    @EnvironmentObject var store: Store
    @ObservedObject var tab: PaneTab
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Open “\(tab.appName)” on another device").font(.title3.weight(.semibold)).padding(.top, 24)
            Text("It shows up in Panes there and stays open here.").font(.subheadline).foregroundStyle(Palette.secondary)
                .padding(.bottom, 10)
            if store.otherDevices.isEmpty {
                Text("No other devices yet. Open Panes in a browser on any of your machines:")
                    .font(.subheadline).foregroundStyle(Palette.secondary).padding(.vertical, 8)
                ForEach(Machine.defaults.compactMap(\.web), id: \.self) { Text($0).font(.footnote.monospaced()).textSelection(.enabled) }
            }
            ForEach(store.otherDevices, id: \.id) { device in
                Divider().overlay(Color.white.opacity(0.06))
                Button {
                    store.send(tab, to: device)
                    done()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: device.kind == "phone" ? "iphone" : "macwindow").font(.title3).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.body.weight(.medium))
                            Text(device.kind == "phone" ? "Panes on a phone" : "Panes in a browser")
                                .font(.caption).foregroundStyle(Palette.secondary)
                        }
                        Spacer()
                    }
                    .frame(minHeight: 58)
                    .contentShape(Rectangle())
                }
                .foregroundStyle(Palette.text)
                .accessibilityLabel(device.name)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.surface)
        .onAppear { store.syncNow() }
    }
}

struct SettingsSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("fitWindows") private var fit = true
    @AppStorage("streamAudio") private var sound = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $store.deviceName)
                } header: {
                    Text("This device")
                } footer: {
                    Text("What your other devices call this phone when you send it a tab.")
                }
                Section {
                    Toggle("Fit windows to the phone", isOn: $fit)
                    Toggle("Play the app's sound", isOn: $sound)
                } footer: {
                    Text("Fitting resizes a Mac window to the phone's shape while its tab is open, and puts it back when you close the tab.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
