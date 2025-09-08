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
import NIOHTTP1
import NIOFoundationCompat
import NIOCore

// Docker API endpoint implementations
extension DockerAPIHandler {
    
    // GET /containers/json
    func listContainers(query: [String: String]) async throws -> DockerAPIResponse {
        let showAll = query["all"] == "true" || query["all"] == "1"
        
        let containers = try await self.containerClient.list()
        let dockerContainers = containers.compactMap { container -> [String: Any]? in
            // Filter based on showAll flag
            if !showAll && container.status != RuntimeStatus.running {
                return nil
            }
            
            return containerSnapshotToDockerContainer(container)
        }
        
        return DockerAPIResponse(status: .ok, body: dockerContainers)
    }
    
    // POST /containers/create
    func createContainer(body: ByteBuffer, query: [String: String]) async throws -> DockerAPIResponse {
        var mutableBody = body
        guard let bodyData = mutableBody.readData(length: mutableBody.readableBytes),
              let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return DockerAPIResponse(
                status: .badRequest,
                body: ["message": "Invalid JSON in request body"]
            )
        }
        
        // Extract container name from query parameter
        let containerName = query["name"] ?? UUID().uuidString
        
        do {
            let config = try dockerCreateRequestToContainerConfiguration(json, name: containerName)
            let options = ContainerCreateOptions() // Use defaults for now
            
            // For now, we'll use a mock kernel since we can't access the actual kernel service
            // In a real implementation, this would get the default kernel
            let mockKernel = getMockKernel()
            
            try await self.containerClient.create(configuration: config, kernel: mockKernel, options: options)
            
            return DockerAPIResponse(
                status: .created,
                body: [
                    "Id": containerName,
                    "Warnings": []
                ]
            )
        } catch {
            return DockerAPIResponse(
                status: .badRequest,
                body: ["message": "Failed to create container: \(error)"]
            )
        }
    }
    
    // POST /containers/{id}/start
    func startContainer(id: String) async throws -> DockerAPIResponse {
        do {
            // The existing API doesn't have a direct start method, but containers
            // are typically started automatically when created. For compatibility,
            // we'll just check if the container exists and is startable.
            let containers = try await self.containerClient.list()
            guard let container = containers.first(where: { $0.configuration.id == id }) else {
                return DockerAPIResponse(
                    status: .notFound,
                    body: ["message": "No such container: \(id)"]
                )
            }
            
            if container.status == RuntimeStatus.running {
                return DockerAPIResponse(
                    status: .notModified,
                    body: ["message": "Container already started"]
                )
            }
            
            // For now, we'll just return success since the actual start logic
            // would require integration with the runtime plugins
            return DockerAPIResponse(status: .noContent)
            
        } catch {
            return DockerAPIResponse(
                status: .internalServerError,
                body: ["message": "Failed to start container: \(error)"]
            )
        }
    }
    
    // POST /containers/{id}/stop
    func stopContainer(id: String, query: [String: String]) async throws -> DockerAPIResponse {
        let timeout = Int(query["t"] ?? "10") ?? 10
        
        do {
            let stopOptions = ContainerStopOptions(
                timeoutInSeconds: timeout,
                signal: SIGTERM
            )
            
            try await self.containerClient.stop(id: id, options: stopOptions)
            return DockerAPIResponse(status: .noContent)
            
        } catch {
            return DockerAPIResponse(
                status: .notFound,
                body: ["message": "No such container: \(id)"]
            )
        }
    }
    
    // DELETE /containers/{id}
    func removeContainer(id: String, query: [String: String]) async throws -> DockerAPIResponse {
        let force = query["force"] == "true" || query["force"] == "1"
        
        do {
            try await self.containerClient.delete(id: id, force: force)
            return DockerAPIResponse(status: .noContent)
            
        } catch {
            return DockerAPIResponse(
                status: .notFound,
                body: ["message": "No such container: \(id)"]
            )
        }
    }
    
    // GET /containers/{id}/logs
    func getContainerLogs(id: String, query: [String: String]) async throws -> DockerAPIResponse {
        do {
            let logHandles = try await self.containerClient.logs(id: id)
            
            // For simplicity, we'll read the logs and return them as text
            // In a full implementation, this would stream the logs properly
            var logContent = ""
            
            for handle in logHandles {
                let data = handle.readDataToEndOfFile()
                if let content = String(data: data, encoding: .utf8) {
                    logContent += content
                }
            }
            
            return DockerAPIResponse(
                status: .ok,
                body: logContent,
                contentType: "text/plain"
            )
            
        } catch {
            return DockerAPIResponse(
                status: .notFound,
                body: ["message": "No such container: \(id)"]
            )
        }
    }
    
    // GET /version
    func getVersion() -> DockerAPIResponse {
        return DockerAPIResponse(
            status: .ok,
            body: [
                "Version": "24.0.0", // Emulate Docker version for compatibility
                "ApiVersion": "1.43",
                "MinAPIVersion": "1.12",
                "GitCommit": "unknown",
                "GoVersion": "N/A",
                "Os": "darwin",
                "Arch": "arm64",
                "KernelVersion": "N/A",
                "BuildTime": "2025-01-01T00:00:00.000000000+00:00",
                "Components": [
                    [
                        "Name": "Apple Container Shim",
                        "Version": "1.0.0",
                        "Details": [
                            "ApiVersion": "1.43",
                            "Arch": "arm64",
                            "BuildTime": "2025-01-01T00:00:00.000000000+00:00",
                            "Experimental": "false",
                            "GitCommit": "unknown",
                            "GoVersion": "N/A",
                            "KernelVersion": "N/A",
                            "MinAPIVersion": "1.12",
                            "Os": "darwin"
                        ]
                    ]
                ]
            ]
        )
    }
    
    // MARK: - Volume endpoints
    
    // GET /volumes
    func listVolumes(query: [String: String]) async throws -> DockerAPIResponse {
        let volumes = try await self.containerClient.listVolumes()
        
        return DockerAPIResponse(
            status: .ok,
            body: [
                "Volumes": volumes,
                "Warnings": []
            ]
        )
    }
    
    // POST /volumes/create
    func createVolume(body: ByteBuffer) async throws -> DockerAPIResponse {
        var mutableBody = body
        guard let bodyData = mutableBody.readData(length: mutableBody.readableBytes),
              let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return DockerAPIResponse(
                status: .badRequest,
                body: ["message": "Invalid JSON in request body"]
            )
        }
        
        guard let name = json["Name"] as? String else {
            return DockerAPIResponse(
                status: .badRequest,
                body: ["message": "Volume name is required"]
            )
        }
        
        let driver = json["Driver"] as? String ?? "local"
        let labels = json["Labels"] as? [String: String] ?? [:]
        let options = json["DriverOpts"] as? [String: String] ?? [:]
        
        do {
            let volume = try await self.containerClient.createVolume(
                name: name,
                driver: driver,
                labels: labels,
                options: options
            )
            return DockerAPIResponse(status: .created, body: volume)
        } catch {
            return DockerAPIResponse(
                status: .conflict,
                body: ["message": "Volume already exists"]
            )
        }
    }
    
    // GET /volumes/{name}
    func inspectVolume(name: String) async throws -> DockerAPIResponse {
        do {
            let volume = try await self.containerClient.inspectVolume(name: name)
            return DockerAPIResponse(status: .ok, body: volume)
        } catch {
            return DockerAPIResponse(
                status: .notFound,
                body: ["message": "Volume not found"]
            )
        }
    }
    
    // DELETE /volumes/{name}
    func removeVolume(name: String, query: [String: String]) async throws -> DockerAPIResponse {
        let force = query["force"] == "true" || query["force"] == "1"
        
        do {
            try await self.containerClient.deleteVolume(name: name, force: force)
            return DockerAPIResponse(status: .noContent)
        } catch {
            return DockerAPIResponse(
                status: .notFound,
                body: ["message": "Volume not found"]
            )
        }
    }
    
    // MARK: - Network endpoints
    
    // GET /networks
    func listNetworks(query: [String: String]) async throws -> DockerAPIResponse {
        let networks = try await self.containerClient.listNetworks()
        return DockerAPIResponse(status: .ok, body: networks)
    }
    
    // POST /networks/create
    func createNetwork(body: ByteBuffer) async throws -> DockerAPIResponse {
        var mutableBody = body
        guard let bodyData = mutableBody.readData(length: mutableBody.readableBytes),
              let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return DockerAPIResponse(
                status: .badRequest,
                body: ["message": "Invalid JSON in request body"]
            )
        }
        
        guard let name = json["Name"] as? String else {
            return DockerAPIResponse(
                status: .badRequest,
                body: ["message": "Network name is required"]
            )
        }
        
        let driver = json["Driver"] as? String ?? "bridge"
        let labels = json["Labels"] as? [String: String] ?? [:]
        let options = json["Options"] as? [String: String] ?? [:]
        
        do {
            let network = try await self.containerClient.createNetwork(
                name: name,
                driver: driver,
                labels: labels,
                options: options
            )
            return DockerAPIResponse(
                status: .created,
                body: ["Id": network.Id]
            )
        } catch {
            return DockerAPIResponse(
                status: .conflict,
                body: ["message": "Network already exists"]
            )
        }
    }
    
    // GET /networks/{id}
    func inspectNetwork(id: String) async throws -> DockerAPIResponse {
        do {
            let network = try await self.containerClient.inspectNetwork(id: id)
            return DockerAPIResponse(status: .ok, body: network)
        } catch {
            return DockerAPIResponse(
                status: .notFound,
                body: ["message": "Network not found"]
            )
        }
    }
    
    // DELETE /networks/{id}
    func removeNetwork(id: String) async throws -> DockerAPIResponse {
        do {
            try await self.containerClient.deleteNetwork(id: id)
            return DockerAPIResponse(status: .noContent)
        } catch {
            return DockerAPIResponse(
                status: .notFound,
                body: ["message": "Network not found"]
            )
        }
    }
    
    // MARK: - Observability endpoints
    
    // GET /containers/{id}/stats
    func getContainerStats(id: String, query: [String: String]) async throws -> DockerAPIResponse {
        let stream = query["stream"] != "false" && query["stream"] != "0"
        
        do {
            let stats = try await self.containerClient.getContainerStats(id: id)
            
            // For streaming, we'd typically keep the connection open
            // For now, just return a single stats response
            return DockerAPIResponse(
                status: .ok,
                body: stats,
                contentType: "application/json"
            )
        } catch {
            return DockerAPIResponse(
                status: .notFound,
                body: ["message": "Container not found"]
            )
        }
    }
    
    // GET /containers/{id}/top
    func getContainerProcesses(id: String, query: [String: String]) async throws -> DockerAPIResponse {
        // Check if container exists
        let containers = try await self.containerClient.list()
        guard containers.contains(where: { $0.configuration.id == id }) else {
            return DockerAPIResponse(
                status: .notFound,
                body: ["message": "Container not found"]
            )
        }
        
        // Mock process list - in real implementation would query actual processes
        return DockerAPIResponse(
            status: .ok,
            body: [
                "Titles": ["UID", "PID", "PPID", "C", "STIME", "TTY", "TIME", "CMD"],
                "Processes": [
                    ["root", "1", "0", "0", "00:00", "?", "00:00:00", "/bin/sh"]
                ]
            ]
        )
    }
    
    // GET /events
    func getEvents(query: [String: String]) async throws -> DockerAPIResponse {
        // Mock events endpoint - in real implementation would stream events
        return DockerAPIResponse(
            status: .ok,
            body: [],
            contentType: "application/json"
        )
    }
}

// Helper functions for data conversion
extension DockerAPIHandler {
    
    private func containerSnapshotToDockerContainer(_ container: ContainerSnapshot) -> [String: Any] {
        return [
            "Id": container.configuration.id,
            "Names": ["/\(container.configuration.id)"],
            "Image": container.configuration.image.reference,
            "ImageID": "sha256:unknown", // Would need image service integration
            "Command": container.configuration.initProcess.path,
            "Created": 0, // Would need creation timestamp
            "Ports": container.configuration.publishedPorts.map { port in
                [
                    "IP": "0.0.0.0",
                    "PrivatePort": port.containerPort,
                    "PublicPort": port.hostPort,
                    "Type": port.protocol.rawValue
                ]
            },
            "Labels": container.configuration.labels,
            "State": runtimeStatusToDockerState(container.status),
            "Status": runtimeStatusToDockerStatus(container.status),
            "HostConfig": [
                "NetworkMode": container.configuration.attachedNetworks.first ?? "bridge",
                "Binds": container.configuration.volumeMounts.map { mount in
                    "\(mount.source):\(mount.destination):\(mount.mode)"
                }
            ],
            "NetworkSettings": [
                "Networks": Dictionary(uniqueKeysWithValues: container.configuration.attachedNetworks.map { networkName in
                    (networkName, [
                        "IPAMConfig": nil as Any?,
                        "Links": nil as Any?,
                        "Aliases": nil as Any?,
                        "NetworkID": "network-\(networkName)",
                        "EndpointID": "",
                        "Gateway": "172.17.0.1",
                        "IPAddress": "",
                        "IPPrefixLen": 16,
                        "IPv6Gateway": "",
                        "GlobalIPv6Address": "",
                        "GlobalIPv6PrefixLen": 0,
                        "MacAddress": ""
                    ])
                })
            ],
            "Mounts": container.configuration.volumeMounts.map { mount in
                [
                    "Type": mount.type,
                    "Source": mount.source,
                    "Destination": mount.destination,
                    "Mode": mount.mode,
                    "RW": mount.mode.contains("rw"),
                    "Propagation": ""
                ]
            }
        ]
    }
    
    private func runtimeStatusToDockerState(_ status: RuntimeStatus) -> String {
        switch status {
        case .running:
            return "running"
        case .stopped:
            return "exited"
        case .stopping:
            return "exited"
        case .unknown:
            return "dead"
        }
    }
    
    private func runtimeStatusToDockerStatus(_ status: RuntimeStatus) -> String {
        switch status {
        case .running:
            return "Up"
        case .stopped:
            return "Exited"
        case .stopping:
            return "Exiting"
        case .unknown:
            return "Dead"
        }
    }
    
    private func dockerCreateRequestToContainerConfiguration(_ json: [String: Any], name: String) throws -> ContainerConfiguration {
        guard let imageName = json["Image"] as? String else {
            throw NSError(domain: "DockerShim", code: 400, userInfo: [NSLocalizedDescriptionKey: "Image field is required"])
        }
        
        let image = ImageDescription(reference: imageName)
        
        // Extract command and args
        var processPath = "/bin/sh"
        var processArgs: [String] = []
        
        if let cmd = json["Cmd"] as? [String], !cmd.isEmpty {
            processPath = cmd[0]
            processArgs = Array(cmd.dropFirst())
        }
        
        // Extract entrypoint
        if let entrypoint = json["Entrypoint"] as? [String], !entrypoint.isEmpty {
            processPath = entrypoint[0]
            if let cmd = json["Cmd"] as? [String] {
                processArgs = Array(entrypoint.dropFirst()) + cmd
            } else {
                processArgs = Array(entrypoint.dropFirst())
            }
        }
        
        let processConfig = ProcessConfiguration(
            path: processPath,
            args: processArgs,
            env: extractEnvironment(from: json),
            workingDirectory: json["WorkingDir"] as? String ?? "/"
        )
        
        var config = ContainerConfiguration(
            id: name,
            image: image,
            process: processConfig
        )
        
        // Extract labels
        if let labels = json["Labels"] as? [String: String] {
            config.labels = labels
        }
        
        // Extract exposed ports
        if let exposedPorts = json["ExposedPorts"] as? [String: Any] {
            config.publishedPorts = extractPublishedPorts(from: exposedPorts)
        }
        
        // Extract volume mounts
        config.volumeMounts = extractVolumeMounts(from: json)
        
        // Extract network mode
        if let hostConfig = json["HostConfig"] as? [String: Any],
           let networkMode = hostConfig["NetworkMode"] as? String {
            if networkMode != "default" && networkMode != "bridge" {
                config.attachedNetworks = [networkMode]
            } else {
                config.attachedNetworks = ["bridge"] // Default network
            }
        } else {
            config.attachedNetworks = ["bridge"] // Default network
        }
        
        return config
    }
    
    private func extractEnvironment(from json: [String: Any]) -> [String: String] {
        guard let env = json["Env"] as? [String] else {
            return [:]
        }
        
        var environment: [String: String] = [:]
        for envVar in env {
            let parts = envVar.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                environment[String(parts[0])] = String(parts[1])
            }
        }
        return environment
    }
    
    private func extractPublishedPorts(from exposedPorts: [String: Any]) -> [PublishPort] {
        var ports: [PublishPort] = []
        
        for (portSpec, _) in exposedPorts {
            let parts = portSpec.split(separator: "/")
            if let portNumber = Int(parts[0]) {
                let portProtocol: PublishPort.PortProtocol = parts.count > 1 && parts[1] == "udp" ? .udp : .tcp
                ports.append(PublishPort(
                    containerPort: portNumber,
                    hostPort: portNumber, // Use same port for simplicity
                    protocol: portProtocol
                ))
            }
        }
        
        return ports
    }
    
    private func extractVolumeMounts(from json: [String: Any]) -> [DockerVolumeMount] {
        var mounts: [DockerVolumeMount] = []
        
        // Extract from Volumes field
        if let volumes = json["Volumes"] as? [String: Any] {
            for (destination, _) in volumes {
                mounts.append(DockerVolumeMount(
                    source: "",  // Anonymous volume
                    destination: destination,
                    mode: "rw",
                    type: "volume"
                ))
            }
        }
        
        // Extract from HostConfig.Binds
        if let hostConfig = json["HostConfig"] as? [String: Any],
           let binds = hostConfig["Binds"] as? [String] {
            for bind in binds {
                let parts = bind.split(separator: ":")
                if parts.count >= 2 {
                    let source = String(parts[0])
                    let destination = String(parts[1])
                    let mode = parts.count > 2 ? String(parts[2]) : "rw"
                    
                    let mountType = source.hasPrefix("/") ? "bind" : "volume"
                    mounts.append(DockerVolumeMount(
                        source: source,
                        destination: destination,
                        mode: mode,
                        type: mountType
                    ))
                }
            }
        }
        
        // Extract from HostConfig.Mounts
        if let hostConfig = json["HostConfig"] as? [String: Any],
           let mountsArray = hostConfig["Mounts"] as? [[String: Any]] {
            for mountDict in mountsArray {
                if let source = mountDict["Source"] as? String,
                   let target = mountDict["Target"] as? String {
                    let type = mountDict["Type"] as? String ?? "volume"
                    let readOnly = mountDict["ReadOnly"] as? Bool ?? false
                    let mode = readOnly ? "ro" : "rw"
                    
                    mounts.append(DockerVolumeMount(
                        source: source,
                        destination: target,
                        mode: mode,
                        type: type
                    ))
                }
            }
        }
        
        return mounts
    }
    
    private func getMockKernel() -> ClientKernel {
        // This is a placeholder - in a real implementation, this would
        // fetch the actual kernel from the kernel service
        return ClientKernel(
            path: "/usr/local/share/container/kernel",
            platform: SystemPlatform.current.ociPlatform()
        )
    }
}