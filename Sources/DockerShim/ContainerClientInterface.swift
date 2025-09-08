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
    /// Volume mounts for the container.
    public var volumeMounts: [DockerVolumeMount] = []
    /// Networks to attach the container to.
    public var attachedNetworks: [String] = []
    
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

// Volume types for Docker API compatibility
public struct DockerVolume: Sendable, Codable {
    public let Name: String
    public let Driver: String
    public let Mountpoint: String
    public let CreatedAt: String
    public let Status: [String: String]?
    public let Labels: [String: String]
    public let Scope: String
    public let Options: [String: String]
    
    public init(name: String, driver: String, mountpoint: String, createdAt: String, labels: [String: String] = [:], options: [String: String] = [:]) {
        self.Name = name
        self.Driver = driver
        self.Mountpoint = mountpoint
        self.CreatedAt = createdAt
        self.Status = nil
        self.Labels = labels
        self.Scope = "local"
        self.Options = options
    }
}

// Network types for Docker API compatibility
public struct DockerNetwork: Sendable, Codable {
    public let Name: String
    public let Id: String
    public let Created: String
    public let Scope: String
    public let Driver: String
    public let EnableIPv6: Bool
    public let IPAM: DockerIPAM
    public let Internal: Bool
    public let Attachable: Bool
    public let Ingress: Bool
    public let ConfigFrom: ConfigFromNetwork?
    public let ConfigOnly: Bool
    public let Containers: [String: DockerNetworkContainer]?
    public let Options: [String: String]
    public let Labels: [String: String]
    
    public init(name: String, id: String, created: String, driver: String = "bridge", labels: [String: String] = [:], options: [String: String] = [:]) {
        self.Name = name
        self.Id = id
        self.Created = created
        self.Scope = "local"
        self.Driver = driver
        self.EnableIPv6 = false
        self.IPAM = DockerIPAM()
        self.Internal = false
        self.Attachable = true
        self.Ingress = false
        self.ConfigFrom = nil
        self.ConfigOnly = false
        self.Containers = [:]
        self.Options = options
        self.Labels = labels
    }
}

public struct DockerIPAM: Sendable, Codable {
    public let Driver: String
    public let Config: [DockerIPAMConfig]
    
    public init() {
        self.Driver = "default"
        self.Config = []
    }
}

public struct DockerIPAMConfig: Sendable, Codable {
    public let Subnet: String?
    public let Gateway: String?
}

public struct ConfigFromNetwork: Sendable, Codable {
    public let Network: String
}

public struct DockerNetworkContainer: Sendable, Codable {
    public let Name: String
    public let EndpointID: String
    public let MacAddress: String
    public let IPv4Address: String
    public let IPv6Address: String
}

// Container stats for observability
public struct DockerContainerStats: Sendable, Codable {
    public let read: String
    public let pids_stats: DockerPidsStats
    public let networks: [String: DockerNetworkStats]
    public let memory_stats: DockerMemoryStats
    public let blkio_stats: DockerBlkioStats
    public let cpu_stats: DockerCPUStats
    public let precpu_stats: DockerCPUStats
    
    public init() {
        self.read = ISO8601DateFormatter().string(from: Date())
        self.pids_stats = DockerPidsStats()
        self.networks = [:]
        self.memory_stats = DockerMemoryStats()
        self.blkio_stats = DockerBlkioStats()
        self.cpu_stats = DockerCPUStats()
        self.precpu_stats = DockerCPUStats()
    }
}

public struct DockerPidsStats: Sendable, Codable {
    public let current: Int
    public let limit: Int
    
    public init() {
        self.current = 0
        self.limit = 0
    }
}

public struct DockerNetworkStats: Sendable, Codable {
    public let rx_bytes: Int
    public let rx_packets: Int
    public let rx_errors: Int
    public let rx_dropped: Int
    public let tx_bytes: Int
    public let tx_packets: Int
    public let tx_errors: Int
    public let tx_dropped: Int
    
    public init() {
        self.rx_bytes = 0
        self.rx_packets = 0
        self.rx_errors = 0
        self.rx_dropped = 0
        self.tx_bytes = 0
        self.tx_packets = 0
        self.tx_errors = 0
        self.tx_dropped = 0
    }
}

public struct DockerMemoryStats: Sendable, Codable {
    public let usage: Int
    public let limit: Int
    public let stats: [String: Int]
    
    public init() {
        self.usage = 0
        self.limit = 0
        self.stats = [:]
    }
}

public struct DockerBlkioStats: Sendable, Codable {
    public let io_service_bytes_recursive: [DockerBlkioStatEntry]
    public let io_serviced_recursive: [DockerBlkioStatEntry]
    
    public init() {
        self.io_service_bytes_recursive = []
        self.io_serviced_recursive = []
    }
}

public struct DockerBlkioStatEntry: Sendable, Codable {
    public let major: Int
    public let minor: Int
    public let op: String
    public let value: Int
}

public struct DockerCPUStats: Sendable, Codable {
    public let cpu_usage: DockerCPUUsage
    public let system_cpu_usage: Int
    public let online_cpus: Int
    
    public init() {
        self.cpu_usage = DockerCPUUsage()
        self.system_cpu_usage = 0
        self.online_cpus = 1
    }
}

public struct DockerCPUUsage: Sendable, Codable {
    public let total_usage: Int
    public let percpu_usage: [Int]
    public let usage_in_kernelmode: Int
    public let usage_in_usermode: Int
    
    public init() {
        self.total_usage = 0
        self.percpu_usage = []
        self.usage_in_kernelmode = 0
        self.usage_in_usermode = 0
    }
}

// Volume mount for enhanced container creation
public struct DockerVolumeMount: Sendable, Codable {
    public let source: String
    public let destination: String
    public let mode: String
    public let type: String
    
    public init(source: String, destination: String, mode: String = "rw", type: String = "volume") {
        self.source = source
        self.destination = destination
        self.mode = mode
        self.type = type
    }
}

// Protocol to abstract the container client interface
protocol ContainerClientInterface: Sendable {
    func list() async throws -> [ContainerSnapshot]
    func create(configuration: ContainerConfiguration, kernel: ClientKernel, options: ContainerCreateOptions) async throws
    func stop(id: String, options: ContainerStopOptions) async throws
    func delete(id: String, force: Bool) async throws
    func logs(id: String) async throws -> [FileHandle]
    
    // Volume operations
    func listVolumes() async throws -> [DockerVolume]
    func createVolume(name: String, driver: String, labels: [String: String], options: [String: String]) async throws -> DockerVolume
    func inspectVolume(name: String) async throws -> DockerVolume
    func deleteVolume(name: String, force: Bool) async throws
    
    // Network operations  
    func listNetworks() async throws -> [DockerNetwork]
    func createNetwork(name: String, driver: String, labels: [String: String], options: [String: String]) async throws -> DockerNetwork
    func inspectNetwork(id: String) async throws -> DockerNetwork
    func deleteNetwork(id: String) async throws
    
    // Observability operations
    func getContainerStats(id: String) async throws -> DockerContainerStats
}

// Mock implementation for the Docker shim
final class MockContainerClient: ContainerClientInterface, @unchecked Sendable {
    private var containers: [ContainerSnapshot] = []
    private var volumes: [DockerVolume] = []
    private var networks: [DockerNetwork] = []
    
    init() {
        // Add default network
        networks.append(DockerNetwork(
            name: "bridge",
            id: "bridge",
            created: ISO8601DateFormatter().string(from: Date()),
            driver: "bridge"
        ))
    }
    
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
    
    // Volume operations
    func listVolumes() async throws -> [DockerVolume] {
        return volumes
    }
    
    func createVolume(name: String, driver: String, labels: [String: String], options: [String: String]) async throws -> DockerVolume {
        // Check if volume already exists
        if volumes.contains(where: { $0.Name == name }) {
            throw NSError(domain: "MockContainerClient", code: 409, userInfo: [NSLocalizedDescriptionKey: "Volume already exists"])
        }
        
        let volume = DockerVolume(
            name: name,
            driver: driver,
            mountpoint: "/var/lib/container/volumes/\(name)/_data",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            labels: labels,
            options: options
        )
        volumes.append(volume)
        return volume
    }
    
    func inspectVolume(name: String) async throws -> DockerVolume {
        guard let volume = volumes.first(where: { $0.Name == name }) else {
            throw NSError(domain: "MockContainerClient", code: 404, userInfo: [NSLocalizedDescriptionKey: "Volume not found"])
        }
        return volume
    }
    
    func deleteVolume(name: String, force: Bool) async throws {
        guard let index = volumes.firstIndex(where: { $0.Name == name }) else {
            throw NSError(domain: "MockContainerClient", code: 404, userInfo: [NSLocalizedDescriptionKey: "Volume not found"])
        }
        
        // In a real implementation, check if volume is in use
        volumes.remove(at: index)
    }
    
    // Network operations
    func listNetworks() async throws -> [DockerNetwork] {
        return networks
    }
    
    func createNetwork(name: String, driver: String, labels: [String: String], options: [String: String]) async throws -> DockerNetwork {
        // Check if network already exists
        if networks.contains(where: { $0.Name == name }) {
            throw NSError(domain: "MockContainerClient", code: 409, userInfo: [NSLocalizedDescriptionKey: "Network already exists"])
        }
        
        let network = DockerNetwork(
            name: name,
            id: UUID().uuidString,
            created: ISO8601DateFormatter().string(from: Date()),
            driver: driver,
            labels: labels,
            options: options
        )
        networks.append(network)
        return network
    }
    
    func inspectNetwork(id: String) async throws -> DockerNetwork {
        guard let network = networks.first(where: { $0.Id == id || $0.Name == id }) else {
            throw NSError(domain: "MockContainerClient", code: 404, userInfo: [NSLocalizedDescriptionKey: "Network not found"])
        }
        return network
    }
    
    func deleteNetwork(id: String) async throws {
        guard let index = networks.firstIndex(where: { $0.Id == id || $0.Name == id }) else {
            throw NSError(domain: "MockContainerClient", code: 404, userInfo: [NSLocalizedDescriptionKey: "Network not found"])
        }
        
        let network = networks[index]
        if network.Name == "bridge" {
            throw NSError(domain: "MockContainerClient", code: 403, userInfo: [NSLocalizedDescriptionKey: "Cannot delete default network"])
        }
        
        networks.remove(at: index)
    }
    
    // Observability operations
    func getContainerStats(id: String) async throws -> DockerContainerStats {
        guard containers.contains(where: { $0.configuration.id == id }) else {
            throw NSError(domain: "MockContainerClient", code: 404, userInfo: [NSLocalizedDescriptionKey: "Container not found"])
        }
        
        return DockerContainerStats()
    }
}

// Factory to create the appropriate client
struct ContainerClientFactory {
    static func create() -> ContainerClientInterface {
        return MockContainerClient()
    }
}