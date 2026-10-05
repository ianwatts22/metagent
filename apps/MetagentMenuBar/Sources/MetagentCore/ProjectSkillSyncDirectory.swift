import Darwin
import Foundation

/// All copy writes are relative to retained directory descriptors, not a
/// checkout pathname that another process can replace underneath the lock.
final class ProjectSkillSyncDirectory {
    let descriptor: CInt

    init(_ url: URL) throws {
        descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw projectSyncError("A sync directory could not be opened safely.") }
    }

    private init(descriptor: CInt) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }

    var identity: ProjectSkillSyncDirectoryIdentity { get throws { try projectSyncIdentity(descriptor: descriptor) } }

    func child(_ name: String, create: Bool = false, mode: mode_t = 0o755) throws -> ProjectSkillSyncDirectory {
        try validate(name)
        if create, mkdirat(descriptor, name, mode) != 0, errno != EEXIST {
            throw projectSyncError("A sync directory could not be created safely.")
        }
        let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw projectSyncError("A sync directory became linked or unavailable.") }
        return ProjectSkillSyncDirectory(descriptor: child)
    }

    func metadata(_ name: String) throws -> stat? {
        try validate(name)
        var value = stat()
        if fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
        if errno == ENOENT { return nil }
        throw projectSyncError("A sync entry could not be checked safely.")
    }

    func isNamed(_ name: String, in parent: ProjectSkillSyncDirectory) throws -> Bool {
        guard let value = try parent.metadata(name), (value.st_mode & S_IFMT) == S_IFDIR else { return false }
        return try identity == ProjectSkillSyncDirectoryIdentity(
            device: UInt64(truncatingIfNeeded: value.st_dev), inode: UInt64(value.st_ino))
    }

    func names(limit: Int) throws -> [String] {
        // A fresh open description avoids sharing readdir offsets with the
        // retained descriptor or another enumeration of this same directory.
        let fresh = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fresh >= 0 else { throw projectSyncError("A sync directory could not be enumerated.") }
        guard let handle = fdopendir(fresh) else {
            Darwin.close(fresh)
            throw projectSyncError("A sync directory could not be enumerated.")
        }
        defer { closedir(handle) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(handle) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard result.count < limit else { throw projectSyncError("The directory exceeds the bounded entry limit.") }
            result.append(name)
            errno = 0
        }
        guard errno == 0 else { throw projectSyncError("A sync directory changed while enumerating.") }
        return result.sorted()
    }

    func read(_ name: String, limit: Int) throws -> (data: Data, permissions: Int) {
        try validate(name)
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw projectSyncError("A bundled file could not be opened safely.") }
        return try projectSyncReadFile(descriptor: file, limit: limit)
    }

    func write(_ relativePath: String, data: Data, permissions: Int) throws {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let name = components.last else { throw projectSyncError("A copied file path is invalid.") }
        var parent = self
        for component in components.dropLast() { parent = try parent.child(component, create: true) }
        try parent.validate(name)
        let file = openat(parent.descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw projectSyncError("A copied file could not be created safely.") }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        guard fchmod(file, mode_t(permissions)) == 0 else { throw projectSyncError("Copied file permissions could not be preserved.") }
    }

    func move(_ name: String, to destination: ProjectSkillSyncDirectory, as target: String) throws {
        try validate(name)
        try destination.validate(target)
        // Never replace a concurrently created target, even an empty folder.
        guard renameatx_np(descriptor, name, destination.descriptor, target, UInt32(RENAME_EXCL)) == 0 else {
            throw projectSyncError("A copy destination changed or a bundle could not be moved safely.")
        }
    }

    func writeAtomically(_ name: String, data: Data) throws {
        try validate(name)
        let temporary = ".metagent-manifest-\(UUID().uuidString)"
        defer { unlinkat(descriptor, temporary, 0) }
        try write(temporary, data: data, permissions: 0o644)
        guard renameat(descriptor, temporary, descriptor, name) == 0 else {
            throw projectSyncError("The ownership manifest could not be committed safely.")
        }
    }

    func removeTree(_ name: String, expectedIdentity: ProjectSkillSyncDirectoryIdentity? = nil, depth: Int = 0) throws {
        guard depth <= 36 else { throw projectSyncError("A recovery tree exceeded its cleanup bound.") }
        guard let value = try metadata(name) else { return }
        let observedIdentity = ProjectSkillSyncDirectoryIdentity(
            device: UInt64(truncatingIfNeeded: value.st_dev), inode: UInt64(value.st_ino))
        if let expectedIdentity, observedIdentity != expectedIdentity {
            throw projectSyncError("A recovery directory changed; its replacement will not be removed.")
        }
        if (value.st_mode & S_IFMT) == S_IFDIR {
            let directory = try child(name)
            guard try directory.identity == observedIdentity else { throw projectSyncError("A recovery directory changed during cleanup.") }
            for entry in try directory.names(limit: 4_096) { try directory.removeTree(entry, depth: depth + 1) }
            guard try directory.isNamed(name, in: self) else { throw projectSyncError("A recovery directory changed during cleanup.") }
            guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else { throw projectSyncError("Recovery cleanup could not finish.") }
        } else {
            guard unlinkat(descriptor, name, 0) == 0 else { throw projectSyncError("Recovery cleanup could not finish.") }
        }
    }

    /// For recovery messages only; never used to route a filesystem mutation.
    func currentPath() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func validate(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw projectSyncError("A sync entry name is invalid.")
        }
    }
}
