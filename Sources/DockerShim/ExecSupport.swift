import Foundation
import NIOCore

struct ExecSpec: Sendable {
    let containerID: String
    let cmd: [String]
    let env: [String]
    let tty: Bool
    let attachStdin: Bool
    let attachStdout: Bool
    let attachStderr: Bool
}

actor ExecStore {
    static let shared = ExecStore()
    private var specs: [String: ExecSpec] = [:]

    func set(spec: ExecSpec, for id: String) {
        specs[id] = spec
    }
    func get(id: String) -> ExecSpec? {
        specs[id]
    }
    func remove(id: String) {
        specs.removeValue(forKey: id)
    }
}

final class ExecInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let writeHandle: FileHandle

    init(writeHandle: FileHandle) {
        self.writeHandle = writeHandle
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        if let bytes = buf.readBytes(length: buf.readableBytes) {
            let d = Data(bytes)
            try? writeHandle.write(contentsOf: d)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        try? writeHandle.close()
        context.fireChannelInactive()
    }
}
