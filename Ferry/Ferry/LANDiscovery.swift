import Darwin
import Foundation

struct DiscoveredServer: Identifiable, Hashable {
    let origin: String
    var id: String { origin }
}

/// Bounded /24 scan for a Ferry Server. Ferry publishes no mDNS/Bonjour or UDP
/// beacon, so discovery probes the unauthenticated, read-only `GET /api/v1/access`
/// endpoint on the server's LAN port. Manual URL entry and QR scanning remain
/// fallbacks.
enum LANDiscovery {
    // The Windows FerryDesktop client boots the Go service with
    // `-listen 127.0.0.1:42819 -lan -lan-listen <IPv4>:42819` (FerryBootstrapper.cs),
    // so the LAN-facing HTTP origin is `<IPv4>:42819`.
    static let scanPort = 42819
    private static let batchSize = 48
    private static let probeTimeout: TimeInterval = 1.5

    /// Warm the iOS local-network permission gate. On iOS 14+ the first
    /// outbound connection to a private address shows the system prompt and
    /// fails while it is pending, so one cheap probe is fired before the scan.
    static func warmUp() async {
        guard let ip = primaryIPv4(), let base = subnetBase(ip) else { return }
        _ = await probe(host: "\(base).1")
    }

    static func scan() async -> [DiscoveredServer] {
        guard let ip = primaryIPv4(), let base = subnetBase(ip) else { return [] }
        // A second pass catches hosts that only answered after the local-network
        // prompt was accepted mid-scan.
        var results = await sweep(base: base, skip: ip)
        if results.isEmpty {
            try? await Task.sleep(for: .seconds(0.5))
            results = await sweep(base: base, skip: ip)
        }
        results.sort { $0.origin < $1.origin }
        return results
    }

    /// Preferred LAN IPv4. iOS lists Wi-Fi as `en0`; cellular (`pdp_ip*`) and
    /// VPN (`utun*`, `ipsec*`) interfaces are excluded so the scan targets the
    /// Wi-Fi subnet the PC is actually on.
    static func primaryIPv4() -> String? {
        var fallback: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var cursor = ifaddr
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let name = current.pointee.ifa_name else { continue }
            let interface = String(cString: name)
            guard !interface.hasPrefix("utun"), !interface.hasPrefix("llw"),
                  !interface.hasPrefix("awdl"), !interface.hasPrefix("bridge"),
                  !interface.hasPrefix("anpi"), !interface.hasPrefix("pdp_ip"),
                  !interface.hasPrefix("ipsec"), !interface.hasPrefix("ap"),
                  !interface.hasPrefix("vboxnet"), !interface.hasPrefix("stf") else { continue }
            guard let sa = current.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if isPrivateIPv4(ip) {
                    if interface == "en0" { return ip }
                    if fallback == nil { fallback = ip }
                }
            }
        }
        return fallback
    }

    static func subnetBase(_ ip: String) -> String? {
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return nil }
        return octets[0...2].map(String.init).joined(separator: ".")
    }

    private static func sweep(base: String, skip: String) async -> [DiscoveredServer] {
        var hosts: [String] = []
        for host in 1...254 {
            let ip = "\(base).\(host)"
            if ip != skip { hosts.append(ip) }
        }
        var results: [DiscoveredServer] = []
        for chunkStart in stride(from: 0, to: hosts.count, by: batchSize) {
            let chunk = Array(hosts[chunkStart..<min(chunkStart + batchSize, hosts.count)])
            let origins = await withTaskGroup(of: String?.self, returning: [String].self) { group in
                for ip in chunk {
                    group.addTask { await probe(host: ip) }
                }
                var found: [String] = []
                for await origin in group {
                    if let origin { found.append(origin) }
                }
                return found
            }
            results.append(contentsOf: origins.map { DiscoveredServer(origin: $0) })
        }
        return results
    }

    private static func probe(host: String) async -> String? {
        let origin = "http://\(host):\(scanPort)"
        guard let url = URL(string: origin + "/api/v1/access") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = probeTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard (try? JSONDecoder().decode(AccessStatusPayload.self, from: data)) != nil else { return nil }
            return origin
        } catch {
            return nil
        }
    }

    private static func isPrivateIPv4(_ ip: String) -> Bool {
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        if octets[0] == 10 { return true }
        if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        return false
    }
}
