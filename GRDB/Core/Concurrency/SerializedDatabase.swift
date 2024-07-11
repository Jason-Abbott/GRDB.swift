import Foundation

/// A class that serializes accesses to an SQLite connection.
final class SerializedDatabase {
    /// The database connection
    private let db: Database
    
    /// The database configuration
    var configuration: Configuration { db.configuration }
    
    /// The path to the database file
    let path: String
    
    /// The dispatch queue
    private let queue: DispatchQueue
    
    /// If true, overrides `configuration.allowsUnsafeTransactions`.
    private var allowsUnsafeTransactions = false
    
    init(
        path: String,
        configuration: Configuration = Configuration(),
        defaultLabel: String,
        purpose: String? = nil)
    throws
    {
        // According to https://www.sqlite.org/threadsafe.html
        //
        // > SQLite support three different threading modes:
        // >
        // > 1. Multi-thread. In this mode, SQLite can be safely used by
        // >    multiple threads provided that no single database connection is
        // >    used simultaneously in two or more threads.
        // >
        // > 2. Serialized. In serialized mode, SQLite can be safely used by
        // >    multiple threads with no restriction.
        // >
        // > [...]
        // >
        // > The default mode is serialized.
        //
        // Since our database connection is only used via our serial dispatch
        // queue, there is no purpose using the default serialized mode.
        var config = configuration
        config.threadingMode = .multiThread
        
        self.path = path
        let identifier = configuration.identifier(defaultLabel: defaultLabel, purpose: purpose)
        self.db = try Database(
            path: path,
            description: identifier,
            configuration: config)
        if config.readonly {
            self.queue = configuration.makeReaderDispatchQueue(label: identifier)
        } else {
            self.queue = configuration.makeWriterDispatchQueue(label: identifier)
        }
        SchedulingWatchdog.allowDatabase(db, onQueue: queue)
        try queue.sync {
            do {
                try db.setUp()
            } catch {
                // Recent versions of the Swift compiler will call the
                // deinitializer. Older ones won't.
                // See https://bugs.swift.org/browse/SR-13746 for details.
                //
                // So let's close the database now. The deinitializer
                // will only close the database if needed.
                db.close_v2()
                throw error
            }
        }
    }
    
    deinit {
        // Database may be deallocated in its own queue: allow reentrancy
        reentrantSync { db in
            db.close_v2()
        }
    }
    
    /// Executes database operations, returns their result after they have
    /// finished executing, and allows or forbids long-lived transactions.
    ///
    /// This method is not reentrant.
    ///
    /// - parameter allowingLongLivedTransaction: When true, the
    ///   ``Configuration/allowsUnsafeTransactions`` configuration flag is
    ///   ignored until this method is called again with false.
    func sync<T>(allowingLongLivedTransaction: Bool, _ body: (Database) throws -> T) rethrows -> T {
        try sync { db in
            self.allowsUnsafeTransactions = allowingLongLivedTransaction
            return try body(db)
        }
    }
    
    /// Executes database operations, and returns their result after they
    /// have finished executing.
    ///
    /// This method is not reentrant.
    func sync<T>(_ block: (Database) throws -> T) rethrows -> T {
        // Three different cases:
        //
        // 1. A database is invoked from some queue like the main queue:
        //
        //      serializedDatabase.sync { db in       // <-- we're here
        //      }
        //
        // 2. A database is invoked in a reentrant way:
        //
        //      serializedDatabase.sync { db in
        //          serializedDatabase.sync { db in   // <-- we're here
        //          }
        //      }
        //
        // 3. A database in invoked from another database:
        //
        //      serializedDatabase1.sync { db1 in
        //          serializedDatabase2.sync { db2 in // <-- we're here
        //          }
        //      }
        
        guard let watchdog = SchedulingWatchdog.current else {
            // Case 1
            return try queue.sync {
                defer { preconditionNoUnsafeTransactionLeft(db) }
                return try block(db)
            }
        }
        
        // Case 2 is forbidden.
        GRDBPrecondition(!watchdog.allows(db), "Database methods are not reentrant.")
        
        // Case 3
        return try queue.sync {
            try SchedulingWatchdog.current!.inheritingAllowedDatabases(from: watchdog) {
                defer { preconditionNoUnsafeTransactionLeft(db) }
                return try block(db)
            }
        }
    }
    
    /// Executes database operations, returns their result after they have
    /// finished executing, and allows or forbids long-lived transactions.
    ///
    /// This method is reentrant.
    ///
    /// - parameter allowingLongLivedTransaction: When true, the
    ///   ``Configuration/allowsUnsafeTransactions`` configuration flag is
    ///   ignored until this method is called again with false.
    func reentrantSync<T>(allowingLongLivedTransaction: Bool, _ body: (Database) throws -> T) rethrows -> T {
        try reentrantSync { db in
            self.allowsUnsafeTransactions = allowingLongLivedTransaction
            return try body(db)
        }
    }
    
    /// Executes database operations, and returns their result after they
    /// have finished executing.
    ///
    /// This method is reentrant.
    func reentrantSync<T>(_ block: (Database) throws -> T) rethrows -> T {
        // Three different cases:
        //
        // 1. A database is invoked from some queue like the main queue:
        //
        //      serializedDatabase.reentrantSync { db in       // <-- we're here
        //      }
        //
        // 2. A database is invoked in a reentrant way:
        //
        //      serializedDatabase.reentrantSync { db in
        //          serializedDatabase.reentrantSync { db in   // <-- we're here
        //          }
        //      }
        //
        // 3. A database in invoked from another database:
        //
        //      serializedDatabase1.reentrantSync { db1 in
        //          serializedDatabase2.reentrantSync { db2 in // <-- we're here
        //          }
        //      }
        
        guard let watchdog = SchedulingWatchdog.current else {
            // Case 1
            return try queue.sync {
                // Since we are reentrant, a transaction may already be opened.
                // In this case, don't check for unsafe transaction at the end.
                if db.isInsideTransaction {
                    return try block(db)
                } else {
                    defer { preconditionNoUnsafeTransactionLeft(db) }
                    return try block(db)
                }
            }
        }
        
        // Case 2
        if watchdog.allows(db) {
            // Since we are reentrant, a transaction may already be opened.
            // In this case, don't check for unsafe transaction at the end.
            if db.isInsideTransaction {
                return try block(db)
            } else {
                defer { preconditionNoUnsafeTransactionLeft(db) }
                return try block(db)
            }
        }
        
        // Case 3
        return try queue.sync {
            try SchedulingWatchdog.current!.inheritingAllowedDatabases(from: watchdog) {
                // Since we are reentrant, a transaction may already be opened.
                // In this case, don't check for unsafe transaction at the end.
                if db.isInsideTransaction {
                    return try block(db)
                } else {
                    defer { preconditionNoUnsafeTransactionLeft(db) }
                    return try block(db)
                }
            }
        }
    }
    
    /// Schedules database operations for execution, and returns immediately.
    func async(
        _ block: sending @escaping (Database) -> Void
    ) {
        // DispatchQueue does not accept a sending closure yet, as
        // discussed at <https://forums.swift.org/t/how-can-i-use-region-based-isolation/71426/5>.
        // So let's wrap the closure in a Sendable wrapper.
        let block = UncheckedSendableWrapper(value: block)
        
        queue.async {
            block.value(self.db)
            self.preconditionNoUnsafeTransactionLeft(self.db)
        }
    }
    
    /// Returns true if any only if the current dispatch queue is valid.
    var onValidQueue: Bool {
        SchedulingWatchdog.current?.allows(db) ?? false
    }
    
    /// Executes the block in the current queue.
    ///
    /// - precondition: the current dispatch queue is valid.
    func execute<T>(_ block: (Database) throws -> T) rethrows -> T {
        preconditionValidQueue()
        return try block(db)
    }
    
    /// Asynchrously executes the block.
    @available(iOS 13, macOS 10.15, tvOS 13, *)
    func execute<T>(
        _ block: sending @escaping (Database) throws -> sending T
    ) async throws -> sending T {
        // Prevent compiler warning with an unchecked Sendable wrapper, due
        // to <https://github.com/apple/swift/issues/73315>.
        // FIXME: remove the closure copy when <https://github.com/apple/swift/issues/74457> is fixed.
        let block: (Database) throws -> T = block
        let blockWrapper = UncheckedSendableWrapper(value: block)
        
        let dbAccess = CancellableDatabaseAccess()
        return try await dbAccess.withCancellableContinuation { continuation in
            self.async { db in
                do {
                    let result = try dbAccess.inDatabase(db) {
                        try blockWrapper.value(db)
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func interrupt() {
        // Intentionally not scheduled in our serial queue
        db.interrupt()
    }
    
    func suspend() {
        // Intentionally not scheduled in our serial queue
        db.suspend()
    }
    
    func resume() {
        // Intentionally not scheduled in our serial queue
        db.resume()
    }
    
    /// Fatal error if current dispatch queue is not valid.
    func preconditionValidQueue(
        _ message: @autoclosure() -> String = "Database was not used on the correct thread.",
        file: StaticString = #file,
        line: UInt = #line)
    {
        SchedulingWatchdog.preconditionValidQueue(db, message(), file: file, line: line)
    }
    
    /// Fatal error if a transaction has been left opened.
    private func preconditionNoUnsafeTransactionLeft(
        _ db: Database,
        _ message: @autoclosure() -> String = "A transaction has been left opened at the end of a database access",
        file: StaticString = #file,
        line: UInt = #line)
    {
        GRDBPrecondition(
            allowsUnsafeTransactions || configuration.allowsUnsafeTransactions || !db.isInsideTransaction,
            message(),
            file: file,
            line: line)
    }
}

// @unchecked because the wrapped `Database` itself is not Sendable.
// It happens the job of SerializedDatabase is precisely to provide thread-safe
// access to `Database`.
extension SerializedDatabase: @unchecked Sendable { }

// MARK: - Task Cancellation Support

@available(iOS 13, macOS 10.15, tvOS 13, *)
enum DatabaseAccessCancellationState: @unchecked Sendable {
    // @unchecked Sendable because database is only accessed from its
    // dispatch queue.
    case notConnected
    case connected(Database)
    case cancelled
    case expired
}

@available(iOS 13, macOS 10.15, tvOS 13, *)
typealias CancellableDatabaseAccess = Mutex<DatabaseAccessCancellationState>

/// Supports Task cancellation in async database accesses.
///
/// Usage:
///
/// ```swift
/// let dbAccess = CancellableDatabaseAccess()
/// return try dbAccess.withCancellableContinuation { continuation in
///     asyncDatabaseAccess { db in
///         do {
///             let result = try dbAccess.inDatabase(db) {
///                 // Perform database operations
///             }
///             continuation.resume(returning: result)
///         } catch {
///             continuation.resume(throwing: error)
///         }
///     }
/// }
/// ```
@available(iOS 13, macOS 10.15, tvOS 13, *)
extension CancellableDatabaseAccess: DatabaseCancellable {
    convenience init() {
        self.init(.notConnected)
    }
    
    func cancel() {
        withLock { state in
            switch state {
            case let .connected(db):
                db.cancel()
                state = .cancelled
            case .notConnected:
                state = .cancelled
            case .cancelled, .expired:
                break
            }
        }
    }
    
    func withCancellableContinuation<Value>(
        _ fn: (UnsafeContinuation<Value, any Error>) -> Void
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            try checkCancellation()
            return try await withUnsafeThrowingContinuation { continuation in
                fn(continuation)
            }
        } onCancel: {
            cancel()
        }
    }
    
    func checkCancellation() throws {
        try withLock { state in
            if case .cancelled = state {
                throw CancellationError()
            }
        }
    }
    
    /// Wraps a full database access with cancellation support. When this
    /// method returns, the database is NOT cancelled.
    func inDatabase<Value>(_ db: Database, _ work: () throws -> Value) throws -> Value {
        try withLock { state in
            switch state {
            case .connected, .expired:
                fatalError("Can't use a CancellableDatabaseAccess twice")
            case .notConnected:
                state = .connected(db)
            case .cancelled:
                throw CancellationError()
            }
        }
        
        defer {
            withLock { state in
                if case .cancelled = state {
                    db.uncancel()
                }
                state = .expired
            }
        }
        
        return try work()
    }
}
