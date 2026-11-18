import MoonGramCore
import SwiftUI

@available(iOS 16.0, *)
struct MoonStreakView: View {
    let accountID: Int64
    let peerID: Int64
    @State private var streak: MoonStreakSummary?
    @State private var error: String?

    var body: some View {
        Form {
            if let streak = self.streak {
                Section {
                    Label("\(streak.days) дн.", systemImage: "flame.fill")
                        .font(.title2.bold())
                        .foregroundStyle(streak.days >= 30 ? Color.purple : streak.days >= 7 ? Color.orange : Color.primary)
                    if streak.canRestoreYesterday {
                        Button("Восстановить вчерашний день") {
                            self.load(restore: true)
                        }
                    }
                    Text("Осталось восстановлений в этом месяце: \(streak.remainingRestores)")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Засчитывается день, когда MoonGram загрузил сообщения от обоих участников личного чата. Дни и месяц считаются по UTC. Счётчик виден только на этом устройстве.")
                }
            }
            if let error = self.error { Text(error).foregroundStyle(.secondary) }
        }
        .task { self.load(restore: false) }
    }

    private func load(restore: Bool) {
        let accountID = self.accountID
        let peerID = self.peerID
        Task { @MainActor in
            do {
                self.streak = try await Task.detached(priority: .utility) {
                    if restore { return try MoonStore.shared.restoreStreak(accountID: accountID, peerID: peerID) }
                    return try MoonStore.shared.streakSummary(accountID: accountID, peerID: peerID)
                }.value
                self.error = nil
            } catch {
                self.error = "Не удалось обновить счётчик."
            }
        }
    }
}
