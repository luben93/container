//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation

// Standalone container types for the Docker shim

/// Runtime status for a sandbox or container.
public enum RuntimeStatus: String, CaseIterable, Sendable, Codable {
    /// The object is in an unknown status.
    case unknown
    /// The object is currently stopped.
    case stopped
    /// The object is currently running.
    case running
    /// The object is currently stopping.
    case stopping
}

/// Container configuration
public struct ContainerConfiguration: Sendable, Codable {
    /// Identifier for the container.
    public var id: String
    /// Image used to create the container.
    public var image: ImageDescription
    /// Key/Value labels for the container.
    public var labels: [String: String] = [:]
    /// Ports to publish from container to host.
    public var publishedPorts: [PublishPort] = []
    /// Initial or main process of the container.
    public var initProcess: ProcessConfiguration
    
    public init(id: String, image: ImageDescription, process: ProcessConfiguration) {
        self.id = id
        self.image = image
        self.initProcess = process
    }
}

/// A snapshot of a container along with its configuration and runtime state.
public struct ContainerSnapshot: Codable, Sendable {
    /// The configuration of the container.
    public let configuration: ContainerConfiguration
    /// The runtime status of the container.
    public let status: RuntimeStatus
    /// Network interfaces attached to the sandbox that are provided to the container.
    public let networks: [String] // Simplified - just network names
    
    public init(configuration: ContainerConfiguration, status: RuntimeStatus, networks: [String] = []) {
        self.configuration = configuration
        self.status = status
        self.networks = networks
    }
}

/// Image description
public struct ImageDescription: Sendable, Codable {
    public let reference: String
    
    public init(reference: String) {
        self.reference = reference
    }
}

/// Process configuration
public struct ProcessConfiguration: Sendable, Codable {
    public let path: String
    public let args: [String]
    public let env: [String: String]
    public let workingDirectory: String
    
    public init(path: String, args: [String] = [], env: [String: String] = [:], workingDirectory: String = "/") {
        self.path = path
        self.args = args
        self.env = env
        self.workingDirectory = workingDirectory
    }
}

/// Published port configuration
public struct PublishPort: Sendable, Codable {
    public let containerPort: Int
    public let hostPort: Int
    public let `protocol`: PortProtocol
    
    public enum PortProtocol: String, Sendable, Codable {
        case tcp
        case udp
    }
    
    public init(containerPort: Int, hostPort: Int, protocol: PortProtocol = .tcp) {
        self.containerPort = containerPort
        self.hostPort = hostPort
        self.`protocol` = `protocol`
    }
}

/// Container creation options
public struct ContainerCreateOptions: Sendable, Codable {
    public let autoRemove: Bool
    
    public init(autoRemove: Bool = false) {
        self.autoRemove = autoRemove
    }
}

/// Container stop options
public struct ContainerStopOptions: Sendable, Codable {
    public let timeoutInSeconds: Int
    public let signal: Int32
    
    public init(timeoutInSeconds: Int = 10, signal: Int32 = 15) { // SIGTERM = 15
        self.timeoutInSeconds = timeoutInSeconds
        self.signal = signal
    }
}

/// Mock kernel for compatibility
public struct ClientKernel: Sendable, Codable {
    public let path: String
    public let platform: Platform
    
    public init(path: String, platform: Platform) {
        self.path = path
        self.platform = platform
    }
}

/// Platform information
public struct Platform: Sendable, Codable {
    public let architecture: String
    public let os: String
    
    public static let current = Platform(architecture: "arm64", os: "darwin")
    
    public init(architecture: String, os: String) {
        self.architecture = architecture
        self.os = os
    }
}

/// System platform helper
public struct SystemPlatform: Sendable {
    public static let current = SystemPlatform()
    
    public func ociPlatform() -> Platform {
        return Platform.current
    }
}

// Protocol to abstract the container client interface
protocol ContainerClientInterface: Sendable {
    func list() async throws -> [ContainerSnapshot]
    func create(configuration: ContainerConfiguration, kernel: ClientKernel, options: ContainerCreateOptions) async throws
    func stop(id: String, options: ContainerStopOptions) async throws
    func delete(id: String, force: Bool) async throws
    func logs(id: String) async throws -> [FileHandle]
}

// Mock implementation for the Docker shim
final class MockContainerClient: ContainerClientInterface, @unchecked Sendable {
    private var containers: [ContainerSnapshot] = []
    
    func list() async throws -> [ContainerSnapshot] {
        return containers
    }
    
    func create(configuration: ContainerConfiguration, kernel: ClientKernel, options: ContainerCreateOptions) async throws {
        let snapshot = ContainerSnapshot(
            configuration: configuration,
            status: .stopped,
            networks: []
        )
        containers.append(snapshot)
    }
    
    func stop(id: String, options: ContainerStopOptions) async throws {
        guard let index = containers.firstIndex(where: { $0.configuration.id == id }) else {
            throw NSError(domain: "MockContainerClient", code: 404, userInfo: [NSLocalizedDescriptionKey: "Container not found"])
        }
        
        let config = containers[index].configuration
        containers[index] = ContainerSnapshot(
            configuration: config,
            status: .stopped,
            networks: []
        )
    }
    
    func delete(id: String, force: Bool) async throws {
        guard let index = containers.firstIndex(where: { $0.configuration.id == id }) else {
            throw NSError(domain: "MockContainerClient", code: 404, userInfo: [NSLocalizedDescriptionKey: "Container not found"])
        }
        
        let container = containers[index]
        if container.status == .running && !force {
            throw NSError(domain: "MockContainerClient", code: 409, userInfo: [NSLocalizedDescriptionKey: "Container is running"])
        }
        
        containers.remove(at: index)
    }
    
    func logs(id: String) async throws -> [FileHandle] {
        guard containers.contains(where: { $0.configuration.id == id }) else {
            throw NSError(domain: "MockContainerClient", code: 404, userInfo: [NSLocalizedDescriptionKey: "Container not found"])
        }
        
        // Return empty log handles for now
        return []
    }
}

// Factory to create the appropriate client
struct ContainerClientFactory {
    static func create() -> ContainerClientInterface {
        return MockContainerClient()
    }
}