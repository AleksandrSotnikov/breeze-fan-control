import Foundation
import Darwin

private func checkedFile(_ directory: Int32, _ name: String, _ flags: Int32, _ owner: uid_t) throws -> Int32 {
    let fd = openat(directory, name, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw BreezeError("Не удалось открыть файл сеанса.") }
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == owner,
          st.st_nlink == 1, st.st_size <= 16384 else { close(fd); throw BreezeError("Неверный файл сеанса.") }
    return fd
}
private func readRequest(_ directory: Int32, _ owner: uid_t) throws -> ControlRequest {
    let fd = try checkedFile(directory, "request.json", O_RDONLY, owner)
    defer { close(fd) }
    var buffer = [UInt8](repeating: 0, count: 16385)
    let count = read(fd, &buffer, buffer.count)
    guard count > 0, count <= 16384 else { throw BreezeError("Нет команды от виджета.") }
    return try JSONDecoder().decode(ControlRequest.self, from: Data(buffer.prefix(count)))
}
private func publish(_ status: ControlStatus, to fd: Int32) {
    guard let data = try? JSONEncoder().encode(status) else { return }
    _ = lseek(fd, 0, SEEK_SET)
    data.withUnsafeBytes { bytes in
        if let base = bytes.baseAddress { _ = write(fd, base, bytes.count) }
    }
    _ = ftruncate(fd, off_t(data.count))
}
@main struct HelperMain {
    static func main() {
        do { try run() } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
    }
    static func run() throws {
        let args = CommandLine.arguments
        guard geteuid() == 0, args.count == 5, args[1] == "--session",
              let uid = uid_t(args[3]), uid > 0, let pid = pid_t(args[4]), pid > 1 else {
            throw BreezeError("BreezeHelper запускается виджетом с правами администратора.")
        }
        let lock = open("/var/run/breeze.guardian.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw BreezeError("Другой сеанс Breeze уже управляет вентиляторами.") }
        defer { close(lock) }
        let directory = open(args[2], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw BreezeError("Папка сеанса недоступна.") }
        defer { close(directory) }
        var st = stat()
        guard fstat(directory, &st) == 0, st.st_uid == uid, st.st_mode & 0o077 == 0 else {
            throw BreezeError("Неверные права папки сеанса.")
        }
        let statusFD = try checkedFile(directory, "status.json", O_WRONLY, uid)
        defer { close(statusFD) }
        fw_signals_install()
        let smc = try SMC()
        let guardian = Guardian(smc)
        var ending = "Управление возвращено macOS."
        do {
            while true {
                guard fw_stopping() == 0 else { throw BreezeError("Помощник остановлен. Управление возвращено macOS.") }
                guard kill(pid, 0) == 0 else { throw BreezeError("Виджет закрыт. Управление возвращено macOS.") }
                let request = try readRequest(directory, uid)
                let now = Date().timeIntervalSince1970
                if try !guardian.step(request, now: now) { break }
                publish(ControlStatus(revision: guardian.revision, active: true, message: "Настройки применены", timestamp: now), to: statusFD)
                usleep(500_000)
            }
        } catch { ending = error.localizedDescription }
        // Keep ownership and keep retrying through transient SMC errors / wake.
        while true {
            do { try guardian.restore(); break }
            catch {
                publish(ControlStatus(revision: guardian.revision, active: true, message: "Возврат к macOS: " + error.localizedDescription, timestamp: Date().timeIntervalSince1970), to: statusFD)
                sleep(2)
            }
        }
        publish(ControlStatus(revision: guardian.revision, active: false, message: ending, timestamp: Date().timeIntervalSince1970), to: statusFD)
    }
}
