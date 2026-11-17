import Foundation
import Darwin

struct BreezeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ text: String) { message = text }
}
struct Fan: Identifiable, Codable {
    var id: Int
    var actual: Double
    var minimum: Double
    var maximum: Double
    var target: Double
    var mode: Int
    var name: String { "Вентилятор \(id + 1)" }
}
protocol FanHardware: AnyObject {
    func fans() throws -> [Fan]
    func temperature() throws -> Double
    func manual(_ id: Int, rpm: Double) throws
    func automatic(_ id: Int) throws
}
final class SMC: FanHardware {
    private var connection: UInt32 = 0
    private var temperatureKeys: [String] = []
    init() throws {
        let result = fw_open(&connection)
        guard result == 0 else { throw BreezeError("Нет доступа к AppleSMC (\(result)).") }
    }
    deinit { fw_close(connection) }
    func number(_ key: String) throws -> Double {
        var value = 0.0
        let result = fw_number(connection, key, &value)
        guard result == 0 else { throw BreezeError("SMC \(key): ошибка \(String(UInt32(bitPattern: result), radix: 16)).") }
        return value
    }
    private func write(_ key: String, _ value: Double) throws {
        let result = fw_write(connection, key, value)
        guard result == 0 else { throw BreezeError("Не удалось записать \(key) (\(String(UInt32(bitPattern: result), radix: 16))).") }
    }
    func fans() throws -> [Fan] {
        let count = try number("FNum")
        guard count >= 1, count <= 8, count.rounded() == count else { throw BreezeError("Вентиляторы не обнаружены.") }
        return try (0..<Int(count)).map { id in
            let prefix = "F\(id)"
            let actual = try number(prefix + "Ac")
            let minimum = try number(prefix + "Mn")
            let maximum = try number(prefix + "Mx")
            let mode = try number(prefix + "Md")
            let target = try number(prefix + "Tg")
            guard actual >= 0, actual <= 20000, minimum >= 0, maximum > minimum, maximum <= 20000 else {
                throw BreezeError("SMC вернул неверные пределы оборотов.")
            }
            return Fan(id: id, actual: actual, minimum: minimum, maximum: maximum, target: target, mode: Int(mode))
        }
    }
    func discoverTemperatures() throws {
        let count = try number("#KEY")
        guard count > 0, count < 20000 else { throw BreezeError("Неверный список датчиков SMC.") }
        var all: [String] = []
        for index in 0..<Int(count) {
            var key = [CChar](repeating: 0, count: 5)
            if fw_key_at(connection, UInt32(index), &key) == 0 {
                let name = String(cString: key)
                if name.hasPrefix("T"), let value = try? number(name), value > 0, value < 125 { all.append(name) }
            }
        }
        // M1 Pro/Max cluster and GPU sensors; keep every readable thermal sensor as fallback.
        let die = all.filter { $0.hasPrefix("Tp") || $0.hasPrefix("Tg") || $0.hasPrefix("TC") }
        temperatureKeys = die.isEmpty ? all : die
        guard !temperatureKeys.isEmpty else { throw BreezeError("Датчики температуры недоступны.") }
    }
    func temperature() throws -> Double {
        if temperatureKeys.isEmpty { try discoverTemperatures() }
        let values = temperatureKeys.compactMap { try? number($0) }.filter { $0 > 0 && $0 < 125 }
        guard values.count >= max(1, temperatureKeys.count / 2), let hottest = values.max() else {
            throw BreezeError("Потерян доступ к датчикам температуры.")
        }
        return hottest
    }
    func manual(_ id: Int, rpm: Double) throws {
        guard let fan = try fans().first(where: { $0.id == id }), rpm.isFinite,
              rpm >= max(1200, fan.minimum), rpm <= fan.maximum else { throw BreezeError("Обороты вне допустимого диапазона.") }
        // Stage the target before entering manual mode, avoiding a stale low target.
        try? write("F\(id)Tg", rpm) // Some firmware accepts targets only in manual mode.
        try write("F\(id)Md", 1)
        try write("F\(id)Tg", rpm)
        var verified = false
        for _ in 0..<10 {
            usleep(50_000)
            if let mode = try? number("F\(id)Md"), mode == 1,
               let target = try? number("F\(id)Tg"), abs(target - rpm) < 60 { verified = true; break }
        }
        guard verified else { throw BreezeError("SMC не подтвердил ручной режим. Управление возвращается macOS.") }
    }
    func automatic(_ id: Int) throws {
        try write("F\(id)Md", 0)
        for _ in 0..<10 {
            usleep(50_000)
            if try number("F\(id)Md") != 1 { return }
        }
        throw BreezeError("SMC не подтвердил автоматический режим вентилятора \(id + 1).")
    }
}

struct ControlRequest: Codable {
    var heartbeat: Double
    var revision: Int
    var issuedAt: Double
    var targets: [String: Double] // -1 means explicit automatic; missing means untouched.
    var stop: Bool
}
struct ControlStatus: Codable {
    var revision: Int
    var active: Bool
    var message: String
    var timestamp: Double
}
final class Guardian {
    let hardware: FanHardware
    private(set) var touched: Set<Int> = []
    private(set) var revision = -1
    private var deadline: Double = 0
    private var previousTick: Double?
    init(_ hardware: FanHardware) { self.hardware = hardware }
    // All failure paths leave ownership recorded until automatic mode is verified.
    func restore() throws {
        var errors: [String] = []
        for id in touched.sorted() {
            var success = false
            for _ in 0..<3 {
                do { try hardware.automatic(id); success = true; break } catch { errors.append(error.localizedDescription) }
            }
            if success { touched.remove(id) }
        }
        if !touched.isEmpty { throw BreezeError("Не удалось вернуть авто: " + errors.suffix(touched.count).joined(separator: "; ")) }
    }
    func step(_ request: ControlRequest, now: Double) throws -> Bool {
        if request.stop { try restore(); return false }
        guard request.heartbeat.isFinite, request.issuedAt.isFinite,
              now - request.heartbeat <= 8, now - request.heartbeat >= -2,
              now - request.issuedAt <= 900, request.issuedAt <= now + 2 else {
            throw BreezeError("Сеанс завершён: истекло время управления.")
        }
        if let previousTick, now - previousTick > 5 { throw BreezeError("Сеанс завершён после сна или паузы.") }
        previousTick = now
        let fans = try hardware.fans()
        guard request.targets.count <= fans.count else { throw BreezeError("Неверная команда.") }
        for (key, value) in request.targets {
            guard let id = Int(key), key == String(id), let fan = fans.first(where: { $0.id == id }), value.isFinite,
                  value == -1 || (value >= max(1200, fan.minimum) && value <= fan.maximum) else {
                throw BreezeError("Недопустимая скорость вентилятора.")
            }
        }
        let changed = request.revision != revision
        if request.targets.values.contains(where: { $0 >= 0 }) {
            let temperature = try hardware.temperature()
            guard temperature.isFinite, temperature > 0, temperature < 90 else {
                throw BreezeError("Температура достигла 90 °C или датчик недоступен. Управление возвращается macOS.")
            }
        }
        if changed {
            deadline = min(request.issuedAt + 900, now + 900)
            for (key, rpm) in request.targets.sorted(by: { $0.key < $1.key }) {
                let id = Int(key)!
                touched.insert(id) // Before any write, so partial failure is restored too.
                if rpm == -1 { try hardware.automatic(id); touched.remove(id) }
                else { try hardware.manual(id, rpm: rpm) }
            }
            revision = request.revision
        }
        guard now < deadline else { throw BreezeError("15 минут истекли. Управление возвращается macOS.") }
        // Unexpected firmware takeover is treated as a reason to stop, never fought.
        for id in touched {
            guard let fan = fans.first(where: { $0.id == id }) else { throw BreezeError("Потеряна связь с вентилятором.") }
            if !changed, fan.mode != 1 || abs(fan.target - (request.targets[String(id)] ?? fan.target)) > 100 { throw BreezeError("Режим SMC изменился.") }
        }
        return true
    }
}
