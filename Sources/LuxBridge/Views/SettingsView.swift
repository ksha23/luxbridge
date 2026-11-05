import LuxBridgeCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ServerSettingsView()
                .tabItem { Label("Home Assistant", systemImage: "house") }
            DisplaysSettingsView()
                .tabItem { Label("Displays", systemImage: "display") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 720, height: 680)
    }
}

private struct ServerSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var primary = ""
    @State private var secondary = ""
    @State private var token = ""
    @State private var result: (text: String, ok: Bool)?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $primary, prompt: Text("http://homeassistant.local:8123"))
                TextField("Second address", text: $secondary, prompt: Text("Optional, tried if the first fails"))
            } header: {
                Text("Server")
            } footer: {
                Text("LuxBridge only contacts Home Assistant while one of your chosen displays is connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                SecureField("Access token", text: $token, prompt: Text(model.hasToken ? "Saved in your Keychain" : "Paste a long-lived access token"))
            } header: {
                Text("Access token")
            } footer: {
                Text("In Home Assistant, open your profile, then Security, then create a long-lived access token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button(testing ? "Testing…" : "Save and Test") {
                        Task { await saveAndTest() }
                    }
                    .disabled(testing)
                    .keyboardShortcut(.defaultAction)
                    if let result {
                        Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(result.ok ? .green : .red)
                            .lineLimit(3)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            primary = model.config.servers.first ?? ""
            secondary = model.config.servers.dropFirst().first ?? ""
        }
    }

    private func saveAndTest() async {
        testing = true
        defer { testing = false }
        model.setServers([primary, secondary])
        if !token.isEmpty {
            model.setToken(token)
            token = ""
        }
        switch await model.testConnection() {
        case .success(let text): result = (text, true)
        case .failure(let error): result = (error.localizedDescription, false)
        }
    }
}

private struct DisplaysSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.config.rules) { rule in
                        Label(rule.display?.name ?? "New display", systemImage: "display").tag(rule.id)
                    }
                }
                Divider()
                HStack(spacing: 2) {
                    Button {
                        selection = model.addRule()
                    } label: {
                        Image(systemName: "plus").frame(width: 22, height: 22)
                    }
                    Button {
                        guard let selection else { return }
                        model.removeRule(id: selection)
                        self.selection = model.config.rules.first?.id
                    } label: {
                        Image(systemName: "minus").frame(width: 22, height: 22)
                    }
                    .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 190)
            Divider()
            if let selection, model.config.rules.contains(where: { $0.id == selection }) {
                RuleEditorView(ruleID: selection).id(selection)
            } else {
                Text("Add a display with +")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selection == nil { selection = model.config.rules.first?.id }
        }
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Toggle("Open at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, enabled in
                    do {
                        try LoginItem.set(enabled)
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        openAtLogin = LoginItem.isEnabled
                    }
                }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
            Toggle("Show the light and brightness in the menu bar", isOn: Binding(
                get: { model.config.showReadingsInMenuBar },
                set: { model.setShowReadingsInMenuBar($0) }
            ))
            Stepper(value: Binding(get: { model.config.pollSeconds }, set: { model.setPollSeconds($0) }), in: 1...30, step: 1) {
                Text("Check the sensor every \(Int(model.config.pollSeconds)) s")
            }
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")
        }
        .formStyle(.grouped)
    }
}
