import SwiftUI

/// The library owns the UI. The full client supplies Telegram's actual engine preference.
@available(iOS 16.0, *)
public struct MoonTransportControls {
    public var isEnabled: @MainActor () async -> Bool
    public var setEnabled: @MainActor (Bool) async -> Void
    public var connectionStatus: @MainActor () async -> String
    public var openProxySettings: @MainActor () -> Void

    public init(isEnabled: @escaping @MainActor () async -> Bool,
                setEnabled: @escaping @MainActor (Bool) async -> Void,
                connectionStatus: @escaping @MainActor () async -> String,
                openProxySettings: @escaping @MainActor () -> Void) {
        self.isEnabled = isEnabled
        self.setEnabled = setEnabled
        self.connectionStatus = connectionStatus
        self.openProxySettings = openProxySettings
    }
}

@available(iOS 16.0, *)
struct MoonTransportView: View {
    let controls: MoonTransportControls
    @State private var preferred: Bool?
    @State private var saving = false
    @State private var status = ""

    var body: some View {
        Form {
            Section {
                if let preferred = self.preferred {
                    Toggle("Telegram WebSocket", isOn: Binding(get: { preferred }, set: self.change)).tint(MoonAccent.control)
                        .disabled(self.saving)

                } else {
                    ProgressView("Читаю настройки подключения…")
                }
            } footer: {
                Text("При включении MoonGram добавит и выберет Telegram WebSocket в списке прокси. Соединение ведёт к дата-центру Telegram. Адрес и пароль вводить не нужно.")
            }
            Section("Состояние") {
                LabeledContent("Telegram", value: self.status.isEmpty ? "Проверяю…" : self.status)
                Button("Открыть прокси") { self.controls.openProxySettings() }
            }
        }
        .navigationTitle("Подключение")
        .task {
            self.preferred = await self.controls.isEnabled()
            while !Task.isCancelled {
                self.status = await self.controls.connectionStatus()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func change(_ enabled: Bool) {
        self.saving = true
        Task { @MainActor in
            await self.controls.setEnabled(enabled)
            self.preferred = await self.controls.isEnabled()
            self.saving = false
        }
    }
}
