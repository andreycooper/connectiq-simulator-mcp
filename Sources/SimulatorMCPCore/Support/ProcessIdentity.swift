import Darwin
import Foundation

public struct ProcessStartIdentity: Codable, Hashable, Sendable {
    public let seconds: UInt64
    public let microseconds: UInt64

    public init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }
}

public struct ProcessIdentitySnapshot: Codable, Equatable, Sendable {
    public let pid: Int32
    public let parentPid: Int32
    public let processGroupId: Int32
    public let start: ProcessStartIdentity
    public let executablePath: String
    public let arguments: [String]

    public init(
        pid: Int32,
        parentPid: Int32,
        processGroupId: Int32,
        start: ProcessStartIdentity,
        executablePath: String,
        arguments: [String]
    ) {
        self.pid = pid
        self.parentPid = parentPid
        self.processGroupId = processGroupId
        self.start = start
        self.executablePath = executablePath
        self.arguments = arguments
    }

    public var stableIdentity: StableProcessIdentity {
        StableProcessIdentity(
            pid: pid,
            processGroupId: processGroupId,
            start: start,
            executablePath: executablePath,
            arguments: arguments)
    }
}

public struct StableProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let processGroupId: Int32
    public let start: ProcessStartIdentity
    public let executablePath: String
    public let arguments: [String]

    public init(
        pid: Int32,
        processGroupId: Int32,
        start: ProcessStartIdentity,
        executablePath: String,
        arguments: [String]
    ) {
        self.pid = pid
        self.processGroupId = processGroupId
        self.start = start
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

public protocol ProcessIdentityReading: Sendable {
    func snapshot(pid: Int32) throws -> ProcessIdentitySnapshot?
    func childPIDs(parentPid: Int32) throws -> [Int32]
    func processGroupPIDs(processGroupId: Int32) throws -> [Int32]
}

struct KernelBSDIdentity: Equatable, Sendable {
    let pid: Int32
    let parentPid: Int32
    let processGroupId: Int32
    let start: ProcessStartIdentity
}

protocol KernelProcessReading: Sendable {
    func bsdIdentity(pid: Int32) throws -> KernelBSDIdentity?
    func executablePath(pid: Int32) throws -> String?
    func arguments(pid: Int32) throws -> [String]?
    func childPIDs(parentPid: Int32) throws -> [Int32]
    func processGroupPIDs(processGroupId: Int32) throws -> [Int32]
}

struct DarwinKernelProcessReader: KernelProcessReading, Sendable {
    func bsdIdentity(pid: Int32) throws -> KernelBSDIdentity? {
        var info = proc_bsdinfo()
        errno = 0
        let captured = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                pid, PROC_PIDTBSDINFO, 0, pointer,
                Int32(MemoryLayout<proc_bsdinfo>.stride))
        }
        guard captured == Int32(MemoryLayout<proc_bsdinfo>.stride) else {
            if captured == 0, Self.indicatesVanishedProcess(errno) { return nil }
            throw Self.inspectionError(
                "proc_pidinfo returned \(captured) bytes for PID \(pid).", pid: pid)
        }
        guard Int32(info.pbi_pid) == pid else {
            throw Self.inspectionError(
                "proc_pidinfo returned identity for PID \(info.pbi_pid) while PID \(pid) was requested.",
                pid: pid)
        }
        return KernelBSDIdentity(
            pid: pid,
            parentPid: Int32(info.pbi_ppid),
            processGroupId: Int32(info.pbi_pgid),
            start: ProcessStartIdentity(
                seconds: info.pbi_start_tvsec,
                microseconds: info.pbi_start_tvusec))
    }

    func executablePath(pid: Int32) throws -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        errno = 0
        let captured = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard captured > 0 else {
            if Self.indicatesVanishedProcess(errno) { return nil }
            throw Self.inspectionError("proc_pidpath failed for PID \(pid).", pid: pid)
        }
        let end = buffer.firstIndex(of: 0) ?? min(Int(captured), buffer.count)
        guard end > 0 else {
            throw Self.inspectionError("proc_pidpath returned an empty path for PID \(pid).", pid: pid)
        }
        let rawPath = String(
            decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
        return URL(fileURLWithPath: rawPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    func arguments(pid: Int32) throws -> [String]? {
        let maximum = sysconf(_SC_ARG_MAX)
        guard maximum > 0, maximum <= 16 * 1_024 * 1_024 else {
            throw Self.inspectionError(
                "sysconf(_SC_ARG_MAX) returned unsafe bound \(maximum) for PID \(pid).", pid: pid)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.addressSpaceReplacementBudget)
        while true {
            var mib = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = Int(maximum)
            var data = Data(count: size)
            errno = 0
            var failure: Int32 = 0
            let result = data.withUnsafeMutableBytes { raw -> Int32 in
                let code = sysctl(&mib, u_int(mib.count), raw.baseAddress, &size, nil, 0)
                // Captured immediately: the confirmation below issues another
                // syscall, which would otherwise overwrite errno.
                failure = errno
                return code
            }
            if result == 0 {
                guard size > 0, size <= data.count else {
                    throw Self.inspectionError(
                        "sysctl(KERN_PROCARGS2) returned invalid length \(size) for PID \(pid).",
                        pid: pid)
                }
                data.count = size
                return try DarwinProcessIdentityReader.parseProcArguments(data)
            }
            switch try Self.resolveArgumentsFailure(
                errno: failure, pid: pid, deadlineExpired: clock.now >= deadline,
                confirmGone: { try bsdIdentity(pid: pid) == nil })
            {
            case .vanished:
                return nil
            case .observeAgain:
                // Yield rather than spin: exec completes in microseconds, and
                // the loop exits on an observed state change, never on elapsed
                // time. The deadline only bounds a process that never recovers.
                sched_yield()
            }
        }
    }

    func childPIDs(parentPid: Int32) throws -> [Int32] {
        try listPIDs(type: UInt32(PROC_PPID_ONLY), typeInfo: UInt32(bitPattern: parentPid))
    }

    func processGroupPIDs(processGroupId: Int32) throws -> [Int32] {
        try listPIDs(type: UInt32(PROC_PGRP_ONLY), typeInfo: UInt32(bitPattern: processGroupId))
    }

    private func listPIDs(type: UInt32, typeInfo: UInt32) throws -> [Int32] {
        let requiredBytes = proc_listpids(type, typeInfo, nil, 0)
        guard requiredBytes >= 0 else {
            throw Self.inspectionError(
                "proc_listpids sizing failed for selector \(type):\(typeInfo).")
        }
        guard requiredBytes > 0 else { return [] }
        var pids = [Int32](
            repeating: 0,
            count: Int(requiredBytes) / MemoryLayout<Int32>.stride + 32)
        let capturedBytes = pids.withUnsafeMutableBytes { raw in
            proc_listpids(type, typeInfo, raw.baseAddress, Int32(raw.count))
        }
        guard capturedBytes >= 0, capturedBytes <= pids.count * MemoryLayout<Int32>.stride else {
            throw Self.inspectionError(
                "proc_listpids returned invalid length \(capturedBytes) for selector \(type):\(typeInfo).")
        }
        return pids.prefix(Int(capturedBytes) / MemoryLayout<Int32>.stride)
            .filter { $0 > 0 }
            .sorted()
    }

    /// Bounds the wait for an exec to complete. Two orders of magnitude above
    /// the largest window measured (1147 us), so it bounds a pathological
    /// process without truncating a normal one.
    static let addressSpaceReplacementBudget: Duration = .milliseconds(250)

    private static func indicatesVanishedProcess(_ code: Int32) -> Bool {
        code == ESRCH || code == ENOENT
    }

    /// How a `KERN_PROCARGS2` failure is to be interpreted.
    enum ArgumentCaptureDisposition: Equatable, Sendable {
        /// The process is gone. The caller sees `nil`.
        case vanished
        /// The argument region could not be copied. Measured 2026-08-04, this
        /// has two causes and they are told apart only by observation: a dying
        /// process whose address space has been removed, and a live process
        /// REPLACING its address space mid-exec.
        case addressSpaceUnreadable
        /// A genuine fault that must fail closed.
        case fault
    }

    /// What the caller should do after an unreadable argument region.
    enum ArgumentFailureResolution: Equatable, Sendable {
        /// The process is gone; report absence.
        case vanished
        /// The process is alive and replacing its address space. Its argv
        /// becomes readable when exec completes, so observe again.
        case observeAgain
    }

    /// Classification is deliberately site-specific: `indicatesVanishedProcess`
    /// is shared with `proc_pidinfo` and `proc_pidpath`, and neither was
    /// measured to return `EIO` for a dying process — both return `ESRCH`.
    /// Widening the shared predicate would broaden a heuristic past its
    /// evidence.
    ///
    /// `EIO` is returned when the target's argument region can no longer be
    /// copied because its address space is already being removed — the terminal
    /// phase of process death. Measured 2026-08-04 at 6.3% of force-kills for a
    /// 64 MB target rising to 12.3% at 1 GB, and never once observed for a live
    /// process across 3.4M samples.
    static func disposition(forArgumentsErrno code: Int32) -> ArgumentCaptureDisposition {
        if indicatesVanishedProcess(code) || code == EINVAL { return .vanished }
        if code == EIO { return .addressSpaceUnreadable }
        return .fault
    }

    /// Resolves an unreadable argument region.
    ///
    /// `confirmGone` is the second opinion: `EIO` on a process that no longer
    /// resolves is death, and absence is reported. `EIO` on one that still
    /// resolves is an exec in progress — the process is alive and its argv
    /// becomes readable when exec completes, so the caller observes again.
    /// Reporting absence there would let a live descendant escape the tree
    /// walk, which is the failure this project guards hardest against.
    ///
    /// The deadline bounds a process that never becomes readable, a state we
    /// have not observed. Measured exec windows: p50 180 us, p99 283 us, max
    /// 1147 us across `/usr/bin/true` and `/usr/bin/java`.
    static func resolveArgumentsFailure(
        errno code: Int32,
        pid: Int32,
        deadlineExpired: Bool,
        confirmGone: () throws -> Bool
    ) throws -> ArgumentFailureResolution {
        switch disposition(forArgumentsErrno: code) {
        case .vanished:
            return .vanished
        case .addressSpaceUnreadable:
            if try confirmGone() { return .vanished }
            guard !deadlineExpired else {
                throw inspectionError(
                    """
                    sysctl(KERN_PROCARGS2) could not read PID \(pid)'s argument region \
                    within the address-space replacement budget, and the process is still live.
                    """,
                    pid: pid)
            }
            return .observeAgain
        case .fault:
            throw inspectionError(
                "sysctl(KERN_PROCARGS2) failed for PID \(pid) with errno \(code).", pid: pid)
        }
    }

    /// Records whether the target PID was still resolvable at throw time.
    /// A dying process and a genuinely faulted one are otherwise
    /// indistinguishable after the fact, which is what left gateD5's PID 816
    /// unidentifiable.
    static func inspectionError(_ message: String, pid: Int32? = nil) -> ToolError {
        ToolError(
            code: "process_inspection_failed",
            message: message,
            fix: "Retry the operation. If it repeats, stop the simulator and inspect the reported process identities before retrying.",
            details: pid.map {
                ["pid": .int(Int($0)), "pidAlive": .bool(isProcessAlive($0))]
            })
    }
}

public struct DarwinProcessIdentityReader: ProcessIdentityReading, Sendable {
    private let kernel: any KernelProcessReading

    public init() {
        self.kernel = DarwinKernelProcessReader()
    }

    init(kernel: any KernelProcessReading) {
        self.kernel = kernel
    }

    public func snapshot(pid: Int32) throws -> ProcessIdentitySnapshot? {
        guard pid > 0 else {
            throw DarwinKernelProcessReader.inspectionError(
                "Cannot inspect non-positive PID \(pid).", pid: pid)
        }
        guard let before = try kernel.bsdIdentity(pid: pid) else { return nil }
        guard let executablePath = try kernel.executablePath(pid: pid) else { return nil }
        guard let arguments = try kernel.arguments(pid: pid) else { return nil }
        guard let after = try kernel.bsdIdentity(pid: pid) else { return nil }
        guard before == after else {
            throw DarwinKernelProcessReader.inspectionError(
                "PID \(pid) changed identity while its executable and arguments were captured.", pid: pid)
        }
        guard !executablePath.isEmpty, !arguments.isEmpty else {
            throw DarwinKernelProcessReader.inspectionError(
                "PID \(pid) exposed an empty executable path or argument vector.", pid: pid)
        }
        return ProcessIdentitySnapshot(
            pid: before.pid,
            parentPid: before.parentPid,
            processGroupId: before.processGroupId,
            start: before.start,
            executablePath: executablePath,
            arguments: arguments)
    }

    public func childPIDs(parentPid: Int32) throws -> [Int32] {
        try kernel.childPIDs(parentPid: parentPid)
    }

    public func processGroupPIDs(processGroupId: Int32) throws -> [Int32] {
        try kernel.processGroupPIDs(processGroupId: processGroupId)
    }

    static func parseProcArguments(_ data: Data) throws -> [String] {
        func malformed(_ reason: String) -> ToolError {
            DarwinKernelProcessReader.inspectionError(
                "KERN_PROCARGS2 returned malformed data: \(reason).")
        }

        guard data.count >= MemoryLayout<Int32>.size else {
            throw malformed("the result has no argc")
        }
        let argc = data.prefix(MemoryLayout<Int32>.size).withUnsafeBytes {
            $0.loadUnaligned(as: Int32.self)
        }
        guard argc > 0 else { throw malformed("argc is not positive") }

        let bytes = [UInt8](data.dropFirst(MemoryLayout<Int32>.size))
        guard Int(argc) <= bytes.count else {
            throw malformed("argc exceeds the bounded result length")
        }
        var index = 0
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        guard index < bytes.count else { throw malformed("the executable path is unterminated") }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argc))
        while arguments.count < Int(argc) {
            guard index < bytes.count else {
                throw malformed("only \(arguments.count) of \(argc) arguments were present")
            }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            guard index < bytes.count else {
                throw malformed("argument \(arguments.count) was unterminated")
            }
            guard let argument = String(bytes: bytes[start..<index], encoding: .utf8) else {
                throw malformed("argument \(arguments.count) was not UTF-8")
            }
            arguments.append(argument)
            index += 1
        }
        return arguments
    }
}
