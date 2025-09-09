import Foundation
import NIOCore
import NIOHTTP1

/// Manages Docker API events and subscribers
final class EventsStore: @unchecked Sendable {
    static let shared = EventsStore()
    
    private let queue = DispatchQueue(label: "com.container.events", attributes: .concurrent)
    private var subscribers: [String: EventSubscriber] = [:]
    private var eventBuffer: [DockerEvent] = []
    private let maxBufferSize = 1000
    
    private init() {}
    
    struct EventSubscriber {
        let channel: Channel
        let filters: [String: [String]]
        let since: Date?
        let until: Date?
    }
    
    struct DockerEvent: Codable {
        let `Type`: String
        let Action: String
        let Actor: EventActor
        let scope: String
        let time: Int64
        let timeNano: Int64
        
        struct EventActor: Codable {
            let ID: String
            let Attributes: [String: String]
        }
    }
    
    func subscribe(
        channel: Channel,
        filters: [String: [String]],
        since: Date?,
        until: Date?
    ) {
        let subscriberId = UUID().uuidString
        
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            let subscriber = EventSubscriber(
                channel: channel,
                filters: filters,
                since: since,
                until: until
            )
            self.subscribers[subscriberId] = subscriber
            
            // Send buffered events that match filters
            let matchingEvents = self.eventBuffer.filter { event in
                self.eventMatches(event, filters: filters, since: since, until: until)
            }
            
            for event in matchingEvents {
                Task {
                    let subscriber = EventSubscriber(
                        channel: channel,
                        filters: filters,
                        since: since,
                        until: until
                    )
                    self.sendEventToSubscriber(event, subscriber: subscriber)
                }
            }
        }
        
        // Clean up when channel closes
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.queue.async(flags: .barrier) { [weak self] in
                self?.subscribers.removeValue(forKey: subscriberId)
            }
        }
    }
    
    func publishContainerEvent(
        containerId: String,
        action: String,
        attributes: [String: String] = [:]
    ) {
        let now = Date()
        let event = DockerEvent(
            Type: "container",
            Action: action,
            Actor: DockerEvent.EventActor(
                ID: containerId,
                Attributes: attributes
            ),
            scope: "local",
            time: Int64(now.timeIntervalSince1970),
            timeNano: Int64(now.timeIntervalSince1970 * 1_000_000_000)
        )
        
        publishEvent(event)
    }
    
    private func publishEvent(_ event: DockerEvent) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            // Add to buffer
            self.eventBuffer.append(event)
            if self.eventBuffer.count > self.maxBufferSize {
                self.eventBuffer.removeFirst()
            }
            
            // Send to matching subscribers
            for subscriber in self.subscribers.values {
                if self.eventMatches(event, filters: subscriber.filters, since: subscriber.since, until: subscriber.until) {
                    self.sendEventToSubscriber(event, subscriber: subscriber)
                }
            }
        }
    }
    
    private func eventMatches(
        _ event: DockerEvent,
        filters: [String: [String]],
        since: Date?,
        until: Date?
    ) -> Bool {
        // Check time range
        let eventTime = Date(timeIntervalSince1970: TimeInterval(event.time))
        if let since = since, eventTime < since { return false }
        if let until = until, eventTime > until { return false }
        
        // Check filters
        for (key, values) in filters {
            switch key {
            case "container":
                if !values.contains(event.Actor.ID) { return false }
            case "type":
                if !values.contains(event.Type) { return false }
            case "event":
                if !values.contains(event.Action) { return false }
            default:
                // Unknown filter - be permissive
                break
            }
        }
        
        return true
    }
    
    private func sendEventToSubscriber(_ event: DockerEvent, subscriber: EventSubscriber) {
        do {
            let data = try JSONEncoder().encode(event)
            var buffer = subscriber.channel.allocator.buffer(capacity: data.count + 1)
            buffer.writeBytes(data)
            buffer.writeString("\n") // Events are newline-delimited JSON
            
            subscriber.channel.writeAndFlush(buffer, promise: nil)
        } catch {
            print("⚠️ Failed to encode event: \(error)")
        }
    }
}
