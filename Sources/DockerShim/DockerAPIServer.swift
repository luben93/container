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
        var bodyCopy = body
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
        // System endpoints
        case (.GET, ["events"]):
            return try await getEvents(query: parseQuery(from: head.uri))
        
        case (.GET, ["version"]):
            return getVersion()
        
        case (.GET, ["_ping"]):
            return DockerAPIResponse(status: .ok, body: "OK")
        
        // Container inspect endpoint
        case (.GET, let pathComponents) where pathComponents.count == 3 && pathComponents[0] == "containers" && pathComponents[2] == "json":
            let id = pathComponents[1]
            return try await inspectContainer(id: id)
        
        default:
            return DockerAPIResponse(
                status: .notFound,
                body: ["message": "Not found"]
            )
        }
    }

    private func sendResponse(context: ChannelHandlerContext, response: DockerAPIResponse) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: response.contentType)
        
        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: response.status,
            headers: headers
        )
        
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        
        if let bodyData = response.bodyData {
            var buffer = context.channel.allocator.buffer(capacity: bodyData.count)
            buffer.writeBytes(bodyData)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
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
    
    init(status: HTTPResponseStatus, body: Any? = nil, contentType: String = "application/json") {
        self.status = status
        self.body = body
        self.contentType = contentType
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
