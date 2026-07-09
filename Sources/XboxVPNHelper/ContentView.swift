import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published var mode: AppMode = .basic
    @Published var snapshot = AppSnapshot()
    @Published var log = "Нажми «Включить», и приложение само попробует поднять схему Xbox через VPN."
    @Published var generatedScript = ""
    @Published var isBusy = false
    @Published var autoRefreshEnabled = true
    @Published var lastUpdatedText = "Ещё не обновлялось"
    @Published var setupStage: SetupStage = .idle

    private var refreshTimer: Timer?
    private let service = VPNService(preferredEthernetInterface: nil)

    func runCheck() {
        isBusy = true
        log = "Собираю безопасный статус только на чтение..."

        Task {
            defer { isBusy = false }

            do {
                let result = try await Task.detached { [service] in
                    let freshSnapshot = try service.collectSnapshot()
                    let generatedScript = freshSnapshot.resolvedConfig.map { service.buildStartScript(for: $0) } ?? ""
                    return (freshSnapshot, generatedScript)
                }.value

                snapshot = result.0
                generatedScript = result.1
                lastUpdatedText = Self.timestampFormatter.string(from: Date())
                if setupStage == .verifyingAfterXboxReboot {
                    setupStage = result.0.overallLevel == .error ? .readyForXboxReboot : .complete
                }
                log = buildSummary(from: result.0)
            } catch {
                log = "Проверка сорвалась: \(error.localizedDescription)"
            }
        }
    }

    func runEnable() {
        runPrivilegedAction(actionName: "Включение") { service, config in
            service.buildStartScript(for: config)
        }
    }

    func runReconnect() {
        runPrivilegedAction(actionName: "Переподключение") { service, config in
            service.buildReconnectScript(for: config)
        }
    }

    func refreshScriptPreview() {
        do {
            let config = try service.resolveConfiguration()
            generatedScript = service.buildStartScript(for: config)
            log = "Скрипт обновлён по автоматически найденной конфигурации."
        } catch {
            log = "Не удалось обновить скрипт: \(error.localizedDescription)"
        }
    }

    func confirmXboxRebootAndVerify() {
        setupStage = .verifyingAfterXboxReboot
        log = "Проверяю состояние после перезагрузки Xbox..."
        runCheck()
    }

    func installApp() {
        isBusy = true
        log = "Устанавливаю приложение в /Applications..."

        Task {
            defer { isBusy = false }

            do {
                let appURL = Bundle.main.bundleURL
                guard appURL.pathExtension == "app" else {
                    log = "Установка из исходников не поддерживается прямо из UI. Сначала собери bundle через ./build_app.sh, затем открой .app."
                    return
                }

                let shellScript = """
                set -euo pipefail
                SRC_APP=\(shellQuote(appURL.path))
                DEST_APP="/Applications/\(appURL.lastPathComponent)"
                rm -rf "$DEST_APP"
                cp -R "$SRC_APP" "$DEST_APP"
                echo "Приложение установлено в $DEST_APP"
                """

                let result = try CommandRunner.runShell(shellScript)
                log = "Установка завершена.\n\n\(result.output)"
            } catch {
                do {
                    let appURL = Bundle.main.bundleURL
                    guard appURL.pathExtension == "app" else {
                        log = "Установка из исходников не поддерживается прямо из UI. Сначала собери bundle через ./build_app.sh, затем открой .app."
                        return
                    }

                    let privilegedScript = """
                    #!/bin/bash
                    set -euo pipefail
                    SRC_APP=\(shellQuote(appURL.path))
                    DEST_APP="/Applications/\(appURL.lastPathComponent)"
                    rm -rf "$DEST_APP"
                    cp -R "$SRC_APP" "$DEST_APP"
                    echo "Приложение установлено в $DEST_APP"
                    """
                    let result = try PrivilegedScriptRunner.run(script: privilegedScript)
                    log = "Установка завершена.\n\n\(result.output)"
                } catch {
                    log = "Установка не выполнена: \(error.localizedDescription)"
                }
            }
        }
    }

    func configureAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        guard autoRefreshEnabled else {
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isBusy {
                    self.runCheck()
                }
            }
        }
        timer.tolerance = 2
        refreshTimer = timer
    }

    private func runPrivilegedAction(
        actionName: String,
        scriptBuilder: @escaping (VPNService, ResolvedConfig) -> String
    ) {
        isBusy = true
        log = "\(actionName): подбираю интерфейсы и запрашиваю права администратора..."

        Task {
            defer { isBusy = false }

            do {
                let config = try service.resolveConfiguration()
                let script = scriptBuilder(service, config)
                generatedScript = script
                let result = try PrivilegedScriptRunner.run(script: script)
                setupStage = .readyForXboxReboot
                log = "\(actionName) завершено.\n\n\(result.output)\n\nТеперь перезагрузи Xbox, а затем нажми кнопку «Я перезагрузил Xbox»."
                let freshSnapshot = try service.collectSnapshot()
                snapshot = freshSnapshot
                lastUpdatedText = Self.timestampFormatter.string(from: Date())
            } catch {
                log = "\(actionName) не выполнено: \(error.localizedDescription)"
            }
        }
    }

    private func buildSummary(from snapshot: AppSnapshot) -> String {
        let config = snapshot.resolvedConfig
        let vpn = config?.detectedVPNInterface.map { "\($0) (\(config?.detectedVPNAddress ?? "без IPv4"))" } ?? "не найден"

        return """
        Статус обновлён.
        Обновлено: \(lastUpdatedText)
        Режим: \(mode.title)
        Этап: \(setupStage.title)
        Ethernet: \(config?.ethernetInterface ?? "не найден") \(snapshot.ethernetIsActive ? "активен" : "неактивен")
        VPN: \(vpn)
        Mac IP: \(snapshot.ethernetHasExpectedIP ? "на месте" : "отсутствует")
        Xbox: \(snapshot.xboxVisibleOnLAN ? "виден" : "не виден")
        Форвардинг: \(snapshot.ipForwardingEnabled ? "включён" : "выключен")
        Автопочинка: \(snapshot.guardRunning ? "запущена" : "не запущена")
        Caffeinate: \(snapshot.caffeinateRunning ? "запущен" : "не запущен")
        """
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

struct ContentView: View {
    @StateObject private var model = AppViewModel()

    var body: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                header
                modePicker

                if model.mode == .basic {
                    basicPanel
                } else {
                    advancedPanel
                }
            }
            .padding(20)
            .frame(width: 900, height: 780)
        }
        .preferredColorScheme(.light)
        .foregroundStyle(.black)
        .onAppear {
            model.configureAutoRefresh()
            model.runCheck()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Xbox VPN Helper")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                Text("Одна кнопка для обычного запуска и полный статус для тех случаев, когда хочется понять, что именно сломалось.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.2, green: 0.2, blue: 0.2))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Toggle(
                    "Автообновление каждые 15 сек.",
                    isOn: Binding(
                        get: { model.autoRefreshEnabled },
                        set: { newValue in
                            model.autoRefreshEnabled = newValue
                            model.configureAutoRefresh()
                        }
                    )
                )
                .toggleStyle(.switch)
                .foregroundStyle(.black)

                Text("Последняя проверка: \(model.lastUpdatedText)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.25, green: 0.25, blue: 0.25))
            }
        }
    }

    private var modePicker: some View {
        Picker("Режим", selection: $model.mode) {
            ForEach(AppMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var basicPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Быстрый запуск") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: model.snapshot.overallLevel.symbol)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(color(for: model.snapshot.overallLevel))

                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.snapshot.overallTitle)
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(.black)

                            Text(basicSubtitle)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Color(red: 0.2, green: 0.2, blue: 0.2))
                        }

                        Spacer()
                    }

                    stageBanner

                    Button {
                        model.runEnable()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Включить Xbox через VPN")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            Spacer()
                        }
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if model.setupStage == .readyForXboxReboot || model.setupStage == .verifyingAfterXboxReboot {
                        Button {
                            model.confirmXboxRebootAndVerify()
                        } label: {
                            HStack {
                                Spacer()
                                Text("Я перезагрузил Xbox, проверить ещё раз")
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                    }

                    if !model.snapshot.failingItems.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Если что-то не сработает, вот что сейчас выглядит подозрительно:")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.black)

                            ForEach(model.snapshot.failingItems.prefix(4)) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: item.level.symbol)
                                        .foregroundStyle(color(for: item.level))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        Text(item.detail)
                                            .font(.system(size: 12, weight: .regular, design: .rounded))
                                            .foregroundStyle(Color(red: 0.22, green: 0.22, blue: 0.22))
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            logPanel
        }
    }

    private var advancedPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            stageBanner
            autoConfigPanel
            checklistPanel
            actions
            logPanel
            scriptPanel
        }
    }

    private var autoConfigPanel: some View {
        GroupBox("Автоматически найдено") {
            let config = model.snapshot.resolvedConfig

            HStack(spacing: 12) {
                infoCard(
                    title: "Ethernet",
                    value: config.map { "\($0.ethernetInterface) · \($0.ethernetLabel)" } ?? "Поиск..."
                )
                infoCard(
                    title: "Mac IP",
                    value: config?.macAddress ?? "10.0.0.1"
                )
                infoCard(
                    title: "Xbox IP",
                    value: config?.xboxAddress ?? "10.0.0.2"
                )
                infoCard(
                    title: "VPN",
                    value: config?.detectedVPNInterface ?? "Не найден"
                )
            }
        }
    }

    private var checklistPanel: some View {
        GroupBox("Чек-лист") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(model.snapshot.items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.level.symbol)
                            .foregroundStyle(color(for: item.level))
                            .font(.system(size: 18, weight: .bold))
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(.black)
                            Text(item.detail)
                                .font(.system(size: 12, weight: .regular, design: .rounded))
                                .foregroundStyle(Color(red: 0.22, green: 0.22, blue: 0.22))
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(Color(red: 0.96, green: 0.96, blue: 0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.black.opacity(0.06), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("Проверить") {
                model.runCheck()
            }
            .keyboardShortcut("r", modifiers: [.command])

            Button("Включить") {
                model.runEnable()
            }
            .buttonStyle(.borderedProminent)

            if model.setupStage == .readyForXboxReboot || model.setupStage == .verifyingAfterXboxReboot {
                Button("Xbox перезагружен, проверить") {
                    model.confirmXboxRebootAndVerify()
                }
            }

            Button("Переподключить") {
                model.runReconnect()
            }

            Button("Показать скрипт") {
                model.refreshScriptPreview()
            }

            Button("Установить в Applications") {
                model.installApp()
            }

            Spacer()

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var logPanel: some View {
        GroupBox("Лог") {
            ScrollView {
                Text(model.log)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.black)
                    .textSelection(.enabled)
            }
            .frame(height: 140)
        }
    }

    private var scriptPanel: some View {
        GroupBox("Предпросмотр скрипта") {
            ScrollView {
                Text(model.generatedScript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.black)
                    .textSelection(.enabled)
            }
            .frame(height: 190)
        }
    }

    private var basicSubtitle: String {
        let config = model.snapshot.resolvedConfig
        let ethernet = config?.ethernetInterface ?? "поиск Ethernet"
        let vpn = config?.detectedVPNInterface ?? "поиск VPN"
        return "Сейчас приложение ориентируется на \(ethernet) и \(vpn). Если сеть уже поднята, кнопка просто освежит рабочее состояние."
    }

    private var stageBanner: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: stageSymbol)
                .foregroundStyle(color(for: stageLevel))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.setupStage.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text(stageDescription)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(Color(red: 0.22, green: 0.22, blue: 0.22))
            }
            Spacer()
        }
        .padding(12)
        .background(Color(red: 0.97, green: 0.97, blue: 0.97))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var stageDescription: String {
        switch model.setupStage {
        case .idle:
            return "Приложение ждёт запуска основного сценария."
        case .readyForXboxReboot:
            return "Mac уже настроен. Если Xbox включён, перезагрузи его и потом запусти повторную проверку."
        case .verifyingAfterXboxReboot:
            return "Идёт повторная проверка после перезагрузки Xbox."
        case .complete:
            return "Сценарий прошёл до конца, и статус выглядит рабочим."
        }
    }

    private var stageLevel: HealthLevel {
        switch model.setupStage {
        case .idle:
            return .unknown
        case .readyForXboxReboot:
            return .warning
        case .verifyingAfterXboxReboot:
            return .unknown
        case .complete:
            return .ok
        }
    }

    private var stageSymbol: String {
        switch model.setupStage {
        case .idle:
            return "ellipsis.circle"
        case .readyForXboxReboot:
            return "arrow.clockwise.circle"
        case .verifyingAfterXboxReboot:
            return "hourglass.circle"
        case .complete:
            return "checkmark.seal.fill"
        }
    }

    private func infoCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.black)
            Text(value)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.18, green: 0.18, blue: 0.18))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(red: 0.96, green: 0.96, blue: 0.96))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func color(for level: HealthLevel) -> Color {
        switch level {
        case .ok:
            return Color(red: 0.1, green: 0.55, blue: 0.3)
        case .warning:
            return Color(red: 0.82, green: 0.55, blue: 0.08)
        case .error:
            return Color(red: 0.75, green: 0.2, blue: 0.18)
        case .unknown:
            return Color(red: 0.35, green: 0.4, blue: 0.48)
        }
    }
}
