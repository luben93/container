import Foundation

/// Stores stdio pipes for containers between attach and start operations
final class ContainerAttachStore: @unchecked Sendable {
    static let shared = ContainerAttachStore()
    
    private let queue = DispatchQueue(label: "com.container.attach-store", attributes: .concurrent)
    private var attachedContainers: [String: AttachedContainer] = [:]
    private var attachConfigs: [String: AttachConfig] = [:]
    
    private init() {}
    
    struct AttachedContainer: Sendable {
        let stdout: Pipe?
        let stderr: Pipe?
    }
    
    struct AttachConfig: Sendable {
        let attachStdout: Bool
        let attachStderr: Bool
        let attachStdin: Bool
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
    
    func setAttachConfig(containerId: String, attachStdout: Bool, attachStderr: Bool, attachStdin: Bool) {
        queue.async(flags: .barrier) { [weak self] in
            self?.attachConfigs[containerId] = AttachConfig(
                attachStdout: attachStdout,
                attachStderr: attachStderr,
                attachStdin: attachStdin
            )
        }
    }
    
    func getAttachConfig(containerId: String) -> AttachConfig? {
        return queue.sync {
            return attachConfigs[containerId]
        }
    }
    
    func removeAttachConfig(containerId: String) {
        queue.async(flags: .barrier) { [weak self] in
            self?.attachConfigs.removeValue(forKey: containerId)
        }
    }
}
