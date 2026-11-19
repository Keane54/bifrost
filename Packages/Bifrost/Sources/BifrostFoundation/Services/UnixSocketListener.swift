import Darwin
import Foundation
import Network
import Synchronization

// MARK: - The errors of a listen

// Why a listener does not listen, or why it stopped. message is the text of the Live details
// status and of the log lines.
package enum ListenError: MessageError, Equatable, Sendable {
    // The socket path has more bytes than the address of a Unix socket holds.
    case pathTooLong(String)
    // A file that is not a socket has the path. Bifrost never changes it.
    case notASocket(String)
    // Another program listens on the path. Bifrost never takes its socket.
    case inUse(String)
    // The socket at the path did not answer the probe in time.
    case noAnswer(String)
    // The folder of the socket is a link, or another user owns it.
    case unsafeFolder(String)
    // The access list of the folder of the socket can let another user in, or Bifrost cannot read
    // it.
    case openAccessList(String)
    // After the listen, the file at the socket path is not a socket of this user with mode 0600.
    case unsafeSocket(String)
    // The path of the lock file has a file that is not a regular file of this user with one link.
    // Bifrost never changes it.
    case notALockFile(String)
    // A call of the system on the path failed with this error number.
    case system(SystemCall, path: String, code: Int32)
    // Another error of the listen, with its text.
    case failed(String)
    // The listener started before (it listens, it listened, or a close ended it). A listener
    // starts one time at most.
    case startedBefore(String)
    // A close ended the listen before it was ready.
    case closedBeforeListen(String)

    package var message: String {
        switch self {
        case .pathTooLong(let path): "The socket path is too long: \(path)"
        case .notASocket(let path): "\(path) exists and is not a socket. Bifrost did not change it."
        case .inUse(let path): "Another program listens on \(path)."
        case .noAnswer(let path):
            "The socket \(path) did not answer in \(SocketProbe.connectLimitText)."
        case .unsafeFolder(let folder):
            "Bifrost doesn't listen in \(folder), because it's a link or another user owns it."
        case .openAccessList(let folder):
            "Bifrost doesn't listen in \(folder), because its access list can let other users in."
        case .unsafeSocket(let path):
            "The socket \(path) is not a socket of this user with mode 0600. Bifrost closed it."
        case .notALockFile(let path):
            "\(path) is not a regular file of this user with one link. Bifrost did not change it."
        case .system(let call, let path, let code): ErrorText.system(code, call: call, path: path)
        case .failed(let text): text
        case .startedBefore(let path): "The listener of \(path) started before."
        case .closedBeforeListen(let path): "The listener of \(path) closed before the listen."
        }
    }

    // The error of the listen of the system on the path: the native form of a POSIX error, else
    // the text of the error (ErrorText).
    package static func listen(_ error: any Error, path: String) -> ListenError {
        if let failure = error as? ListenError { return failure }
        guard let code = ErrorText.posixCode(of: error) else {
            return .failed(error.localizedDescription)
        }
        return .system(.listen, path: path, code: code)
    }
}

// MARK: - The listener

// One listener on a Unix socket: the socket of the Live details server and of the debug test
// port. It wraps NWListener of Network. (NetworkListener of macOS 26 also listens on a Unix path,
// but the end of its run comes before it closes its socket, and it does not always report the
// end of its cancel. So a close during the listen cannot know when it may remove the socket file
// of that listen.)
//
// - listen(handle:) prepares the path: it makes the folder of the socket and each missing parent
//   with mode 0700. It opens the folder with no follow of a link, refuses a folder that is a link,
//   that another user owns or whose access list allows another user, and sets the mode 0700 on
//   the open folder. With a lock path, it then takes the lock of the lock file in that folder
//   (flock, no wait): only the holder of the lock probes, removes a stale socket and listens, so
//   two apps never race for the path. A lock that another process holds gives inUse. Then it
//   probes the path (SocketProbe) and removes a stale socket. It never takes the socket of
//   another program, and it never removes a file that is not a socket. Then it listens. At the
//   ready state it sets the mode 0600 on the socket file with no follow of a link, and checks the
//   file: a socket of this user with mode 0600, else the listen fails. It gives its result when
//   the check passed, so only the user may connect. It keeps the device and the inode of the
//   socket file.
// - Network gives no descriptor of a connection, so the listener cannot check the user of the
//   peer. The folder check, the folder mode 0700 and the socket mode 0600 keep other users out.
//   The check is only as safe as the parent of the folder: a user who can write in that parent
//   can replace the folder between the check and the listen. The parents of the socket paths of
//   the app are the home folder of the user and the test home.
// - Each connection runs handle in its own task, off the main actor. The listener keeps at most
//   maxConnections connections, and it closes a new connection over the limit at once. Each
//   connection has the request time limit: at that limit the connection closes, also when an
//   answer does not end. The connection closes when handle returns.
// - close() closes the listener and each connection. A listener that listened removes its
//   socket file, but only when the file at the path still has the device and the inode of its
//   socket, so it never removes the socket of another program. close() tells the owner whether
//   the listener listened. A close during the listen ends the listen when the cancel of the
//   NWListener is complete. That cancel can still leave the socket file of this listen, so the
//   listener then removes a stale socket file at the path. A socket of another program stays.
// - The listener holds the lock from before the probe until the removal of its socket file at
//   the close, or until the end of a listen that failed. The end of the process also frees it.
// - refused gets a call for each connection that the listener closes at once (the limit of open
//   connections, or a connection after the close), on the queue of the listener.
// - stopped() gives the end of a listener that listened: nil after a close, or the error of a
//   failure. A listener that failed takes no more connections.
// The NWListener reports its states on its own queue. One stream takes them in their order to one
// task on the main actor, so the state of the listener changes only there. That task ends at the
// stop of the listener.
@MainActor
package final class UnixSocketListener {
    package struct Limits: Sendable {
        var maxConnections: Int
        var requestTimeout: Duration

        package init(maxConnections: Int, requestTimeout: Duration) {
            self.maxConnections = maxConnections
            self.requestTimeout = requestTimeout
        }
    }

    // The work of one connection.
    package typealias Handler = @Sendable (UnixSocketConnection) async -> Void

    // A step of a listen between the bind and the ready state: the socket file exists, and the
    // listener does not listen yet. Only a test gives one. It holds a listen at that point, so a
    // close comes there on each run.
    package typealias BoundStep = @MainActor () async -> Void

    private enum Phase {
        case waiting
        case preparing
        // The NWListener runs and is not ready yet. closing is true after a close.
        case starting(NWListener, closing: Bool)
        case listening(NWListener)
        case stopped(ListenError?)
    }

    package let socketPath: String
    private let lockPath: String?
    private let limits: Limits
    private let clock: any Clock<Duration>
    private var phase = Phase.waiting
    // True from the ready state until close() gives it: the listen made the socket file.
    private var listened = false
    // The open lock file whose lock the listener holds, or nil.
    private var lockFile: Int32?
    // The device and the inode of the socket file of the listen, from the ready state.
    private var socketFile: (device: dev_t, inode: ino_t)?
    // The listen that waits for its result, and the calls that wait for the end.
    private var ready: CheckedContinuation<ListenError?, Never>?
    private var ends: [CheckedContinuation<ListenError?, Never>] = []
    private let gate: ConnectionGate
    // The queue of the NWListener and of its connections.
    private let queue = DispatchQueue(label: "bifrost.socket")
    // The states of the NWListener, and the task that gives them to stateChanged.
    private var reports: AsyncStream<NWListener.State>.Continuation?
    private var follow: Task<Void, Never>?
    private let boundStep: BoundStep?

    // lockPath: the lock file of the socket, in the folder of the socket, or nil for no lock.
    package init(
        socketPath: String, lockPath: String? = nil, limits: Limits, clock: any Clock<Duration>,
        refused: @escaping @Sendable () -> Void = {}, boundStep: BoundStep? = nil
    ) {
        self.socketPath = socketPath
        self.lockPath = lockPath
        self.limits = limits
        self.clock = clock
        self.boundStep = boundStep
        gate = ConnectionGate(limit: limits.maxConnections, refused: refused)
    }

    // Prepare the path and listen. The call ends when the listener listens and the socket file
    // has mode 0600, else it throws the reason. A listener listens one time at most, also after
    // a close.
    package func listen(handle: @escaping Handler) async throws(ListenError) {
        guard case .waiting = phase else { throw .startedBefore(socketPath) }
        phase = .preparing
        do {
            lockFile = try await Self.prepare(socketPath, lockPath: lockPath)
        } catch {
            if case .preparing = phase { stop(error) }
            throw error
        }
        guard case .preparing = phase else {
            releaseLock()
            throw .closedBeforeListen(socketPath)
        }
        // The bind of the listener follows a link at the path, so the path must still be free
        // just before the listener starts. Only a process of this user can put a file there now.
        if let failure = Self.checkFree(socketPath) {
            stop(failure)
            releaseLock()
            throw failure
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socketPath)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            let failure = ListenError.listen(error, path: socketPath)
            stop(failure)
            releaseLock()
            throw failure
        }
        let (states, reports) = AsyncStream.makeStream(of: NWListener.State.self)
        self.reports = reports
        listener.stateUpdateHandler = { reports.yield($0) }
        follow = Task { [weak self, boundStep] in
            for await state in states {
                if case .ready = state, let boundStep { await boundStep() }
                guard let self else { return }
                stateChanged(state)
            }
        }
        listener.newConnectionHandler = Self.accept(
            gate: gate, queue: queue, limit: limits.requestTimeout, clock: clock, handle: handle)
        phase = .starting(listener, closing: false)
        listener.start(queue: queue)
        let error = await withCheckedContinuation { ready = $0 }
        if let error { throw error }
    }

    // The end of a listener that listened: nil after a close, or the error of a failure. It
    // waits until the end.
    package func stopped() async -> ListenError? {
        if case .stopped(let error) = phase { return error }
        return await withCheckedContinuation { ends.append($0) }
    }

    // Close the listener and each connection. The result is true when the listener listened:
    // then its listen made the socket file, and the owner can remove it. A listen that waits
    // gets its reason when the cancel of the NWListener is complete. A close does not remove
    // the file.
    @discardableResult
    package func close() -> Bool {
        let made = listened
        listened = false
        switch phase {
        case .waiting, .preparing:
            stop(nil)
        case .starting(let listener, _):
            phase = .starting(listener, closing: true)
            listener.cancel()
        case .listening(let listener):
            gate.shut()
            listener.cancel()
            stop(nil)
        case .stopped:
            break
        }
        if made {
            removeSocketFile()
            releaseLock()
        }
        return made
    }

    // Remove the socket file of the listen: only a file with the device and the inode of the
    // socket of the listen. A file that another program put at the path stays.
    private func removeSocketFile() {
        guard let made = socketFile else { return }
        socketFile = nil
        var info = stat()
        guard lstat(socketPath, &info) == 0, info.st_dev == made.device,
            info.st_ino == made.inode
        else { return }
        unlink(socketPath)
    }

    // Free the lock of the lock file. A second call does nothing.
    private func releaseLock() {
        guard let lockFile else { return }
        self.lockFile = nil
        Darwin.close(lockFile)
    }

    // MARK: - The life of the listener

    private func stateChanged(_ state: NWListener.State) {
        switch (phase, state) {
        case (.starting(let listener, false), .ready):
            // The socket file starts with mode 0755. Only the user may connect. The mode, the
            // check and the phase change in the same turn, so a close sees all or none.
            if let failure = secureSocketFile() {
                listener.cancel()
                finishListen(failure)
                return
            }
            phase = .listening(listener)
            listened = true
            gate.open()
            ready?.resume(returning: nil)
            ready = nil
        case (.starting(let listener, false), .failed(let error)),
            (.starting(let listener, false), .waiting(let error)):
            // The listen did not make the socket file, so the file is not removed.
            listener.cancel()
            finishListen(.listen(error, path: socketPath))
        case (.starting(_, true), .cancelled):
            // A close ended the listen. At .cancelled the NWListener changes no file any more, but
            // a socket file of that listen can be at the path now. Remove a stale socket, then
            // give the listen its reason.
            stop(nil)
            Task { [socketPath] in
                await SocketProbe.removeStaleSocket(socketPath)
                self.finishListen(.closedBeforeListen(socketPath))
            }
        case (_, .cancelled):
            reports?.finish()
        case (.listening(let listener), .failed(let error)),
            (.listening(let listener), .waiting(let error)):
            gate.shut()
            listener.cancel()
            stop(.listen(error, path: socketPath))
        default:
            break
        }
    }

    // Set the mode 0600 on the socket file with no follow of a link, then check the file: a
    // socket of this user with mode 0600. Keep its device and its inode. On a failure, remove a
    // socket of this user at the path (the lock holder made it) and give the reason.
    private func secureSocketFile() -> ListenError? {
        var failure: ListenError?
        if fchmodat(AT_FDCWD, socketPath, 0o600, AT_SYMLINK_NOFOLLOW) != 0 {
            failure = .system(.setPermissions, path: socketPath, code: errno)
        }
        var info = stat()
        guard lstat(socketPath, &info) == 0 else {
            return failure ?? .system(.check, path: socketPath, code: errno)
        }
        let ownSocket = info.st_mode & S_IFMT == S_IFSOCK && info.st_uid == getuid()
        if failure == nil, ownSocket, info.st_mode & 0o777 == 0o600 {
            socketFile = (info.st_dev, info.st_ino)
            return nil
        }
        // The cancel does not remove the file, and this listen made a socket of this user.
        if ownSocket { unlink(socketPath) }
        return failure ?? .unsafeSocket(socketPath)
    }

    // Give the listen that waits its reason, stop and free the lock.
    private func finishListen(_ error: ListenError) {
        if case .starting = phase { stop(error) }
        releaseLock()
        ready?.resume(returning: error)
        ready = nil
    }

    // The end of the listener: no more states go to stateChanged, and each call of stopped()
    // gets the error.
    private func stop(_ error: ListenError?) {
        phase = .stopped(error)
        reports?.finish()
        reports = nil
        for end in ends { end.resume(returning: error) }
        ends = []
    }

    // MARK: - The steps off the main actor

    // The folder of the socket with mode 0700, the folder check, the lock, the probe, and the
    // removal of a stale socket. The result is the open lock file whose lock the caller holds now,
    // or nil with no lock path. A failure frees the lock.
    @concurrent private static func prepare(
        _ socketPath: String, lockPath: String?
    ) async throws(ListenError) -> Int32? {
        let parent = (socketPath as NSString).deletingLastPathComponent
        let folder = parent.isEmpty ? "." : parent
        // The text has the path of the folder, also when a parent fails.
        if let code = makeFolder(folder) { throw .system(.createFolder, path: folder, code: code) }
        let lockFile = try checkFolderAndLock(folder, lockPath: lockPath, socketPath: socketPath)
        do throws(ListenError) {
            switch await SocketProbe.probe(socketPath) {
            case .free:
                break
            case .refused(let reason):
                throw reason
            case .stale:
                if unlink(socketPath) != 0 {
                    let code = errno
                    if code != ENOENT { throw .system(.remove, path: socketPath, code: code) }
                }
            }
        } catch {
            if let lockFile { Darwin.close(lockFile) }
            throw error
        }
        return lockFile
    }

    // Open the folder with no follow of a link, check it on the descriptor and set its mode 0700:
    // a folder of this user whose access list allows no other user. The open reads only the last
    // part of the path with no follow, so this check is as safe as the parent of the folder (see
    // the type comment). Then open the lock file in that folder (no follow, no inherit by a
    // child) and take its lock with no wait. The result is the open lock file, or nil with no
    // lock path.
    nonisolated private static func checkFolderAndLock(
        _ folder: String, lockPath: String?, socketPath: String
    ) throws(ListenError) -> Int32? {
        let fd = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            let code = errno
            // ELOOP: the last part of the path is a link. ENOTDIR: it is not a folder.
            if code == ELOOP || code == ENOTDIR { throw .unsafeFolder(folder) }
            throw .system(.check, path: folder, code: code)
        }
        defer { Darwin.close(fd) }
        var info = stat()
        if fstat(fd, &info) != 0 { throw .system(.check, path: folder, code: errno) }
        if info.st_mode & S_IFMT != S_IFDIR || info.st_uid != getuid() {
            throw .unsafeFolder(folder)
        }
        if allowsOthers(fd) { throw .openAccessList(folder) }
        if fchmod(fd, 0o700) != 0 { throw .system(.setPermissions, path: folder, code: errno) }
        guard let lockPath else { return nil }
        let name = (lockPath as NSString).lastPathComponent
        let lockFile = openat(fd, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if lockFile < 0 {
            let code = errno
            if code == ELOOP { throw .notALockFile(lockPath) }
            throw .system(.lock, path: lockPath, code: code)
        }
        // The lock file must be a regular file of this user with one link, so the lock is never
        // the lock of another file.
        var lockInfo = stat()
        if fstat(lockFile, &lockInfo) != 0 || lockInfo.st_mode & S_IFMT != S_IFREG
            || lockInfo.st_uid != getuid() || lockInfo.st_nlink != 1
        {
            Darwin.close(lockFile)
            throw .notALockFile(lockPath)
        }
        if flock(lockFile, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            Darwin.close(lockFile)
            // Another process holds the lock: another app listens, or starts to listen.
            if code == EWOULDBLOCK { throw .inUse(socketPath) }
            throw .system(.lock, path: lockPath, code: code)
        }
        return lockFile
    }

    // True when the extended access list of the open folder has an entry that allows, or when
    // the read of the list fails for another reason than "no list" (ENOENT). An allow entry can
    // let another user into the folder, also with the mode 0700. A deny entry is safe.
    nonisolated private static func allowsOthers(_ fd: Int32) -> Bool {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno != ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, Int32(which), &entry) == 0 {
            var tag = ACL_UNDEFINED_TAG
            if let entry, acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_ALLOW {
                return true
            }
            which = ACL_NEXT_ENTRY.rawValue
        }
        return false
    }

    // nil when no file is at the path, else the reason: a socket is inUse, another file is
    // notASocket.
    nonisolated private static func checkFree(_ path: String) -> ListenError? {
        var info = stat()
        if lstat(path, &info) != 0 {
            let code = errno
            return code == ENOENT ? nil : .system(.check, path: path, code: code)
        }
        return info.st_mode & S_IFMT == S_IFSOCK ? .inUse(path) : .notASocket(path)
    }

    // Make the folder and each missing parent with mode 0700, as mkdir -p does. The result is
    // nil, or the error number. A file at the path gives EEXIST. A path through a file gives
    // ENOTDIR.
    nonisolated private static func makeFolder(_ folder: String) -> Int32? {
        if mkdir(folder, 0o700) == 0 { return nil }
        var code = errno
        let parent = (folder as NSString).deletingLastPathComponent
        if code == ENOENT, !parent.isEmpty, parent != folder {
            if let failure = makeFolder(parent) { return failure }
            if mkdir(folder, 0o700) == 0 { return nil }
            code = errno
        }
        if code == EEXIST {
            var info = stat()
            if stat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { return nil }
        }
        return code
    }

    // The new connections, on the queue of the listener: the limit of open connections, then a
    // task for each connection that runs handle with the request time limit. The connection
    // closes when that task ends.
    nonisolated private static func accept(
        gate: ConnectionGate, queue: DispatchQueue, limit: Duration, clock: any Clock<Duration>,
        handle: @escaping Handler
    ) -> @Sendable (NWConnection) -> Void {
        { connection in
            guard gate.enter(connection) else {
                connection.cancel()
                return
            }
            connection.start(queue: queue)
            let client = UnixSocketConnection(connection)
            Task.detached {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await handle(client) }
                    group.addTask { try? await clock.sleep(for: limit) }
                    await group.next()
                    group.cancelAll()
                    // The close ends a receive or an answer that waits.
                    connection.cancel()
                }
                gate.leave(connection)
            }
        }
    }
}

// The open connections, for the queue of the listener and the tasks of the connections. A
// connection enters only while the listener listens and the count is under the limit. A shut
// closes each open connection.
private final class ConnectionGate: Sendable {
    private struct State {
        var open = false
        var connections: [ObjectIdentifier: NWConnection] = [:]
    }

    private let state = Mutex(State())
    private let limit: Int
    private let refused: @Sendable () -> Void

    init(limit: Int, refused: @escaping @Sendable () -> Void) {
        self.limit = limit
        self.refused = refused
    }

    func open() { state.withLock { $0.open = true } }

    func shut() {
        let open = state.withLock { s in
            s.open = false
            return Array(s.connections.values)
        }
        for connection in open { connection.cancel() }
    }

    // Let the connection in, or count it as refused.
    func enter(_ connection: NWConnection) -> Bool {
        let entered = state.withLock { s in
            guard s.open, s.connections.count < limit else { return false }
            s.connections[ObjectIdentifier(connection)] = connection
            return true
        }
        if !entered { refused() }
        return entered
    }

    func leave(_ connection: NWConnection) {
        _ = state.withLock { $0.connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }
}

// One connection of a client. One task reads it and answers it.
package final class UnixSocketConnection: Sendable {
    private let connection: NWConnection
    // True after the client ended its side, or after the connection failed or closed.
    private let ended = Mutex(false)

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    // The next bytes of the client, at most 65,536. nil when the client ended its side or the
    // connection failed or closed.
    package func receive() async -> [UInt8]? {
        guard !ended.withLock({ $0 }) else { return nil }
        return await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                [self] data, _, isComplete, error in
                if isComplete || error != nil { ended.withLock { $0 = true } }
                let bytes = data.map { [UInt8]($0) } ?? []
                continuation.resume(returning: bytes.isEmpty ? nil : bytes)
            }
        }
    }

    // Send the answer and end the side of the server. The call ends when the send is done or
    // failed. The connection closes when the work of the connection ends.
    package func answer(_ bytes: [UInt8]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(
                content: Data(bytes), contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in continuation.resume() })
        }
    }
}
