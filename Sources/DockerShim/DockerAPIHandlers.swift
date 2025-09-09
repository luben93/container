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
import ContainerClient
import ContainerNetworkService
import Containerization
import ContainerizationOCI

// Docker API endpoint implementations
extension DockerAPIHandler {
    
    // GET /containers/json
    func listContainers(query: [String: String]) async throws -> DockerAPIResponse {
        let showAll = query["all"] == "true" || query["all"] == "1"
        do {
            let containers = try await ClientContainer.list()
            let dockerContainers = containers.compactMap { c -> [String: Any]? in
                if !showAll && c.status != .running { return nil }
                return containerToDockerContainer(c)
            }
            return DockerAPIResponse(status: .ok, body: dockerContainers)
        } catch {
            // If backend unavailable, return empty list to keep clients working
            return DockerAPIResponse(status: .ok, body: [])
        }
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
            let (config, kernel) = try await dockerCreateRequestToContainerConfiguration(json, name: containerName)
            let options = ContainerCreateOptions.default
            _ = try await ClientContainer.create(configuration: config, options: options, kernel: kernel)
            
            return DockerAPIResponse(status: .created, body: ["Id": containerName, "Warnings": []])
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
            let container = try await ClientContainer.get(id: id)
            let proc = try await container.bootstrap(stdio: [nil, nil, nil])
            try await proc.start()
            return DockerAPIResponse(status: .noContent)
        } catch {
            return DockerAPIResponse(status: .internalServerError, body: ["message": "Failed to start container: \(error)"])
        }
    }
    
    // POST /containers/{id}/stop
    func stopContainer(id: String, query: [String: String]) async throws -> DockerAPIResponse {
        let timeout = Int(query["t"] ?? "10") ?? 10
        
        do {
            let c = try await ClientContainer.get(id: id)
            let stopOptions = ContainerStopOptions(timeoutInSeconds: Int32(timeout), signal: SIGTERM)
            try await c.stop(opts: stopOptions)
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
            let c = try await ClientContainer.get(id: id)
            try await c.delete(force: force)
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
            let c = try await ClientContainer.get(id: id)
            let logHandles = try await c.logs()
            
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

    // (moved) inspectContainer implemented later using ContainerClient
    
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
        do {
            let volumes = try await ClientVolume.list()
            let mapped: [[String: Any]] = volumes.map { v in
                [
                    "Name": v.name,
                    "Driver": v.driver,
                    "Mountpoint": v.source,
                    "CreatedAt": ISO8601DateFormatter().string(from: v.createdAt),
                    "Labels": v.labels,
                    "Scope": "local",
                    "Options": v.options
                ]
            }
            return DockerAPIResponse(status: .ok, body: ["Volumes": mapped, "Warnings": []])
        } catch {
            return DockerAPIResponse(status: .ok, body: ["Volumes": [], "Warnings": []])
        }
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
            let v = try await ClientVolume.create(name: name, driver: driver, driverOpts: options, labels: labels)
            let body: [String: Any] = [
                "Name": v.name,
                "Driver": v.driver,
                "Mountpoint": v.source,
                "CreatedAt": ISO8601DateFormatter().string(from: v.createdAt),
                "Labels": v.labels,
                "Scope": "local",
                "Options": v.options
            ]
            return DockerAPIResponse(status: .created, body: body)
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
            let v = try await ClientVolume.inspect(name)
            let body: [String: Any] = [
                "Name": v.name,
                "Driver": v.driver,
                "Mountpoint": v.source,
                "CreatedAt": ISO8601DateFormatter().string(from: v.createdAt),
                "Labels": v.labels,
                "Scope": "local",
                "Options": v.options
            ]
            return DockerAPIResponse(status: .ok, body: body)
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
            _ = force
            try await ClientVolume.delete(name: name)
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
        do {
            let nets = try await ClientNetwork.list()
            let mapped: [[String: Any]] = nets.map { state in
                let id: String
                switch state {
                case .created(let cfg): id = cfg.id
                case .running(let cfg, _): id = cfg.id
                }
                return [
                    "Name": id,
                    "Id": id,
                    "Created": ISO8601DateFormatter().string(from: Date()),
                    "Scope": "local",
                    "Driver": "bridge",
                    "EnableIPv6": false,
                    "IPAM": ["Driver": "default", "Config": []],
                    "Internal": false,
                    "Attachable": true,
                    "Ingress": false,
                    "Containers": [:],
                    "Options": [:],
                    "Labels": [:]
                ]
            }
            return DockerAPIResponse(status: .ok, body: mapped)
        } catch {
            return DockerAPIResponse(status: .ok, body: [])
        }
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
        
        let _ = json["Driver"] as? String ?? "bridge"
        let labels = json["Labels"] as? [String: String] ?? [:]
        _ = json["Options"] as? [String: String] ?? [:]
        
        do {
            _ = labels
            let cfg = NetworkConfiguration(id: name, mode: .nat)
            let state = try await ClientNetwork.create(configuration: cfg)
            let id: String = {
                switch state { case .created(let c): return c.id; case .running(let c,_): return c.id }
            }()
            return DockerAPIResponse(status: .created, body: ["Id": id])
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
            let _ = try await ClientNetwork.get(id: id)
            // Minimal network inspect response
            return DockerAPIResponse(status: .ok, body: [
                "Name": id,
                "Id": id,
                "Created": ISO8601DateFormatter().string(from: Date()),
                "Scope": "local",
                "Driver": "bridge",
                "EnableIPv6": false,
                "IPAM": ["Driver": "default", "Config": []],
                "Internal": false,
                "Attachable": true,
                "Ingress": false,
                "Containers": [:],
                "Options": [:],
                "Labels": [:]
            ])
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
            try await ClientNetwork.delete(id: id)
            return DockerAPIResponse(status: .noContent)
        } catch {
            return DockerAPIResponse(
                status: .notFound,
                body: ["message": "Network not found"]
            )
        }
    }

    // POST /networks/{id}/connect
    func connectNetwork(id: String, body: ByteBuffer) async throws -> DockerAPIResponse {
        var mutable = body
        guard let data = mutable.readData(length: mutable.readableBytes),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containerID = json["Container"] as? String else {
            return DockerAPIResponse(status: .badRequest, body: ["message": "Invalid connect payload"])
        }
        _ = (id, containerID)
        return DockerAPIResponse(status: .noContent)
    }
    
    // POST /networks/{id}/disconnect
    func disconnectNetwork(id: String, body: ByteBuffer) async throws -> DockerAPIResponse {
        var mutable = body
        guard let data = mutable.readData(length: mutable.readableBytes),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containerID = json["Container"] as? String else {
            return DockerAPIResponse(status: .badRequest, body: ["message": "Invalid disconnect payload"])
        }
        _ = (id, containerID)
        return DockerAPIResponse(status: .noContent)
    }
    
    // (removed duplicates) connect/disconnect implemented above as no-ops
    
    // GET /containers/{id}/json
    func inspectContainer(id: String) async throws -> DockerAPIResponse {
        let containers = try await ClientContainer.list()
        guard let container = containers.first(where: { $0.id == id }) else {
            return DockerAPIResponse(
                status: .notFound,
                body: ["message": "No such container: \(id)"]
            )
        }
        
        let dockerContainer = containerToDockerContainer(container)
        return DockerAPIResponse(status: .ok, body: dockerContainer)
    }
    
    // MARK: - Observability endpoints
    
    // GET /containers/{id}/stats
    func getContainerStats(id: String, query: [String: String]) async throws -> DockerAPIResponse {
        // Not implemented in runtime yet
        return DockerAPIResponse(status: .notImplemented, body: ["message": "Container stats not implemented"])
    }
    
    // GET /containers/{id}/top
    func getContainerProcesses(id: String, query: [String: String]) async throws -> DockerAPIResponse {
        // Not implemented yet
        let containers = try? await ClientContainer.list()
        guard (containers ?? []).contains(where: { $0.id == id }) else {
            return DockerAPIResponse(status: .notFound, body: ["message": "Container not found"])
        }
        return DockerAPIResponse(status: .notImplemented, body: ["message": "Top not implemented"])
    }
    
    // GET /events
    func getEvents(query: [String: String]) async throws -> DockerAPIResponse {
        return DockerAPIResponse(status: .notImplemented, body: ["message": "Events not implemented"])
    }

    // POST /images/create
    func imagesCreate(head: HTTPRequestHead, query: [String: String]) async throws -> DockerAPIResponse {
        guard let fromImage = query["fromImage"] ?? query["fromSrc"] else {
            return DockerAPIResponse(status: .badRequest, body: ["message": "fromImage is required"])
        }
        let tag = query["tag"]
        let ref = tag.map { "\(fromImage):\($0)" } ?? fromImage
        do {
            _ = try await ClientImage.pull(reference: ref)
            // Docker expects newline-delimited JSON status messages; a single entry suffices
            let msg = ["status": "Downloaded or up to date", "id": ref]
            return DockerAPIResponse(status: .ok, body: [msg])
        } catch {
            return DockerAPIResponse(status: .internalServerError, body: ["message": "Failed to pull image: \(error)"])
        }
    }

    // GET /images/json
    func imagesList() async throws -> DockerAPIResponse {
        do {
            let images = try await ClientImage.list()
            let mapped = images.map { img in
                [
                    "Id": img.digest,
                    "RepoTags": [img.reference],
                    "Created": 0,
                    "Size": 0,
                    "VirtualSize": 0,
                    "Labels": [:] as [String: String]
                ] as [String: Any]
            }
            return DockerAPIResponse(status: .ok, body: mapped)
        } catch {
            return DockerAPIResponse(status: .ok, body: [])
        }
    }
}

// Helper functions for data conversion
extension DockerAPIHandler {

    private func containerToDockerContainer(_ container: ClientContainer) -> [String: Any] {
        return [
            "Id": container.id,
            "Names": ["/\(container.id)"],
            "Image": container.configuration.image.reference,
            "ImageID": "sha256:unknown", // Would need image service integration
            "Command": container.configuration.initProcess.executable,
            "Created": 0, // Would need creation timestamp
            "Ports": container.configuration.publishedPorts.map { port in
                [
                    "IP": "0.0.0.0",
                    "PrivatePort": port.containerPort,
                    "PublicPort": port.hostPort,
                    "Type": port.proto.rawValue
                ]
            },
            "Labels": container.configuration.labels,
            "State": runtimeStatusToDockerState(container.status),
            "Status": runtimeStatusToDockerStatus(container.status),
            "HostConfig": [
                "NetworkMode": container.configuration.networks.first?.network ?? ClientNetwork.defaultNetworkName,
                "Binds": container.configuration.mounts.map { fs in
                    "\(fs.source):\(fs.destination):\(fs.options.joined(separator: ","))"
                }
            ],
            "NetworkSettings": [
                "Networks": Dictionary(uniqueKeysWithValues: (container.configuration.networks.isEmpty ? [ClientNetwork.defaultNetworkName] : container.configuration.networks.map { $0.network }).map { networkName in
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
            "Mounts": container.configuration.mounts.map { m in
                [
                    "Type": (m.isVolume ? "volume" : (m.isTmpfs ? "tmpfs" : "bind")),
                    "Source": m.source,
                    "Destination": m.destination,
                    "Mode": m.options.joined(separator: ","),
                    "RW": !m.options.contains("ro"),
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
    
    private func dockerCreateRequestToContainerConfiguration(_ json: [String: Any], name: String) async throws -> (ContainerConfiguration, Kernel) {
        guard let imageName = json["Image"] as? String else {
            throw NSError(domain: "DockerShim", code: 400, userInfo: [NSLocalizedDescriptionKey: "Image field is required"])
        }
        // Resolve or pull image to get ImageDescription
        let image: ImageDescription
        if let img = try? await ClientImage.get(reference: imageName) {
            image = img.description
        } else {
            let pulled = try await ClientImage.pull(reference: imageName)
            image = pulled.description
        }
        
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
            executable: processPath,
            arguments: processArgs,
            environment: extractEnvironment(from: json),
            workingDirectory: json["WorkingDir"] as? String ?? "/"
        )
        
        var config = ContainerConfiguration(id: name, image: image, process: processConfig)
        
        // Extract labels
        if let labels = json["Labels"] as? [String: String] {
            config.labels = labels
        }
        
        // Extract exposed ports
        config.publishedPorts = extractPublishedPorts(fullJSON: json)
        
        config.mounts = try await extractMounts(from: json)
        
        // Extract network attachments
        var networks: [String] = []
        if let hostConfig = json["HostConfig"] as? [String: Any],
           let networkMode = hostConfig["NetworkMode"] as? String,
           !networkMode.isEmpty {
            if networkMode != "default" && networkMode != "bridge" {
                networks.append(networkMode)
            }
        }
        if let networkingConfig = json["NetworkingConfig"] as? [String: Any],
           let endpoints = networkingConfig["EndpointsConfig"] as? [String: Any] {
            for (netName, _) in endpoints { networks.append(netName) }
        }
        if networks.isEmpty { networks = [ClientNetwork.defaultNetworkName] }
        config.networks = unique(networks).map { AttachmentConfiguration(network: $0, options: AttachmentOptions(hostname: name)) }
        
        // Get default kernel for current platform
        let kernel = try await ClientKernel.getDefaultKernel(for: .current)
        return (config, kernel)
    }
    
    private func extractEnvironment(from json: [String: Any]) -> [String] {
        guard let env = json["Env"] as? [String] else { return [] }
        return env
    }

    // Small helper to unique values while preserving order
    private func unique<T: Hashable>(_ array: [T]) -> [T] {
        var seen = Set<T>()
        var result: [T] = []
        for v in array where !seen.contains(v) {
            seen.insert(v)
            result.append(v)
        }
        return result
    }
    
    private func extractPublishedPorts(fullJSON: [String: Any]) -> [PublishPort] {
        var ports: [PublishPort] = []
        if let hostConfig = fullJSON["HostConfig"] as? [String: Any], let bindings = hostConfig["PortBindings"] as? [String: Any] {
            for (key, value) in bindings {
                let parts = key.split(separator: "/")
                guard let cport = Int(parts[0]) else { continue }
                let proto = parts.count > 1 && parts[1].lowercased() == "udp" ? PublishProtocol.udp : PublishProtocol.tcp
                if let arr = value as? [[String: Any]] {
                    for bind in arr {
                        let hostPort = Int((bind["HostPort"] as? String) ?? "") ?? cport
                        let hostIP = (bind["HostIp"] as? String) ?? "0.0.0.0"
                        ports.append(PublishPort(hostAddress: hostIP, hostPort: hostPort, containerPort: cport, proto: proto))
                    }
                }
            }
            return ports
        }
        if let exposedPorts = fullJSON["ExposedPorts"] as? [String: Any] {
            for (portSpec, _) in exposedPorts {
                let parts = portSpec.split(separator: "/")
                if let portNumber = Int(parts[0]) {
                    let proto: PublishProtocol = parts.count > 1 && parts[1] == "udp" ? .udp : .tcp
                    ports.append(PublishPort(hostAddress: "0.0.0.0", hostPort: portNumber, containerPort: portNumber, proto: proto))
                }
            }
        }
        return ports
    }
    
    private func extractMounts(from json: [String: Any]) async throws -> [Filesystem] {
        var mounts: [Filesystem] = []
        if let volumes = json["Volumes"] as? [String: Any] {
            for (destination, _) in volumes {
                mounts.append(Filesystem.tmpfs(destination: destination, options: ["rw"]))
            }
        }
        func addVolume(name: String, dest: String, mode: String) async throws {
            let v = try await ClientVolume.inspect(name)
            mounts.append(Filesystem.volume(name: v.name, format: v.format, source: v.source, destination: dest, options: [mode]))
        }
        func addBind(src: String, dest: String, mode: String) {
            mounts.append(Filesystem.virtiofs(source: src, destination: dest, options: [mode]))
        }
        if let hostConfig = json["HostConfig"] as? [String: Any], let binds = hostConfig["Binds"] as? [String] {
            for bind in binds {
                let parts = bind.split(separator: ":")
                guard parts.count >= 2 else { continue }
                let src = String(parts[0])
                let dest = String(parts[1])
                let mode = parts.count > 2 ? String(parts[2]) : "rw"
                if src.hasPrefix("/") { addBind(src: src, dest: dest, mode: mode) } else { try await addVolume(name: src, dest: dest, mode: mode) }
            }
        }
        if let hostConfig = json["HostConfig"] as? [String: Any], let mountsArray = hostConfig["Mounts"] as? [[String: Any]] {
            for m in mountsArray {
                guard let target = m["Target"] as? String else { continue }
                let src = (m["Source"] as? String) ?? ""
                let type = (m["Type"] as? String) ?? (src.hasPrefix("/") ? "bind" : "volume")
                let readOnly = (m["ReadOnly"] as? Bool) ?? false
                let mode = readOnly ? "ro" : "rw"
                if type == "bind" { addBind(src: src, dest: target, mode: mode) } else { try await addVolume(name: src, dest: target, mode: mode) }
            }
        }
        return mounts
    }
}
