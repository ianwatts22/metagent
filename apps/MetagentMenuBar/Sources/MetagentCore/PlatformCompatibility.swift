#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
import CLinuxShims
#endif
import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

// Small libc and file-metadata seams so the core and headless helper build on
// both macOS and Linux. macOS keeps its existing system calls; Linux gets the
// nearest POSIX equivalent or a conservative fallback.

/// Module-qualified libc calls, for call sites where a member such as
/// `FileHandle.write` or `close()` would otherwise shadow the free function.
enum LibC {
    #if canImport(Darwin)
    @discardableResult static func open(_ path: String, _ flags: Int32) -> Int32 { Darwin.open(path, flags) }
    @discardableResult static func open(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 { Darwin.open(path, flags, mode) }
    @discardableResult static func close(_ descriptor: Int32) -> Int32 { Darwin.close(descriptor) }
    @discardableResult static func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        Darwin.read(descriptor, buffer, count)
    }
    @discardableResult static func write(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        Darwin.write(descriptor, buffer, count)
    }
    @discardableResult static func poll(_ descriptors: UnsafeMutablePointer<pollfd>?, _ count: nfds_t, _ timeout: Int32) -> Int32 {
        Darwin.poll(descriptors, count, timeout)
    }
    @discardableResult static func kill(_ processID: pid_t, _ signal: Int32) -> Int32 { Darwin.kill(processID, signal) }
    @discardableResult static func rename(_ old: String, _ new: String) -> Int32 { Darwin.rename(old, new) }
    #else
    @discardableResult static func open(_ path: String, _ flags: Int32) -> Int32 { Glibc.open(path, flags) }
    @discardableResult static func open(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 { Glibc.open(path, flags, mode) }
    @discardableResult static func close(_ descriptor: Int32) -> Int32 { Glibc.close(descriptor) }
    @discardableResult static func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        Glibc.read(descriptor, buffer, count)
    }
    @discardableResult static func write(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        Glibc.write(descriptor, buffer, count)
    }
    @discardableResult static func poll(_ descriptors: UnsafeMutablePointer<pollfd>?, _ count: nfds_t, _ timeout: Int32) -> Int32 {
        Glibc.poll(descriptors, count, timeout)
    }
    @discardableResult static func kill(_ processID: pid_t, _ signal: Int32) -> Int32 { Glibc.kill(processID, signal) }
    @discardableResult static func rename(_ old: String, _ new: String) -> Int32 { Glibc.rename(old, new) }
    #endif
}

#if canImport(Darwin)
typealias SpawnFileActions = posix_spawn_file_actions_t?
typealias SpawnAttributes = posix_spawnattr_t?
func makeSpawnFileActions() -> SpawnFileActions { nil }
func makeSpawnAttributes() -> SpawnAttributes { nil }

func spawnFileActionsAddChdir(_ actions: inout SpawnFileActions, _ path: String) -> Int32 {
    posix_spawn_file_actions_addchdir(&actions, path)
}
#else
typealias SpawnFileActions = posix_spawn_file_actions_t
typealias SpawnAttributes = posix_spawnattr_t
func makeSpawnFileActions() -> SpawnFileActions { posix_spawn_file_actions_t() }
func makeSpawnAttributes() -> SpawnAttributes { posix_spawnattr_t() }

func spawnFileActionsAddChdir(_ actions: inout SpawnFileActions, _ path: String) -> Int32 {
    metagent_spawn_file_actions_addchdir(&actions, path)
}
#endif

/// Asks the child to close every inherited descriptor that the file actions
/// do not explicitly map, so a pipe end held by the parent cannot keep a
/// child's stdin or stdout open. Darwin does this with a spawn flag.
func spawnCloseUnmappedDescriptors(
    _ actions: inout SpawnFileActions,
    _ attributeFlags: inout Int32
) -> Int32 {
    #if canImport(Darwin)
    attributeFlags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
    return 0
    #else
    return metagent_spawn_file_actions_addclosefrom(&actions, 3)
    #endif
}

/// Writes to a pipe whose reader exited must fail with EPIPE, not kill us.
func disableSIGPIPE(on descriptor: Int32) -> Bool {
    #if canImport(Darwin)
    return fcntl(descriptor, F_SETNOSIGPIPE, 1) >= 0
    #else
    // Linux has no per-descriptor switch; the headless helper ignores SIGPIPE
    // process-wide, which also covers sockets and FileHandle writes.
    signal(SIGPIPE, SIG_IGN)
    return true
    #endif
}

/// Child pid and raw status reported by `waitid` for an exited child.
func exitedChildInfo(_ info: siginfo_t) -> (pid: pid_t, status: Int32) {
    #if canImport(Darwin)
    return (info.si_pid, info.si_status)
    #else
    return (info._sifields._sigchld.si_pid, info._sifields._sigchld.si_status)
    #endif
}

/// A monotonic clock that keeps advancing while the machine sleeps.
func continuousClockSeconds() -> TimeInterval {
    #if canImport(Darwin)
    return Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    #else
    var time = timespec()
    clock_gettime(CLOCK_BOOTTIME, &time)
    return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    #endif
}

func modificationTime(_ info: stat) -> timespec {
    #if canImport(Darwin)
    info.st_mtimespec
    #else
    info.st_mtim
    #endif
}

/// Birth time distinguishes a reused inode on macOS. Linux `stat` does not
/// report it, so identities there fall back to device and inode alone.
func creationTime(_ info: stat) -> timespec {
    #if canImport(Darwin)
    info.st_birthtimespec
    #else
    timespec()
    #endif
}

/// Moves `name` under `source` to `target` under `destination` only if the
/// target does not already exist.
func renameAtExclusive(_ source: Int32, _ name: String, _ destination: Int32, _ target: String) -> Int32 {
    #if canImport(Darwin)
    return renameatx_np(source, name, destination, target, UInt32(RENAME_EXCL))
    #else
    return metagent_renameat_noreplace(source, name, destination, target)
    #endif
}

/// The path a descriptor currently refers to.
func pathForDescriptor(_ descriptor: Int32) -> String? {
    #if canImport(Darwin)
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    #else
    return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(descriptor)")
    #endif
}

#if !canImport(Darwin)
/// A pidfd for `processID`, or -1 when the kernel or sandbox refuses one.
func openProcessDescriptor(_ processID: pid_t) -> Int32 {
    metagent_pidfd_open(processID)
}
#endif

/// PNG signature plus a well-formed, non-empty IHDR header. ImageIO decodes the
/// whole image on macOS; Linux has no system image decoder, so the headless
/// helper accepts a structurally valid single PNG instead.
func isDecodablePNG(_ data: Data) -> Bool {
    #if canImport(ImageIO)
    guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
          (CGImageSourceGetType(imageSource) as String?) == "public.png",
          CGImageSourceGetCount(imageSource) == 1,
          CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil
    else { return false }
    return true
    #else
    let bytes = [UInt8](data.prefix(33))
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    guard bytes.count == 33, Array(bytes[0..<8]) == signature,
          Array(bytes[12..<16]) == Array("IHDR".utf8)
    else { return false }
    func bigEndian(_ offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
    return bigEndian(8) == 13 && bigEndian(16) > 0 && bigEndian(20) > 0
    #endif
}

#if !canImport(IOKit)
/// Servers and containers usually expose no battery at all; only a laptop
/// running on battery counts as energy constrained.
func linuxHasExternalPower() -> Bool {
    let root = URL(fileURLWithPath: "/sys/class/power_supply")
    guard let supplies = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil
    ) else { return true }
    func value(_ supply: URL, _ name: String) -> String? {
        (try? String(contentsOf: supply.appendingPathComponent(name), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var hasBattery = false
    for supply in supplies {
        switch value(supply, "type") {
        case "Mains", "USB":
            if value(supply, "online") == "1" { return true }
        case "Battery":
            hasBattery = true
        default:
            continue
        }
    }
    return !hasBattery
}
#endif
