import Foundation
import Network

/// The third way to ask a router for a port, and on most consumer routers the
/// only one that works.
///
/// UPnP-IGD is older and uglier than PCP: the router is found by shouting on a
/// multicast address, it answers with a URL, the URL serves an XML document, the
/// document names a control URL, and the control URL takes SOAP. Every step is a
/// place where a particular vendor's firmware does something slightly its own
/// way. It is tried last for that reason — and it is tried at all because the
/// routers that speak it are the ones in most houses.
///
/// Two things are deliberately not done here. Nimlet does not enable UPnP on a
/// router that has it switched off — there is no way to, and a router with it off
/// has been told not to hand out mappings, which is an answer. And it does not
/// map a port for anything other than itself: the internal client is always this
/// Mac's own address on the interface the router is on, so a bug here cannot
/// expose somebody else's machine.
actor UPnPGateway {

    /// Where the description document was, so a renewal does not have to
    /// re-discover the router. Dropped whenever a call through it fails.
    private var control: Control?

    private struct Control {
        var url: URL
        var serviceType: String
        /// This Mac's address on the interface the router answered on, which is
        /// the only address a mapping is ever made for.
        var localAddress: String
    }

    func map(internalPort: UInt16, lifetime: UInt32, over interface: NWInterface?) async -> PortMapper.Mapping? {
        guard let control = await resolvedControl(over: interface) else { return nil }
        let body = """
            <NewRemoteHost></NewRemoteHost>\
            <NewExternalPort>\(internalPort)</NewExternalPort>\
            <NewProtocol>TCP</NewProtocol>\
            <NewInternalPort>\(internalPort)</NewInternalPort>\
            <NewInternalClient>\(control.localAddress)</NewInternalClient>\
            <NewEnabled>1</NewEnabled>\
            <NewPortMappingDescription>Mice</NewPortMappingDescription>\
            <NewLeaseDuration>\(lifetime)</NewLeaseDuration>
            """
        guard await soap(control, action: "AddPortMapping", body: body) != nil else {
            // A router that refuses a leased mapping sometimes accepts a
            // permanent one; several firmwares implement lease durations by
            // rejecting them. A permanent mapping is worse — it outlives the Mac
            // — so it is only tried after the right thing has failed, and
            // `RemoteReach` deletes it when away access goes off.
            let permanent = body.replacingOccurrences(of: "<NewLeaseDuration>\(lifetime)</NewLeaseDuration>",
                                                      with: "<NewLeaseDuration>0</NewLeaseDuration>")
            guard await soap(control, action: "AddPortMapping", body: permanent) != nil else {
                self.control = nil
                return nil
            }
            miceLog.info("away: UPnP mapped \(internalPort, privacy: .public) with no lease — the router refused a leased one")
            return PortMapper.Mapping(externalHost: await externalAddress(control),
                                      externalPort: internalPort,
                                      lifetime: lifetime,
                                      via: "UPnP")
        }
        miceLog.info("away: UPnP mapped \(internalPort, privacy: .public) for \(lifetime, privacy: .public)s")
        return PortMapper.Mapping(externalHost: await externalAddress(control),
                                  externalPort: internalPort,
                                  lifetime: lifetime,
                                  via: "UPnP")
    }

    func unmap(internalPort: UInt16, over interface: NWInterface?) async {
        guard let control = await resolvedControl(over: interface) else { return }
        let body = """
            <NewRemoteHost></NewRemoteHost>\
            <NewExternalPort>\(internalPort)</NewExternalPort>\
            <NewProtocol>TCP</NewProtocol>
            """
        _ = await soap(control, action: "DeletePortMapping", body: body)
    }

    // MARK: - Discovery

    private func resolvedControl(over interface: NWInterface?) async -> Control? {
        if let control { return control }
        guard let found = await discover(over: interface) else { return nil }
        control = found
        return found
    }

    /// M-SEARCH, and the first gateway that answers.
    ///
    /// `NWConnectionGroup` rather than a plain connection: the request goes to a
    /// multicast address and the answer comes back *unicast* from the router's own
    /// address, which a connection bound to the group address would discard.
    private func discover(over interface: NWInterface?) async -> Control? {
        let targets = ["urn:schemas-upnp-org:service:WANIPConnection:1",
                       "urn:schemas-upnp-org:service:WANIPConnection:2",
                       "urn:schemas-upnp-org:device:InternetGatewayDevice:1"]
        guard let group = try? NWMulticastGroup(for: [.hostPort(host: "239.255.255.250", port: 1900)]) else {
            return nil
        }
        let parameters = NWParameters.udp
        // Pinned to the interface the router is on, for the reason `UDPExchange`
        // gives: with a VPN up, the default route is the tunnel's, and a
        // multicast search sent down a tunnel finds nothing.
        parameters.requiredInterface = interface
        let connection = NWConnectionGroup(with: group, using: parameters)
        let queue = DispatchQueue(label: "com.renyicao.mice.host.ssdp")

        let locations: [URL] = await withCheckedContinuation { continuation in
            let box = LocationBox(continuation: continuation, group: connection)
            connection.setReceiveHandler(maximumMessageSize: 8 * 1024, rejectOversizedMessages: true) { _, content, _ in
                guard let content, let text = String(data: content, encoding: .utf8) else { return }
                guard let location = Self.header("LOCATION", in: text).flatMap(URL.init(string:)) else { return }
                box.add(location)
            }
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                for target in targets {
                    let search = """
                        M-SEARCH * HTTP/1.1\r
                        HOST: 239.255.255.250:1900\r
                        MAN: "ssdp:discover"\r
                        MX: 2\r
                        ST: \(target)\r
                        \r\n
                        """
                    connection.send(content: Data(search.utf8)) { _ in }
                }
            }
            connection.start(queue: queue)
            // Two seconds, which is the MX the search asked routers to spread
            // their answers over, plus a little.
            queue.asyncAfter(deadline: .now() + 2.5) { box.finish() }
        }

        for location in locations {
            if let control = await describe(location) { return control }
        }
        return nil
    }

    /// Reads the router's description document and finds the one service that can
    /// forward a port.
    private func describe(_ location: URL) async -> Control? {
        guard let (data, response) = try? await Self.session.data(from: location),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let xml = String(data: data, encoding: .utf8) else { return nil }

        // WANIPConnection for a router on Ethernet or fibre, WANPPPConnection for
        // one dialling PPPoE. Same two actions either way.
        for type in ["urn:schemas-upnp-org:service:WANIPConnection:2",
                     "urn:schemas-upnp-org:service:WANIPConnection:1",
                     "urn:schemas-upnp-org:service:WANPPPConnection:1"] {
            guard let controlPath = Self.controlURL(forServiceType: type, in: xml) else { continue }
            guard let url = URL(string: controlPath, relativeTo: location)?.absoluteURL else { continue }
            guard let local = Self.localAddress(towards: location) else { continue }
            miceLog.info("away: UPnP gateway at \(url.absoluteString, privacy: .public)")
            return Control(url: url, serviceType: type, localAddress: local)
        }
        return nil
    }

    // MARK: - SOAP

    private func soap(_ control: Control, action: String, body: String) async -> String? {
        var request = URLRequest(url: control.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(control.serviceType)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data("""
            <?xml version="1.0"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
            <s:Body><u:\(action) xmlns:u="\(control.serviceType)">\(body)</u:\(action)></s:Body>\
            </s:Envelope>
            """.utf8)

        guard let (data, response) = try? await Self.session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard http.statusCode == 200 else {
            // The router says why in the fault body, and it is worth logging
            // verbatim: "OnlyPermanentLeasesSupported" and
            // "ActionNotAuthorized" are two entirely different problems that
            // both arrive as a 500.
            miceLog.info("away: UPnP \(action, privacy: .public) failed \(http.statusCode, privacy: .public) \(Self.faultReason(in: text) ?? "", privacy: .public)")
            return nil
        }
        return text
    }

    private func externalAddress(_ control: Control) async -> String? {
        guard let reply = await soap(control, action: "GetExternalIPAddress", body: "") else { return nil }
        guard let address = Self.element("NewExternalIPAddress", in: reply), !address.isEmpty else {
            return nil
        }
        // A router that is itself behind another NAT reports a private address
        // here. Publishing it would send the phone to an address on a network it
        // is not on, and STUN can answer the question properly.
        return Self.isPrivate(address) ? nil : address
    }

    // MARK: - Text

    /// One HTTP header out of an SSDP answer, whose case no two routers agree on.
    static func header(_ name: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).uppercased() == name.uppercased()
            else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The `controlURL` belonging to one `serviceType`, out of a description
    /// document that holds several services.
    ///
    /// Scanned rather than parsed with XMLDocument because the two elements have
    /// to be matched up: a document lists half a dozen services and the
    /// `controlURL` that matters is the one inside the same `<service>` element as
    /// the type being looked for — taking the first `controlURL` in the file
    /// forwards a port on the wrong service, which routers answer with a 500 and
    /// no explanation.
    static func controlURL(forServiceType type: String, in xml: String) -> String? {
        let services = xml.components(separatedBy: "<service>").dropFirst()
        for service in services {
            let block = service.components(separatedBy: "</service>").first ?? service
            guard block.contains(type) else { continue }
            if let url = element("controlURL", in: block) { return url }
        }
        return nil
    }

    static func element(_ name: String, in xml: String) -> String? {
        // Namespace prefixes vary, so the tag is matched by its local name.
        guard let openStart = xml.range(of: "<\(name)>") ?? xml.range(of: ":\(name)>") else { return nil }
        let after = xml[openStart.upperBound...]
        guard let closeStart = after.range(of: "</") else { return nil }
        return after[..<closeStart.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func faultReason(in xml: String) -> String? {
        element("errorDescription", in: xml) ?? element("faultstring", in: xml)
    }

    /// A router that is itself behind another NAT reports a private address as
    /// its "external" one. `PortMapWire` has the ranges.
    static func isPrivate(_ address: String) -> Bool {
        PortMapWire.isPrivateIPv4(address)
    }

    /// This Mac's address on the interface that reaches the router — which is the
    /// only address a port is ever forwarded to.
    private static func localAddress(towards location: URL) -> String? {
        guard let host = location.host, let port = location.port ?? Optional(80) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 80,
                                      using: .tcp)
        let queue = DispatchQueue(label: "com.renyicao.mice.host.upnp.local")
        let found = NSLock()
        var address: String?
        let ready = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let local = UDPExchange.address(of: connection.currentPath?.localEndpoint)
                found.withLock { address = local }
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        connection.cancel()
        return found.withLock { address }
    }

    /// Its own session: a router's description document must not be fetched
    /// through a proxy or a VPN, and nothing here should be cached.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 6
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    /// Collects every gateway that answers within the search window, then
    /// resumes once.
    private final class LocationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[URL], Never>?
        private var locations: [URL] = []
        private let group: NWConnectionGroup

        init(continuation: CheckedContinuation<[URL], Never>, group: NWConnectionGroup) {
            self.continuation = continuation
            self.group = group
        }

        func add(_ location: URL) {
            lock.withLock {
                guard !locations.contains(location) else { return }
                locations.append(location)
            }
        }

        func finish() {
            let pending: CheckedContinuation<[URL], Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            guard let pending else { return }
            group.cancel()
            pending.resume(returning: lock.withLock { locations })
        }
    }
}
