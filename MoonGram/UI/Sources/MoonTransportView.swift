import SwiftUI

/// The library owns the UI. The full client supplies Telegram's actual engine preference.
@available(iOS 16.0, *)
public struct MoonTransportControls {
    public var prefersWebFallback: @MainActor () async -> Bool
    public var setWebFallback: @MainActor (Bool) async -> Void
    public var usesAlternateEngine: @MainActor () -> Bool

    public init(prefersWebFallback: @escaping @MainActor () async -> Bool,
                setWebFallback: @escaping @MainActor (Bool) async -> Void,
                usesAlternateEngine: @escaping @MainActor () -> Bool) {
        self.prefersWebFallback = prefersWebFallback
        self.setWebFallback = setWebFallback
        self.usesAlternateEngine = usesAlternateEngine
    }
}

@available(iOS 16.0, *)
struct MoonTransportView: View {
    let controls: MoonTransportControls
    @State private var preferred: Bool?
    @State private var saving = false

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
                Text("MoonGram попробует подключиться к Telegram по WebSocket, если прямая связь не работает. Дополнительный сервер и VPN для этого режима не нужны.")
            }
        }
        .navigationTitle("Подключение")
        .task { self.preferred = await self.controls.prefersWebFallback() }
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
