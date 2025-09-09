
import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOFoundationCompat
import ContainerClient

final class DockerAPIServer: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let logger: Logger
    
    init(host: String, port: Int, logger: Logger) {
        self.host = host
        self.port = port
        self.logger = logger
    }

    func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    HTTPResponseEncoder(),
                    ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)),
                    DockerAPIHandler(logger: self.logger)
                ])
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        let channel = try await bootstrap.bind(host: host, port: port).get()
        logger.info("Docker API shim listening", metadata: [
            "address": "\(channel.localAddress!)"
        ])

        do {
            try await channel.closeFuture.get()
        } catch {
            logger.error("Server error: \(error)")
        }
        
        do {
            try await group.shutdownGracefully()
        } catch {
            logger.warning("Failed to shutdown event loop group gracefully: \(error)")
        }
    }
}

final class DockerAPIHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let logger: Logger
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()

    init(logger: Logger) {
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = unwrapInboundIn(data)

        switch reqPart {
        case .head(let head):
            self.head = head
            self.body.clear()
            
        case .body(let chunk):
            self.body.writeImmutableBuffer(chunk)
            
        case .end:
            guard let head = self.head else {
                sendError(context: context, status: .badRequest, message: "Invalid request")
                return
            }
            
            let currentBody = self.body
            handleRequest(context: context, head: head, body: currentBody)
        }
    }

    private func handleRequest(context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer) {
        logger.debug("Handling request", metadata: [
            "method": "\(head.method)",
            "uri": "\(head.uri)"
        ])

        let unsafeSelf = UnsafeSendable(self)
        let unsafeChannel = UnsafeSendable(context.channel)
        let headCopy = head
        let bodyCopy = body
        Task {
            let response: DockerAPIResponse
            do {
                response = try await unsafeSelf.value.routeRequest(head: headCopy, body: bodyCopy)
            } catch {
                unsafeSelf.value.logger.error("Request failed", metadata: ["error": "\(error)"])
                response = DockerAPIResponse(
                    status: .internalServerError,
                    body: ["message": "Internal server error"]
                )
            }
            unsafeChannel.value.eventLoop.execute {
                unsafeChannel.value.pipeline.context(handlerType: DockerAPIHandler.self).whenSuccess { handlerContext in
                    unsafeSelf.value.sendResponse(context: handlerContext, response: response)
                }
            }
        }
    }

    private func routeRequest(head: HTTPRequestHead, body: ByteBuffer) async throws -> DockerAPIResponse {
        // Extract path without query and normalize components
        let rawPath = String(head.uri.split(separator: "?", maxSplits: 1).first ?? Substring(head.uri))
        var components = rawPath.split(separator: "/").map(String.init)
        // Drop optional version prefix like /v1.43
        if let first = components.first, first.hasPrefix("v"), first.dropFirst().contains(".") {
            components.removeFirst()
        }
        
        // Log the request for debugging
        print("🔍 Docker API Request: \(head.method) \(head.uri) -> components: \(components)")
        
        switch (head.method, components) {
        // Container endpoints
        case (.GET, ["containers", "json"]):
            return try await listContainers(query: parseQuery(from: head.uri))
            
        case (.POST, ["containers", "create"]):
            return try await createContainer(body: body, query: parseQuery(from: head.uri))
            
        case (.POST, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "containers" && pathComponents[2] == "start":
            let id = pathComponents[1]
            return try await startContainer(id: id)
            
        case (.POST, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "containers" && pathComponents[2] == "stop":
            let id = pathComponents[1]
            return try await stopContainer(id: id, query: parseQuery(from: head.uri))
            
        case (.POST, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "containers" && pathComponents[2] == "restart":
            let id = pathComponents[1]
            return try await restartContainer(id: id, query: parseQuery(from: head.uri))
            
        case (.POST, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "containers" && pathComponents[2] == "kill":
            let id = pathComponents[1]
            return try await killContainer(id: id, query: parseQuery(from: head.uri))
            
        case (.POST, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "containers" && pathComponents[2] == "pause":
            let id = pathComponents[1]
            return try await pauseContainer(id: id)
            
        case (.POST, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "containers" && pathComponents[2] == "unpause":
            let id = pathComponents[1]
            return try await unpauseContainer(id: id)
            
        case (.POST, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "containers" && pathComponents[2] == "wait":
            let id = pathComponents[1]
            return try await waitContainer(id: id)
            
        case (.DELETE, let pathComponents) where pathComponents.count == 2 && pathComponents[0] == "containers":
            let id = pathComponents[1]
            return try await removeContainer(id: id, query: parseQuery(from: head.uri))
            
        case (.GET, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "containers" && pathComponents[2] == "logs":
            let id = pathComponents[1]
            return try await getContainerLogs(id: id, query: parseQuery(from: head.uri))
            
        case (.GET, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "containers" && pathComponents[2] == "stats":
            let id = pathComponents[1]
            return try await getContainerStats(id: id, query: parseQuery(from: head.uri))
            
        case (.GET, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "containers" && pathComponents[2] == "top":
            let id = pathComponents[1]
            return try await getContainerProcesses(id: id, query: parseQuery(from: head.uri))
            
        // Volume endpoints  
        case (.GET, ["volumes"]):
            return try await listVolumes(query: parseQuery(from: head.uri))
            
        case (.POST, ["volumes", "create"]):
            return try await createVolume(body: body)
            
        case (.GET, let pathComponents) where pathComponents.count == 2 && pathComponents[0] == "volumes":
            let name = pathComponents[1]
            return try await inspectVolume(name: name)
            
        case (.DELETE, let pathComponents) where pathComponents.count == 2 && pathComponents[0] == "volumes":
            let name = pathComponents[1]
            return try await removeVolume(name: name, query: parseQuery(from: head.uri))
        
        case (.POST, ["volumes", "prune"]):
            return try await pruneVolumes(query: parseQuery(from: head.uri))
            
        // Network endpoints
        case (.GET, ["networks"]):
            return try await listNetworks(query: parseQuery(from: head.uri))
        
        case (.POST, ["networks", "create"]):
            return try await createNetwork(body: body)
        
        case (.GET, let pathComponents) where pathComponents.count == 2 && pathComponents[0] == "networks":
            let id = pathComponents[1]
            return try await inspectNetwork(id: id)
        
        case (.DELETE, let pathComponents) where pathComponents.count == 2 && pathComponents[0] == "networks":
            let id = pathComponents[1]
            return try await removeNetwork(id: id)
        
        case (.POST, ["networks", "prune"]):
            return try await pruneNetworks(query: parseQuery(from: head.uri))
        
        // Network connect/disconnect endpoints
        case (.POST, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "networks" && pathComponents[2] == "connect":
            let id = pathComponents[1]
            return try await connectNetwork(id: id, body: body)
        case (.POST, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "networks" && pathComponents[2] == "disconnect":
            let id = pathComponents[1]
            return try await disconnectNetwork(id: id, body: body)

        // Image endpoints
        case (.POST, ["images", "create"]):
            return try await imagesCreate(head: head, query: parseQuery(from: head.uri))
        case (.GET, ["images", "json"]):
            return try await imagesList()
        case (.POST, ["build"]):
            return try await buildImage(head: head, body: body, query: parseQuery(from: head.uri))
        case (.DELETE, let pathComponents) where pathComponents.count == 2 && pathComponents[0] == "images":
            let name = pathComponents[1]
            return try await removeImage(name: name, query: parseQuery(from: head.uri))
        case (.GET, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "images" && pathComponents[2] == "json":
            let name = pathComponents[1]
            return try await inspectImage(name: name)
        case (.GET, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "images" && pathComponents[2] == "history":
            let name = pathComponents[1]
            return try await getImageHistory(name: name)
        case (.POST, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "images" && pathComponents[2] == "tag":
            let name = pathComponents[1]
            return try await tagImage(name: name, query: parseQuery(from: head.uri))
        case (.POST, ["images", "prune"]):
            return try await pruneImages(query: parseQuery(from: head.uri))
        case (.GET, let pathComponents) where pathComponents.count == 4 && pathComponents[0] == "images" && pathComponents[2] == "get":
            let name = pathComponents[1]
            return try await exportImages(names: [name])
        case (.POST, ["images", "load"]):
            return try await loadImages(body: body)
        case (.POST, ["images", "search"]):
            return try await searchImages(query: parseQuery(from: head.uri))
        
        // Registry and distribution endpoints
        case (.GET, let pathComponents) where pathComponents.count >= 3 && pathComponents[0] == "distribution" && pathComponents[2] == "json":
            let name = pathComponents[1]
            return try await getDistributionInfo(name: name)
        
        // Container exec endpoints
        case (.POST, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "containers" && pathComponents[2] == "exec":
            let id = pathComponents[1]
            return try await createExec(id: id, body: body)
        case (.POST, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "exec" && pathComponents[2] == "start":
            let execId = pathComponents[1]
            return try await startExec(execId: execId, body: body)
        
        // Container attach endpoint
        case (.POST, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "containers" && pathComponents[2] == "attach":
            let id = pathComponents[1]
            return try await attachContainer(id: id, query: parseQuery(from: head.uri))
        
        // System endpoints
        case (.GET, ["events"]):
            return try await getEvents(query: parseQuery(from: head.uri))
        
        case (.GET, ["version"]):
            return getVersion()
        
        case (.GET, ["info"]):
            return getSystemInfo()
        
        case (.GET, ["_ping"]):
            return DockerAPIResponse(status: .ok, body: "OK")
        
        case (.HEAD, ["_ping"]):
            return DockerAPIResponse(status: .ok, body: "")
        
        case (.GET, ["events"]):
            return try await getEvents(query: parseQuery(from: head.uri))
        
        case (.POST, ["auth"]):
            return DockerAPIResponse(status: .notImplemented, body: ["message": "Authentication not yet implemented"])
        
        case (.GET, ["system", "df"]):
            return getSystemUsage()
        
        case (.POST, ["system", "prune"]):
            return try await pruneSystem(query: parseQuery(from: head.uri))
        
        // Session and config endpoints
        case (.POST, ["session"]):
            return try await createSession(body: body)
        
        // Secrets endpoints (for Docker Compose)
        case (.GET, ["secrets"]):
            return try await listSecrets(query: parseQuery(from: head.uri))
        
        case (.POST, ["secrets", "create"]):
            return try await createSecret(body: body)
        
        case (.GET, let pathComponents) where pathComponents.count == 2 && pathComponents[0] == "secrets":
            let id = pathComponents[1]
            return try await inspectSecret(id: id)
        
        case (.DELETE, let pathComponents) where pathComponents.count == 2 && pathComponents[0] == "secrets":
            let id = pathComponents[1]
            return try await removeSecret(id: id)
        
        // Configs endpoints (for Docker Compose)
        case (.GET, ["configs"]):
            return try await listConfigs(query: parseQuery(from: head.uri))
        
        case (.POST, ["configs", "create"]):
            return try await createConfig(body: body)
        
        case (.GET, let pathComponents) where pathComponents.count == 2 && pathComponents[0] == "configs":
            let id = pathComponents[1]
            return try await inspectConfig(id: id)
        
        case (.DELETE, let pathComponents) where pathComponents.count == 2 && pathComponents[0] == "configs":
            let id = pathComponents[1]
            return try await removeConfig(id: id)
        
        // Services endpoints (for Docker Compose with swarm mode)
        case (.GET, ["services"]):
            return try await listServices(query: parseQuery(from: head.uri))
        
        case (.POST, ["services", "create"]):
            return try await createService(body: body)
        
        case (.GET, let pathComponents) where pathComponents.count == 2 && pathComponents[0] == "services":
            let id = pathComponents[1]
            return try await inspectService(id: id)
        
        case (.DELETE, let pathComponents) where pathComponents.count == 2 && pathComponents[0] == "services":
            let id = pathComponents[1]
            return try await removeService(id: id)
        
        case (.POST, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "services" && pathComponents[2] == "update":
            let id = pathComponents[1]
            return try await updateService(id: id, body: body)
        
        // Container inspect endpoint
        case (.GET, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "containers" && pathComponents[2] == "json":
            let id = pathComponents[1]
            return try await inspectContainer(id: id)
        
        default:
            // Log unhandled requests
            print("🚫 Unhandled Docker API Request: \(head.method) \(head.uri) -> components: \(components)")
            return DockerAPIResponse(
                status: .notFound,
                body: ["message": "Not found"]
            )
        }
    }

    private func sendResponse(context: ChannelHandlerContext, response: DockerAPIResponse) {
        var headers = HTTPHeaders()
        let isUpgrade = response.status == .switchingProtocols
        let bodyData = response.bodyData ?? Data()

        if isUpgrade {
            // For upgrade, ensure required headers; omit length & content-type per upgrade expectations.
            if !response.additionalHeaders.contains(where: { $0.0.lowercased() == "connection" }) {
                headers.add(name: "Connection", value: "Upgrade")
            }
            if !response.additionalHeaders.contains(where: { $0.0.lowercased() == "upgrade" }) {
                headers.add(name: "Upgrade", value: "tcp")
            }
        } else if response.streamer != nil {
            // Streaming response (non-upgrade): use chunked transfer and keep-alive
            headers.add(name: "Content-Type", value: response.contentType)
            headers.add(name: "Transfer-Encoding", value: "chunked")
            headers.add(name: "Connection", value: "keep-alive")
        } else {
            headers.add(name: "Content-Type", value: response.contentType)
            headers.add(name: "Content-Length", value: "\(bodyData.count)")
            headers.add(name: "Connection", value: "close")
        }
        for (k,v) in response.additionalHeaders { headers.add(name: k, value: v) }

        let responseHead = HTTPResponseHead(version: .http1_1, status: response.status, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)

        if !bodyData.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: bodyData.count)
            buffer.writeBytes(bodyData)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }

        if let streamer = response.streamer {
            let channel = context.channel
            if isUpgrade {
                // Complete the HTTP upgrade handshake first
                context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { result in
                    // Then hijack connection for raw streaming after the upgrade is complete
                    channel.pipeline.context(handlerType: HTTPResponseEncoder.self).whenSuccess { ctx in
                        _ = channel.pipeline.syncOperations.removeHandler(context: ctx)
                    }
                    channel.pipeline.context(handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self).whenSuccess { ctx in
                        _ = channel.pipeline.syncOperations.removeHandler(context: ctx)
                    }
                    // Now start the streamer - capture streamer locally
                    let capturedStreamer = streamer
                    capturedStreamer(channel)
                }
            } else {
                // Run streamer directly for non-upgrade streaming
                streamer(channel)
            }
        } else if !isUpgrade {
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        } else {
            let channel = context.channel
            channel.eventLoop.scheduleTask(in: .milliseconds(150)) { channel.close(promise: nil) }
        }
    }

    private func sendError(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String) {
        let response = DockerAPIResponse(
            status: status,
            body: ["message": message]
        )
        sendResponse(context: context, response: response)
    }

    private func parseQuery(from uri: String) -> [String: String] {
        guard let components = URLComponents(string: uri),
              let queryItems = components.queryItems else {
            return [:]
        }
        
        var query: [String: String] = [:]
        for item in queryItems {
            query[item.name] = item.value ?? ""
        }
        return query
    }
}

struct DockerAPIResponse: @unchecked Sendable {
    let status: HTTPResponseStatus
    let body: Any?
    let contentType: String
    let additionalHeaders: [(String,String)]
    let streamer: (@Sendable (Channel) -> Void)?

    init(status: HTTPResponseStatus, body: Any? = nil, contentType: String = "application/json", additionalHeaders: [(String,String)] = [], streamer: (@Sendable (Channel) -> Void)? = nil) {
        self.status = status
        self.body = body
        self.contentType = contentType
        self.additionalHeaders = additionalHeaders
        self.streamer = streamer
    }
    
    var bodyData: Data? {
        guard let body = body else { return nil }
        
        // Return raw bytes or text as-is
        if let data = body as? Data { return data }
        if let string = body as? String { return string.data(using: .utf8) }
        
        // Prefer property list JSON when valid
        if JSONSerialization.isValidJSONObject(body) {
            return try? JSONSerialization.data(withJSONObject: body)
        }
        
        // Fallback: attempt to encode Encodable types
        if let encodable = body as? any Encodable {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try? encoder.encode(AnyEncodable(encodable))
        }
        
        return nil
    }
}
