import SwiftUI

/// The library owns the UI. The full client supplies Telegram's actual engine preference.
@available(iOS 16.0, *)
public struct MoonTransportControls {
    public var prefersWebFallback: @MainActor () async -> Bool
    public var setWebFallback: @MainActor (Bool) async -> Void
    public var usesAlternateEngine: @MainActor () -> Bool
    public var connectionStatus: @MainActor () async -> String
    public var openProxySettings: @MainActor () -> Void

    public init(prefersWebFallback: @escaping @MainActor () async -> Bool,
                setWebFallback: @escaping @MainActor (Bool) async -> Void,
                usesAlternateEngine: @escaping @MainActor () -> Bool,
                connectionStatus: @escaping @MainActor () async -> String,
                openProxySettings: @escaping @MainActor () -> Void) {
        self.prefersWebFallback = prefersWebFallback
        self.setWebFallback = setWebFallback
        self.usesAlternateEngine = usesAlternateEngine
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
                    Toggle("Резерв через WebSocket", isOn: Binding(get: { preferred }, set: self.change)).tint(MoonAccent.control)
                        .disabled(self.saving)
                    if preferred != self.controls.usesAlternateEngine() {
                        Text("Закрой MoonGram через переключатель приложений и открой снова.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Читаю настройки подключения…")
                }
            } footer: {
                Text("WebSocket используется при сбое обычного подключения. Значок прокси открывает настройки серверов.")
            }
            Section("Состояние") {
                LabeledContent("Telegram", value: self.status.isEmpty ? "Проверяю…" : self.status)
                LabeledContent("Сетевой движок", value: self.controls.usesAlternateEngine() ? "С резервом WebSocket" : "Стандартный")
                Button("Открыть прокси") { self.controls.openProxySettings() }
            }
        }
        .navigationTitle("Подключение")
        .task {
            self.preferred = await self.controls.prefersWebFallback()
            while !Task.isCancelled {
                self.status = await self.controls.connectionStatus()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func change(_ enabled: Bool) {
        self.saving = true
        Task { @MainActor in
            await self.controls.setWebFallback(enabled)
            self.preferred = await self.controls.prefersWebFallback()
            self.saving = false
        }
    }
}
