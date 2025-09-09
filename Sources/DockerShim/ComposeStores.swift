import Foundation
import Logging
import ContainerPersistence

// MARK: Secret store

struct SecretEntity: Codable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    var labels: [String: String]
    var createdAt: Date
    var updatedAt: Date
    // data stored as a file alongside metadata
}

actor SecretStore {
    static let shared = try! SecretStore()

    private let log = Logger(label: "com.apple.container.docker-shim.secrets")
    private let store: FilesystemEntityStore<SecretEntity>

    private let dataDir: URL

    init() throws {
        let base = SecretStore.baseDir().appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.dataDir = base
        self.store = try FilesystemEntityStore(path: base, type: "secret", log: log)
    }

    func list() async throws -> [SecretEntity] {
        try await store.list()
    }

    func create(name: String, data: Data, labels: [String: String]) async throws -> SecretEntity {
        let entity = SecretEntity(name: name, labels: labels, createdAt: Date(), updatedAt: Date())
        try await store.create(entity)
        try data.write(to: dataFileURL(name: name))
        return entity
    }

    func get(id: String) async throws -> SecretEntity? {
        try await store.retrieve(id)
    }

    func delete(id: String) async throws {
        try await store.delete(id)
        try? FileManager.default.removeItem(at: dataFileURL(name: id))
    }

    private func dataFileURL(name: String) -> URL {
        dataDir.appendingPathComponent(name).appendingPathComponent("data")
    }

    private static func baseDir() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".container-shim")
    }
}

// MARK: Config store

struct ConfigEntity: Codable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    var labels: [String: String]
    var createdAt: Date
    var updatedAt: Date
}

actor ConfigStore {
    static let shared = try! ConfigStore()

    private let log = Logger(label: "com.apple.container.docker-shim.configs")
    private let store: FilesystemEntityStore<ConfigEntity>
    private let dataDir: URL

    init() throws {
        let base = ConfigStore.baseDir().appendingPathComponent("configs")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.dataDir = base
        self.store = try FilesystemEntityStore(path: base, type: "config", log: log)
    }

    func list() async throws -> [ConfigEntity] {
        try await store.list()
    }

    func create(name: String, data: Data, labels: [String: String]) async throws -> String {
        let entity = ConfigEntity(name: name, labels: labels, createdAt: Date(), updatedAt: Date())
        try await store.create(entity)
        try data.write(to: dataFileURL(name: name))
        return entity.id
    }

    func get(id: String) async throws -> (name: String, labels: [String: String], createdAt: Date, updatedAt: Date, data: Data)? {
        guard let e = try await store.retrieve(id) else { return nil }
        let data = (try? Data(contentsOf: dataFileURL(name: id))) ?? Data()
        return (name: e.name, labels: e.labels, createdAt: e.createdAt, updatedAt: e.updatedAt, data: data)
    }

    func delete(id: String) async throws {
        try await store.delete(id)
        try? FileManager.default.removeItem(at: dataFileURL(name: id))
    }

    private func dataFileURL(name: String) -> URL {
        dataDir.appendingPathComponent(name).appendingPathComponent("data")
    }

    private static func baseDir() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".container-shim")
    }
}
