import Foundation

/// Сериализует async-операции: каждый enqueue выполняется только после
/// завершения предыдущего. Нужен для ADBClient, потому что транспорт
/// stream-based (один TCP) — параллельные shell-команды перемешали бы
/// send/receive и порушили бы буфер.
actor RequestSerializer {
    private var lastTask: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) async throws -> T {
        let previous = lastTask
        let task = Task<T, Error> {
            _ = await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        lastTask = Task {
            _ = try? await task.value
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
