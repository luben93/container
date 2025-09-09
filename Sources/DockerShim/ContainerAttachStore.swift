import Foundation

/// Stores stdio pipes for containers between attach and start operations
final class ContainerAttachStore: @unchecked Sendable {
    static let shared = ContainerAttachStore()
    
    private let queue = DispatchQueue(label: "com.container.attach-store", attributes: .concurrent)
    private var attachedContainers: [String: AttachedContainer] = [:]
    
    private init() {}
    
    struct AttachedContainer: Sendable {
        let stdout: Pipe?
        let stderr: Pipe?
    }
    
    func setPipes(containerId: String, stdout: Pipe?, stderr: Pipe?) {
        queue.async(flags: .barrier) { [weak self] in
            self?.attachedContainers[containerId] = AttachedContainer(stdout: stdout, stderr: stderr)
        }
    }
    
    func getPipes(containerId: String) -> AttachedContainer? {
        return queue.sync {
            return attachedContainers[containerId]
        }
    }
    
    func removePipes(containerId: String) {
        queue.async(flags: .barrier) { [weak self] in
            self?.attachedContainers.removeValue(forKey: containerId)
        }
    }
}
