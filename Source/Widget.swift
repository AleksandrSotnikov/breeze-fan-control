import AppKit
import SwiftUI
import Combine
import Darwin

private let mint = Color(red: 0.44, green: 0.92, blue: 0.78)

private final class SensorReader: @unchecked Sendable {
    var smc: SMC? // Accessed only from sensorQueue.
}

@MainActor final class WidgetModel: ObservableObject {
    @Published var fans: [Fan] = []
    @Published var temperature: Double?
    @Published var history: [Double] = []
    @Published var message = "Подключение к датчикам…"
    @Published var error: String?
    @Published var busy = false
    @Published var controlling = false
    @Published var remaining = 0
    @Published var pinned = UserDefaults.standard.bool(forKey: "tileAlwaysOnTop")
    private let reader = SensorReader()
    private let sensorQueue = DispatchQueue(label: "breeze.sensors", qos: .utility)
    private var reading = false
    private var timer: Timer?
    private var session: URL?
    private var request: ControlRequest?
    private var helperRunning = false
    private var shutdownCallbacks: [() -> Void] = []
    var manual: Bool { fans.contains { $0.mode == 1 } }
    var fresh = false

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }
    func tick() {
        heartbeat()
        if !reading {
            reading = true
            let reader = self.reader
            sensorQueue.async { [weak self] in
                do {
                    // SMC object stays exclusively on this serial queue.
                    guard let self else { return }
                    let smc = try reader.smc ?? SMC()
                    reader.smc = smc
                    let fans = try smc.fans()
                    let temp = try? smc.temperature()
                    DispatchQueue.main.async {
                        self.fans = fans; self.temperature = temp; self.reading = false; self.fresh = true
                        if let temp { self.history.append(temp); self.history = Array(self.history.suffix(45)) }
                        if self.request == nil && !self.busy { self.message = "Управляет macOS" }
                    }
                } catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async {
                        self?.reading = false; self?.fresh = false; self?.temperature = nil
                        self?.error = message; self?.message = "Нет данных SMC"
                    }
                }
            }
        }
    }
    private func heartbeat() {
        guard var request, let session else { return }
        let now = Date().timeIntervalSince1970
        if now - request.issuedAt >= 900 { request.stop = true; self.request = request }
        request.heartbeat = now
        do { try JSONEncoder().encode(request).write(to: session.appendingPathComponent("request.json"), options: .atomic) }
        catch { self.error = "Не удалось передать команду помощнику." }
        remaining = max(0, Int(900 - (now - request.issuedAt)))
        if let data = try? Data(contentsOf: session.appendingPathComponent("status.json")),
           let status = try? JSONDecoder().decode(ControlStatus.self, from: data) {
            message = status.message
            if status.revision == request.revision && status.active { busy = false; controlling = !request.stop && request.targets.values.contains { $0 >= 0 } }
            if !status.active {
                controlling = false; busy = false; self.request = nil
                if status.message != "Управление возвращено macOS." { self.error = status.message }
            }
        }
    }
    func apply(_ targets: [String: Double]) {
        guard fresh, !busy else { return }
        guard !helperRunning || request != nil else { return }
        error = nil
        let now = Date().timeIntervalSince1970
        busy = true
        if helperRunning, request != nil {
            var merged = request!.targets
            for (key, value) in targets { merged[key] = value }
            request = ControlRequest(heartbeat: now, revision: request!.revision + 1, issuedAt: now, targets: merged, stop: false)
            heartbeat(); return
        }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("breeze-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data().write(to: folder.appendingPathComponent("status.json"))
            session = folder
            request = ControlRequest(heartbeat: now, revision: 1, issuedAt: now, targets: targets, stop: false)
            heartbeat(); message = "Ожидаю пароль администратора…"
            startHelper(folder)
        } catch { self.error = error.localizedDescription; busy = false }
    }
    private func startHelper(_ folder: URL) {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "BreezeHelper") else {
            error = "BreezeHelper отсутствует в приложении."; busy = false; return
        }
        helperRunning = true
        let command = [helper.path, "--session", folder.path, String(getuid()), String(getpid())].map(shellQuote).joined(separator: " ")
        let script = "do shell script " + appleQuote(command) + " with administrator privileges with prompt " + appleQuote("Breeze: разрешить временное управление вентиляторами?")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // AppleScript's default AppleEvent timeout is avoided by executing a local script.
        process.arguments = ["-e", "with timeout of 86400 seconds\n" + script + "\nend timeout"]
        let stderrPipe = Pipe(); process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.heartbeat()
                self.helperRunning = false; self.busy = false; self.controlling = false
                self.request = nil
                if process.terminationStatus != 0 {
                    self.error = text.contains("-128") ? "Запрос прав отменён." : "Не удалось запустить помощник: " + text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if self.session == folder { self.session = nil }
                try? FileManager.default.removeItem(at: folder)
                let callbacks = self.shutdownCallbacks; self.shutdownCallbacks = []; callbacks.forEach { $0() }
            }
        }
        do { try process.run() } catch {
            helperRunning = false; request = nil; busy = false; self.error = error.localizedDescription
        }
    }
    func autoAll() {
        if helperRunning, var req = request {
            req.targets = Dictionary(uniqueKeysWithValues: fans.map { (String($0.id), -1.0) })
            req.revision += 1; req.issuedAt = Date().timeIntervalSince1970; request = req
            busy = true; heartbeat()
        } else { apply(Dictionary(uniqueKeysWithValues: fans.map { (String($0.id), -1.0) })) }
    }
    func stop(completion: (() -> Void)? = nil) {
        guard helperRunning, var req = request else { completion?(); return }
        if let completion { shutdownCallbacks.append(completion) }
        req.stop = true; request = req; heartbeat()
        message = "Возвращаю управление macOS…"
    }
    func togglePin() {
        pinned.toggle(); UserDefaults.standard.set(pinned, forKey: "tileAlwaysOnTop")
        (NSApp.delegate as? AppDelegate)?.updatePlacement()
    }
    func dismissError() { error = nil }
}
private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
private func appleQuote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

struct WidgetView: View {
    @ObservedObject var model: WidgetModel
    @State private var settings = false
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "wind").font(.system(size: 15, weight: .medium)).foregroundStyle(mint)
                Text("Breeze").font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                Text(model.temperature.map { String(format: "%.0f°", $0) } ?? "—°")
                    .font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle((model.temperature ?? 0) >= 85 ? .orange : .white)
                    .help("Максимальная температура CPU / GPU")
                    .accessibilityLabel("CPU / GPU, максимум: " + (model.temperature.map { String(format: "%.0f градусов", $0) } ?? "нет данных"))
            }
            HStack(spacing: 14) {
                ForEach(model.fans) { fan in FanGauge(fan: fan, fresh: model.fresh) }
                if model.fans.isEmpty { ProgressView().frame(maxWidth: .infinity) }
            }.frame(height: 115)
            Sparkline(values: model.history)
                .stroke(mint.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(height: 23).padding(.horizontal, 3)
                .help("История температуры за последние 45 измерений")
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Circle().fill(model.fresh ? mint : .orange).frame(width: 5, height: 5)
                Text(model.controlling ? "Вручную · \(model.remaining / 60):\(String(format: "%02d", model.remaining % 60))" : (model.manual ? "Ручной режим" : "Управляет macOS"))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 0)
                if model.busy { ProgressView().controlSize(.mini) }
                if let error = model.error {
                    Button { settings = true } label: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }.help(error)
                }
                Button { settings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Управление вентиляторами")
                    .popover(isPresented: $settings, arrowEdge: .trailing) {
                        ControlView(model: model).padding(20).frame(width: 330).preferredColorScheme(.dark)
                    }
                Menu {
                    Button(model.pinned ? "На рабочем столе" : "Поверх окон") { model.togglePin() }
                    Button("Вернуть управление macOS") { model.autoAll() }.disabled(model.fans.isEmpty || model.busy)
                    Divider()
                    Button("Закрыть Breeze", role: .destructive) { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 14)
            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
        }
        .padding(16).frame(width: 260, height: 260)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 25).fill(Color(red: 0.075, green: 0.095, blue: 0.11))
                LinearGradient(colors: [mint.opacity(0.09), .clear, .black.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .clipShape(RoundedRectangle(cornerRadius: 25))
                RoundedRectangle(cornerRadius: 25).strokeBorder(.white.opacity(0.1), lineWidth: 0.7)
            }
        }
        .preferredColorScheme(.dark)
        .onReceive(model.$fans) { _ in (NSApp.delegate as? AppDelegate)?.updateStatus() }
    }
}
struct FanGauge: View {
    let fan: Fan
    let fresh: Bool
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().trim(from: 0.12, to: 0.88).stroke(.white.opacity(0.07), style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(90))
                Circle().trim(from: 0.12, to: 0.12 + 0.76 * min(1, max(0, fan.actual / fan.maximum)))
                    .stroke(mint, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(90))
                VStack(spacing: 3) {
                    Image(systemName: "fanblades.fill").font(.system(size: 17)).foregroundStyle(mint.opacity(0.8))
                    Text(fresh ? "\(Int(fan.actual.rounded()))" : "—").font(.system(size: 21, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("об/мин").font(.system(size: 8)).foregroundStyle(.white.opacity(0.35))
                }
            }.frame(width: 92, height: 92)
            Text(fan.name).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
        }.frame(maxWidth: .infinity)
    }
}
struct Sparkline: Shape {
    var values: [Double]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let low = (values.min() ?? 0) - 3
        let high = max(low + 12, (values.max() ?? 1) + 3)
        for (i, value) in values.enumerated() {
            let point = CGPoint(x: rect.width * CGFloat(i) / CGFloat(values.count - 1), y: rect.height * CGFloat(1 - (value - low) / (high - low)))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
struct ControlView: View {
    @ObservedObject var model: WidgetModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Охлаждение").font(.title3.weight(.semibold)); Spacer(); Text("15 мин").font(.caption).foregroundStyle(.secondary) }
            ForEach(model.fans) { fan in FanControlRow(model: model, fan: fan) }
            Button { model.autoAll() } label: { Label("Вернуть всё в авто", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity) }
                .controlSize(.large).disabled(model.busy || !model.fresh)
            Text(model.error ?? model.message).font(.caption).foregroundStyle(model.error == nil ? Color.secondary : Color.orange).fixedSize(horizontal: false, vertical: true)
            Text("Ручной режим действует до 15 минут. При закрытии виджета, потере связи или от 90 °C помощник возвращает управление macOS.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
struct FanControlRow: View {
    @ObservedObject var model: WidgetModel
    let fan: Fan
    @State private var rpm = 2400.0
    private var minimum: Double { max(1200, fan.minimum) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(fan.name).font(.subheadline.weight(.medium)); Spacer(); Text(fan.mode == 1 ? "Вручную" : "macOS").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text("\(Int(rpm))").font(.system(.title3, design: .rounded).weight(.medium)).monospacedDigit()
                Text("об/мин").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Макс.") { rpm = fan.maximum }.font(.caption)
            }
            Slider(value: $rpm, in: minimum...max(minimum + 1, fan.maximum), step: 50).tint(mint)
            HStack {
                Text("\(Int(minimum))").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(fan.maximum))").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button("Авто") { model.apply([String(fan.id): -1]) }
                Spacer()
                Button("Применить") { model.apply([String(fan.id): min(fan.maximum, max(minimum, rpm))]) }.buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black)
            }.disabled(model.busy || !model.fresh)
        }.padding(13).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .onAppear { rpm = min(fan.maximum, max(minimum, fan.target > 0 ? fan.target : 2400)) }
    }
}

@MainActor final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: WidgetPanel?
    private var model: WidgetModel!
    private var hosting: NSHostingView<WidgetView>?
    private var status: NSStatusItem!
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = WidgetModel()
        let panel = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 260), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        // Above the wallpaper and desktop icons, below every ordinary app window.
        panel.level = model.pinned ? .floating : Self.desktopLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.title = "Breeze — плитка рабочего стола"
        let view = NSHostingView(rootView: WidgetView(model: model)); hosting = view; panel.contentView = view
        self.panel = panel
        if let screen = NSScreen.main {
            let rect = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: rect.minX + 28, y: rect.maxY - 288))
        }
        panel.setFrameAutosaveName("BreezeDesktopTile")
        _ = panel.setFrameUsingName("BreezeDesktopTile")
        // Keep the current fixed tile size when restoring an old window frame.
        panel.setContentSize(NSSize(width: 260, height: 260))
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }), let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 28, y: screen.visibleFrame.maxY - 288))
        }
        panel.orderFrontRegardless()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "fanblades", accessibilityDescription: "Breeze")
        status.button?.target = self; status.button?.action = #selector(toggleWidget)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
    }
    private static var desktopLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }
    func updatePlacement() {
        panel?.level = model.pinned ? .floating : Self.desktopLevel
    }
    func updateStatus() {
        status?.button?.toolTip = model.fans.map { "\($0.name): \(Int($0.actual)) об/мин" }.joined(separator: "\n")
    }
    @objc func toggleWidget() { if panel?.isVisible == true { panel?.orderOut(nil) } else { panel?.orderFrontRegardless() } }
    @objc func willSleep() { model.stop() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        terminating = true
        model.stop { DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
}
@main struct BreezeMain {
    static func main() {
        if CommandLine.arguments.contains("--probe") {
            do {
                let smc = try SMC()
                let fans = try smc.fans(); let temp = try smc.temperature()
                let data = try JSONSerialization.data(withJSONObject: ["fans": fans.map { ["id": $0.id, "rpm": $0.actual, "min": $0.minimum, "max": $0.maximum, "mode": $0.mode, "target": $0.target] }, "temperature": temp], options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
    }
}
