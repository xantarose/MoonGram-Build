import MoonGramCore
import SwiftUI

@available(iOS 16.0, *)
struct MoonPrivacyView: View {
    @ObservedObject var model: MoonViewModel

    private func binding(_ keyPath: WritableKeyPath<MoonPrivacySettings, Bool>) -> Binding<Bool> {
        Binding(get: { (self.model.settings?.privacy ?? MoonPrivacySettings())[keyPath: keyPath] }, set: { value in
            self.model.mutate { settings in
                var privacy = settings.privacy ?? MoonPrivacySettings()
                privacy[keyPath: keyPath] = value
                settings.privacy = privacy
            }
        })
    }

    var body: some View {
        List {
            Section {
                Toggle("Не отправлять прочтение", isOn: self.binding(\.hideReadReceipts))
                Toggle("Скрывать набор и запись", isOn: self.binding(\.hideTyping))
                Toggle("Не показывать онлайн", isOn: self.binding(\.hideOnline))
                Toggle("Скрывать просмотры историй", isOn: self.binding(\.hideStoryViews))
            } header: {
                Text("Гостевой режим")
            } footer: {
                Text("Настройки относятся к этому аккаунту на этом устройстве и работают независимо от визуалов.")
            }
            Section {
                Text("Нечиталка относится к облачным чатам и просмотрам медиа. В секретных чатах сохраняются обычные подтверждения и таймеры.")
                Text("Уже отправленные события отменить нельзя. Другие устройства продолжают работать со своими настройками. После отключения нечиталки следующее прочтение может подтвердить и более ранние сообщения.")
            } header: {
                Text("Как это работает")
            }
            Section {
                Text("Эти функции противоречат правилам API Telegram. Ограничения со стороны Telegram возможны; гарантии отсутствия блокировок нет.")
            } header: {
                Text("Перед включением")
            }
        }
        .navigationTitle("Гостевой режим")
        .disabled(self.model.busy || self.model.settings == nil)
    }
}
