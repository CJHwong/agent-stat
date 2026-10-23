import Foundation

@MainActor
final class RemoteHosts {
    private let store: SessionStore
    private let onChange: () -> Void
    private var streams: [RemoteStream] = []
    private var readers: [String: EventReader] = [:]
    private var connections: [String: String] = [:]
    private var lastStatus: [String: Int] = [:]

    init(store: SessionStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange
    }

    private func directory(_ host: String) -> URL {
        Paths.eventsDirectory.appendingPathComponent("remote").appendingPathComponent(host)
            .appendingPathComponent("hosts")
    }

    func start() {
        for (host, argv) in Routes.load().streams where host != Paths.localHostName() {
            guard !host.isEmpty, !host.contains("/"), host != ".", host != ".." else {
                Log.write("stream: invalid route host")
                continue
            }
            connections[host] = "catching up"
            readers[host] = EventReader()
            let changed: RemoteStream.Update = { [weak self] host, state, alive in
                self?.receive(host: host, state: state, alive: alive)
            }
            let stream = RemoteStream(host: host, argv: argv, directory: directory(host), update: changed)
            streams.append(stream)
            stream.start()
        }
        onChange()
    }

    func stop() {
        for stream in streams { stream.stop() }
    }

    private func receive(host: String, state: String, alive: [String: Bool]?) {
        let now = Int(Date().timeIntervalSince1970)
        if connections[host] != state { Log.write("stream \(host): \(state)") }
        connections[host] = state
        if let alive {
            lastStatus[host] = now
            read()
            store.reapRemote(host: host, alive: alive, now: now)
        }
        onChange()
    }

    func read() {
        for (host, reader) in readers {
            for item in reader.poll(directory: directory(host)) {
                store.apply(item.record, host: host, position: item.position)
            }
            store.applyTitles(CodexTitles.cached(in: directory(host)), host: host)
        }
    }

    func labels(now: Int) -> [String: String] {
        var labels = connections
        for (host, state) in connections where state == "offline" {
            guard let last = lastStatus[host] else { continue }
            labels[host] = "offline, updated \(PanelModel.shortDuration(max(0, now - last))) ago"
        }
        return labels
    }
}
