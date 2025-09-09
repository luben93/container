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

import ArgumentParser
import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOFoundationCompat

@main
struct DockerShim: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-docker-shim",
        abstract: "Docker Moby API compatibility shim for Apple Container runtime",
        version: "1.0.0"
    )

    @Option(name: .shortAndLong, help: "Port to listen on")
    var port: Int = 2375

    @Option(name: .shortAndLong, help: "Host to bind to")
    var host: String = "127.0.0.1"

    @Flag(name: .long, help: "Enable debug logging")
    var debug = false

    func run() async throws {
        let log = setupLogger()
        log.info("Starting Docker API shim server", metadata: [
            "host": "\(host)",
            "port": "\(port)"
        ])

        let server = DockerAPIServer(host: host, port: port, logger: log)
        try await server.start()
    }

    private func setupLogger() -> Logger {
        LoggingSystem.bootstrap { label in
            StreamLogHandler.standardOutput(label: label)
        }
        var log = Logger(label: "com.apple.container.docker-shim")
        if debug {
            log.logLevel = .debug
        }
        return log
    }
}