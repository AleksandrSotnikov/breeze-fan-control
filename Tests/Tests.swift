import Foundation

final class MockHardware: FanHardware {
    var data = [Fan(id: 0, actual: 1700, minimum: 1499, maximum: 4296, target: 0, mode: 3), Fan(id: 1, actual: 1800, minimum: 1499, maximum: 4744, target: 0, mode: 3)]
    var temp = 55.0
    var failTemperature = false
    var failWrite = false
    var autoFailures = 0
    var writes: [String] = []
    func fans() throws -> [Fan] { data }
    func temperature() throws -> Double { if failTemperature { throw BreezeError("sensor") }; return temp }
    func manual(_ id: Int, rpm: Double) throws {
        data[id].mode = 1; writes.append("manual \(id)")
        if failWrite { throw BreezeError("partial write") }
        data[id].target = rpm
    }
    func automatic(_ id: Int) throws {
        if autoFailures > 0 { autoFailures -= 1; throw BreezeError("retry") }
        data[id].mode = 0; writes.append("auto \(id)")
    }
}
@main struct Tests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            guard value else { fatalError("FAIL: " + label) }; checks += 1
        }
        func rejected(_ guardian: Guardian, _ req: ControlRequest, _ now: Double) -> Bool {
            do { _ = try guardian.step(req, now: now); return false } catch { try? guardian.restore(); return true }
        }
        let now = 10000.0
        func request(_ value: Double = 2400) -> ControlRequest { ControlRequest(heartbeat: now, revision: 1, issuedAt: now, targets: ["0": value], stop: false) }
        check(fw_codec_test() == 0, "SMC ABI and float / fixed-point codecs")
        do {
            let h = MockHardware(), g = Guardian(h)
            check(try g.step(request(), now: now), "accept manual")
            check(h.data[0].mode == 1 && h.data[0].target == 2400, "writes requested speed")
            check(h.data[1].mode == 3, "untouched fan preserved")
            var req = request(); req.stop = true
            check(try !g.step(req, now: now + 1), "stop session")
            check(h.data[0].mode == 0 && g.touched.isEmpty, "stop restores touched fan")
        }
        for invalid in [0.0, 1498, 4297, Double.nan, Double.infinity] {
            let h = MockHardware(), g = Guardian(h)
            check(rejected(g, request(invalid), now), "reject invalid RPM")
            check(h.writes.isEmpty, "invalid RPM does not write")
        }
        for temp in [90.0, 101, Double.nan, 0] {
            let h = MockHardware(), g = Guardian(h); h.temp = temp
            check(rejected(g, request(), now), "thermal guard")
            check(h.writes.isEmpty, "hot machine stays automatic")
        }
        do {
            let h = MockHardware(), g = Guardian(h)
            _ = try g.step(request(), now: now); h.temp = 92
            var r = request(); r.heartbeat = now + 1
            check(rejected(g, r, now + 1), "overheat during session")
            check(h.data[0].mode == 0, "overheat restores automatic")
        }
        do {
            let h = MockHardware(), g = Guardian(h)
            _ = try g.step(request(), now: now)
            var r = request(); r.heartbeat = now + 10
            check(rejected(g, r, now + 10), "sleep gap")
            check(h.data[0].mode == 0, "sleep cleanup")
        }
        do {
            let h = MockHardware(), g = Guardian(h)
            _ = try g.step(request(), now: now)
            check(rejected(g, request(), now + 9), "stale heartbeat")
            check(h.data[0].mode == 0, "watchdog cleanup")
        }
        do {
            let h = MockHardware(), g = Guardian(h)
            _ = try g.step(request(), now: now)
            var r = request(); r.heartbeat = now + 901
            check(rejected(g, r, now + 901), "lease expires even with fresh heartbeat")
            check(h.data[0].mode == 0, "lease cleanup")
        }
        do {
            let h = MockHardware(), g = Guardian(h); h.failWrite = true
            check(rejected(g, request(), now), "partial write failure")
            check(h.data[0].mode == 0 && g.touched.isEmpty, "partial write rollback")
        }
        do {
            let h = MockHardware(), g = Guardian(h)
            _ = try g.step(request(), now: now); h.failTemperature = true
            var r = request(); r.heartbeat = now + 1
            check(rejected(g, r, now + 1), "sensor loss")
            check(h.data[0].mode == 0, "sensor loss cleanup")
        }
        do {
            let h = MockHardware(), g = Guardian(h)
            _ = try g.step(request(), now: now); h.autoFailures = 2
            try g.restore()
            check(g.touched.isEmpty && h.data[0].mode == 0, "restore retries")
        }
        do {
            let h = MockHardware(), g = Guardian(h)
            _ = try g.step(request(), now: now); h.data[0].mode = 3
            var r = request(); r.heartbeat = now + 1
            check(rejected(g, r, now + 1), "firmware takeover ends session")
        }
        do {
            let h = MockHardware(), g = Guardian(h); h.temp = 99
            check(try g.step(request(-1), now: now), "explicit auto allowed when hot")
            check(h.data[0].mode == 0 && h.data[1].mode == 3, "explicit auto only touches selected fan")
        }
        print("PASS: \(checks) checks; hardware writes mocked, live hardware untouched")
    }
}
