import Foundation

enum SSHEndpoint: Codable, Hashable, Sendable {
    case openSSHConfigAlias(String)
    case direct(host: String, user: String?, port: UInt16)

    var displayDestination: String {
        switch self {
        case .openSSHConfigAlias(let alias):
            return alias
        case .direct(let host, let user, let port):
            let destination = user.map { "\($0)@\(host)" } ?? host
            return port == 22 ? destination : "\(destination):\(port)"
        }
    }
}

enum SSHAuthenticationPreference: String, Codable, Hashable, Sendable {
    /// OpenSSH config, ssh-agent, and default identity files.
    case automatic
}

struct SSHLocationProfile: Codable, Hashable, Identifiable, Sendable {
    let id: LocationID
    let connectionID: ConnectionID
    let volumeID: VolumeID
    var displayName: String
    var endpoint: SSHEndpoint
    var authentication: SSHAuthenticationPreference
    var rootPath: String

    init(
        id: LocationID = LocationID(rawValue: "ssh:location:\(UUID().uuidString)"),
        connectionID: ConnectionID = ConnectionID(rawValue: "ssh:connection:\(UUID().uuidString)"),
        volumeID: VolumeID? = nil,
        displayName: String,
        endpoint: SSHEndpoint,
        authentication: SSHAuthenticationPreference = .automatic,
        rootPath: String
    ) {
        self.id = id
        self.connectionID = connectionID
        self.volumeID = volumeID
            ?? VolumeID(rawValue: "ssh:volume:\(connectionID.rawValue)")
        self.displayName = displayName
        self.endpoint = endpoint
        self.authentication = authentication
        self.rootPath = ItemRef(volumeID: self.volumeID, path: rootPath).path
    }

    var root: ItemRef {
        ItemRef(volumeID: volumeID, path: rootPath)
    }

    var location: FileLocation {
        FileLocation(id: id, displayName: displayName, root: root)
    }

    var connection: FileConnection {
        FileConnection(
            id: connectionID,
            providerKind: .ssh,
            displayName: displayName
        )
    }
}
