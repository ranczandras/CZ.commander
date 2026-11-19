import Foundation

public enum RemoteProtocolType: String, CaseIterable, Codable, Sendable {
    case sftp = "SFTP (SSH)"
    case ftp = "FTP"
    case ftps = "FTPS (SSL)"
    case webdav = "WebDAV (HTTPS)"
    case localGateway = "Local VFS Gateway"

    public var defaultPort: Int {
        switch self {
        case .sftp: return 22
        case .ftp: return 21
        case .ftps: return 990
        case .webdav: return 443
        case .localGateway: return 0
        }
    }
}

public struct RemoteConnectionProfile: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var protocolType: RemoteProtocolType
    public var host: String
    public var port: Int
    public var username: String
    public var passwordOrKeyPath: String
    public var remoteDirectory: String
    public var localDirectory: String
    public var useSSHKeyFile: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        protocolType: RemoteProtocolType = .sftp,
        host: String,
        port: Int? = nil,
        username: String = "",
        passwordOrKeyPath: String = "",
        remoteDirectory: String = "/",
        localDirectory: String = "",
        useSSHKeyFile: Bool = false
    ) {
        self.id = id
        self.title = title
        self.protocolType = protocolType
        self.host = host
        self.port = port ?? protocolType.defaultPort
        self.username = username
        self.passwordOrKeyPath = passwordOrKeyPath
        self.remoteDirectory = remoteDirectory
        self.localDirectory = localDirectory
        self.useSSHKeyFile = useSSHKeyFile
    }
}

public enum RemoteConnectionEngine {
    public static func listDirectory(
        profile: RemoteConnectionProfile,
        remotePath: String
    ) throws -> [FileItem] {
        let normalizedPath = remotePath.isEmpty ? profile.remoteDirectory : remotePath

        if profile.protocolType == .localGateway || profile.host.hasPrefix("/") {
            let rootPath = profile.host.hasPrefix("/") ? profile.host : normalizedPath
            let items = try FileSystemEngine.listDirectory(at: rootPath, showHidden: true, includeParentEntry: true)
            return items.map { item in
                var copy = item
                copy.remoteConnectionID = profile.id
                return copy
            }
        }

        switch profile.protocolType {
        case .sftp:
            return try listSFTP(profile: profile, remotePath: normalizedPath)
        case .ftp, .ftps, .webdav:
            return try listViaCurl(profile: profile, remotePath: normalizedPath)
        case .localGateway:
            return []
        }
    }

    private static func listSFTP(profile: RemoteConnectionProfile, remotePath: String) throws -> [FileItem] {
        var sshArgs: [String] = ["-p", "\(profile.port)", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
        if profile.useSSHKeyFile && !profile.passwordOrKeyPath.isEmpty {
            sshArgs.append(contentsOf: ["-i", profile.passwordOrKeyPath])
        }
        let targetHost = profile.username.isEmpty ? profile.host : "\(profile.username)@\(profile.host)"
        sshArgs.append(targetHost)
        sshArgs.append("ls -la \"\(remotePath)\"")

        let output = try ArchiveEngine.runCommand(executable: "/usr/bin/ssh", arguments: sshArgs)
        return parseUnixLsOutput(output, remoteBasePath: remotePath, connectionID: profile.id)
    }

    private static func listViaCurl(profile: RemoteConnectionProfile, remotePath: String) throws -> [FileItem] {
        let scheme: String
        switch profile.protocolType {
        case .ftp: scheme = "ftp"
        case .ftps: scheme = "ftps"
        case .webdav: scheme = "https"
        default: scheme = "ftp"
        }
        let cleanPath = remotePath.hasPrefix("/") ? remotePath : "/\(remotePath)"
        let urlStr = "\(scheme)://\(profile.host):\(profile.port)\(cleanPath.hasSuffix("/") ? cleanPath : cleanPath + "/")"
        var args = ["-s", "-S", "--connect-timeout", "5"]
        if !profile.username.isEmpty {
            args.append(contentsOf: ["-u", "\(profile.username):\(profile.passwordOrKeyPath)"])
        }
        args.append(urlStr)
        let output = try ArchiveEngine.runCommand(executable: "/usr/bin/curl", arguments: args)
        return parseUnixLsOutput(output, remoteBasePath: cleanPath, connectionID: profile.id)
    }

    public static func parseUnixLsOutput(
        _ output: String,
        remoteBasePath: String,
        connectionID: UUID
    ) -> [FileItem] {
        var items: [FileItem] = []
        let cleanBase = remoteBasePath == "/" ? "" : remoteBasePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parentPath: String
        if cleanBase.isEmpty {
            parentPath = "/"
        } else if let idx = cleanBase.lastIndex(of: "/") {
            parentPath = "/" + String(cleanBase[..<idx])
        } else {
            parentPath = "/"
        }

        items.append(
            FileItem(
                id: "remote-parent::\(connectionID)::\(remoteBasePath)",
                name: "..",
                fullPath: parentPath,
                isDirectory: true,
                isParentDirectoryEntry: true,
                remoteConnectionID: connectionID
            )
        )

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("total ") { continue }
            let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard parts.count >= 9 else { continue }
            let perm = String(parts[0])
            let name = String(parts[8])
            if name == "." || name == ".." { continue }
            let isDir = perm.hasPrefix("d")
            let isLnk = perm.hasPrefix("l")
            let size = Int64(parts[4]) ?? 0
            let fullRemotePath = (remoteBasePath as NSString).appendingPathComponent(name)

            items.append(
                FileItem(
                    id: "remote::\(connectionID)::\(fullRemotePath)",
                    name: name,
                    fullPath: fullRemotePath,
                    isDirectory: isDir,
                    isSymlink: isLnk,
                    isHidden: name.hasPrefix("."),
                    size: size,
                    modificationDate: Date(),
                    creationDate: Date(),
                    posixPermissions: isDir ? 0o755 : 0o644,
                    ownerName: String(parts[2]),
                    groupName: String(parts[3]),
                    remoteConnectionID: connectionID
                )
            )
        }
        return items
    }

    public static func downloadItem(
        profile: RemoteConnectionProfile,
        remotePath: String,
        toLocalDirectory localDir: String
    ) throws {
        if profile.protocolType == .localGateway || profile.host.hasPrefix("/") {
            _ = try FileSystemEngine.copyOrMoveItems(sources: [remotePath], toDestinationDirectory: localDir, isMove: false)
            return
        }
        let targetLocal = (localDir as NSString).appendingPathComponent((remotePath as NSString).lastPathComponent)
        if profile.protocolType == .sftp {
            var scpArgs = ["-P", "\(profile.port)", "-r"]
            if profile.useSSHKeyFile && !profile.passwordOrKeyPath.isEmpty {
                scpArgs.append(contentsOf: ["-i", profile.passwordOrKeyPath])
            }
            let hostPart = profile.username.isEmpty ? profile.host : "\(profile.username)@\(profile.host)"
            scpArgs.append("\(hostPart):\(remotePath)")
            scpArgs.append(targetLocal)
            _ = try ArchiveEngine.runCommand(executable: "/usr/bin/scp", arguments: scpArgs)
        } else {
            let scheme = profile.protocolType == .ftps ? "ftps" : "ftp"
            let urlStr = "\(scheme)://\(profile.host):\(profile.port)\(remotePath)"
            var args = ["-s", "-S", "-o", targetLocal]
            if !profile.username.isEmpty {
                args.append(contentsOf: ["-u", "\(profile.username):\(profile.passwordOrKeyPath)"])
            }
            args.append(urlStr)
            _ = try ArchiveEngine.runCommand(executable: "/usr/bin/curl", arguments: args)
        }
    }

    public static func uploadItem(
        profile: RemoteConnectionProfile,
        localPath: String,
        toRemoteDirectory remoteDir: String
    ) throws {
        if profile.protocolType == .localGateway || profile.host.hasPrefix("/") {
            _ = try FileSystemEngine.copyOrMoveItems(sources: [localPath], toDestinationDirectory: remoteDir, isMove: false)
            return
        }
        let targetRemote = (remoteDir as NSString).appendingPathComponent((localPath as NSString).lastPathComponent)
        if profile.protocolType == .sftp {
            var scpArgs = ["-P", "\(profile.port)", "-r"]
            if profile.useSSHKeyFile && !profile.passwordOrKeyPath.isEmpty {
                scpArgs.append(contentsOf: ["-i", profile.passwordOrKeyPath])
            }
            let hostPart = profile.username.isEmpty ? profile.host : "\(profile.username)@\(profile.host)"
            scpArgs.append(localPath)
            scpArgs.append("\(hostPart):\(targetRemote)")
            _ = try ArchiveEngine.runCommand(executable: "/usr/bin/scp", arguments: scpArgs)
        } else {
            let scheme = profile.protocolType == .ftps ? "ftps" : "ftp"
            let urlStr = "\(scheme)://\(profile.host):\(profile.port)\(targetRemote)"
            var args = ["-s", "-S", "-T", localPath]
            if !profile.username.isEmpty {
                args.append(contentsOf: ["-u", "\(profile.username):\(profile.passwordOrKeyPath)"])
            }
            args.append(urlStr)
            _ = try ArchiveEngine.runCommand(executable: "/usr/bin/curl", arguments: args)
        }
    }
}
