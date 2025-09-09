import Foundation

/// Stores stdio pipes for containers between attach and start operations
final class ContainerAttachStore: @unchecked Sendable {
    static let shared = ContainerAttachStore()
    
    private let queue = DispatchQueue(label: "com.container.attach-store", attributes: .concurrent)
    private var attachedContainers: [String: AttachedContainer] = [:]
    private var attachConfigs: [String: AttachConfig] = [:]
    private var pipeWaiters: [String: [CheckedContinuation<AttachedContainer?, Never>]] = [:]
    
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
            guard let self = self else { return }
            self.attachedContainers[containerId] = AttachedContainer(stdout: stdout, stderr: stderr)
            
            // Notify any waiting attach connections
            if let waiters = self.pipeWaiters.removeValue(forKey: containerId) {
                let pipes = self.attachedContainers[containerId]
                for continuation in waiters {
                    continuation.resume(returning: pipes)
                }
            }
        }
    }
    
    func getPipes(containerId: String) -> AttachedContainer? {
        return queue.sync {
            return attachedContainers[containerId]
        }
    }
    
    func waitForPipes(containerId: String) async -> AttachedContainer? {
        // Check if pipes are already available
        if let existing = getPipes(containerId: containerId) {
            return existing
        }
        
        // If not, wait for them to be set
        return await withCheckedContinuation { continuation in
            queue.async(flags: .barrier) { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                
                // Double-check after acquiring the barrier
                if let existing = self.attachedContainers[containerId] {
                    continuation.resume(returning: existing)
                } else {
                    // Add to waiters
                    if self.pipeWaiters[containerId] == nil {
                        self.pipeWaiters[containerId] = []
                    }
                    self.pipeWaiters[containerId]?.append(continuation)
                }
            }
        }
    }
    
    func removePipes(containerId: String) {
        queue.async(flags: .barrier) { [weak self] in
            self?.attachedContainers.removeValue(forKey: containerId)
            // Also cancel any remaining waiters
            if let waiters = self?.pipeWaiters.removeValue(forKey: containerId) {
                for continuation in waiters {
                    continuation.resume(returning: nil)
                }
            }
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
