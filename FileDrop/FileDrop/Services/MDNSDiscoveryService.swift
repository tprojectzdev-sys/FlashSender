import Foundation

struct DiscoveredServer: Equatable {
    let host: String
    let port: Int
}

/// Bonjour browser for `_filedrop._tcp` (Rust server mDNS advertisement).
@MainActor
final class MDNSDiscoveryService: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var browser: NetServiceBrowser?
    private var resolvingService: NetService?
    private var continuation: CheckedContinuation<DiscoveredServer?, Never>?
    private var timeoutTask: Task<Void, Never>?

    func discover(timeout: TimeInterval = 5) async -> DiscoveredServer? {
        stop()

        return await withCheckedContinuation { continuation in
            self.continuation = continuation

            let browser = NetServiceBrowser()
            browser.delegate = self
            self.browser = browser
            browser.searchForServices(ofType: "_filedrop._tcp.", inDomain: "local.")

            timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.finish(with: nil)
            }
        }
    }

    func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        browser?.stop()
        browser = nil
        resolvingService?.stop()
        resolvingService = nil
    }

    private func finish(with server: DiscoveredServer?) {
        guard let continuation else { return }
        self.continuation = nil
        stop()
        continuation.resume(returning: server)
    }

    // MARK: - NetServiceBrowserDelegate

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor in
            guard self.continuation != nil else { return }
            self.resolvingService?.stop()
            service.delegate = self
            self.resolvingService = service
            service.resolve(withTimeout: 5)
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch error: [String: NSNumber]
    ) {
        Task { @MainActor in self.finish(with: nil) }
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {}

    // MARK: - NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in
            guard let host = sender.hostName, sender.port > 0 else {
                self.finish(with: nil)
                return
            }
            var hostname = host
            if hostname.hasSuffix(".") {
                hostname.removeLast()
            }
            self.finish(with: DiscoveredServer(host: hostname, port: sender.port))
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        Task { @MainActor in
            if self.resolvingService == sender {
                self.resolvingService = nil
            }
        }
    }
}
