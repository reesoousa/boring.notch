//
//  LocalSendMulticast.swift
//  boringCode
//
//  Descoberta por UDP multicast (224.0.0.167:53317). O boringCode se anuncia e
//  escuta os anúncios dos outros aparelhos. Socket compartilhado
//  (SO_REUSEPORT), então convive com o app LocalSend aberto no mesmo Mac.
//

import Darwin
import Foundation
import os

final class LocalSendMulticast: @unchecked Sendable {  // estado só é tocado em `queue`
    /// Mensagem recebida + IP de quem mandou.
    var onMessage: ((LocalSendInfo, String) -> Void)?

    private let queue: DispatchQueue
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var joinedInterfaces: Set<String> = []
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "boringcode", category: "LocalSend")

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start() {
        queue.async { self.open() }
    }

    func stop() {
        queue.async { self.closeSocket() }
    }

    /// Manda o anúncio em rajada (100 ms, 500 ms, 2 s), como o LocalSend faz —
    /// quem acabou de entrar na rede pode perder o primeiro pacote.
    func announce(_ info: LocalSendInfo) {
        var message = info
        message.announce = true
        guard let payload = try? JSONEncoder().encode(message) else { return }
        for delay in [0.1, 0.5, 2.0] {
            queue.asyncAfter(deadline: .now() + delay) { self.send(payload) }
        }
    }

    // MARK: - Socket

    private func open() {
        guard fd < 0 else {
            joinInterfaces()
            return
        }
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            log.error("LocalSend: socket UDP falhou (\(errno))")
            return
        }
        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var ttl: UInt8 = 255
        setsockopt(socketFD, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = LocalSendProtocol.port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            log.error("LocalSend: bind UDP falhou (\(errno))")
            close(socketFD)
            return
        }
        fd = socketFD
        joinInterfaces()

        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.receive() }
        source.setCancelHandler { close(socketFD) }
        readSource = source
        source.resume()
    }

    private func closeSocket() {
        readSource?.cancel()
        readSource = nil
        fd = -1
        joinedInterfaces = []
    }

    /// Entra no grupo em cada interface IPv4 ativa (Wi-Fi, Ethernet…). Chamado
    /// de novo a cada anúncio para pegar redes que apareceram depois.
    private func joinInterfaces() {
        guard fd >= 0 else { return }
        for interface in LocalSendNetwork.ipv4Interfaces() where !joinedInterfaces.contains(interface.address) {
            var request = ip_mreq()
            request.imr_multiaddr.s_addr = inet_addr(LocalSendProtocol.multicastGroup)
            request.imr_interface.s_addr = inet_addr(interface.address)
            let result = setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &request, socklen_t(MemoryLayout<ip_mreq>.size))
            if result == 0 || errno == EADDRINUSE {
                joinedInterfaces.insert(interface.address)
            }
        }
    }

    private func send(_ payload: Data) {
        if fd < 0 { open() }
        guard fd >= 0 else { return }
        joinInterfaces()

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = LocalSendProtocol.port.bigEndian
        destination.sin_addr.s_addr = inet_addr(LocalSendProtocol.multicastGroup)

        for interface in LocalSendNetwork.ipv4Interfaces() {
            var outgoing = in_addr(s_addr: inet_addr(interface.address))
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &outgoing, socklen_t(MemoryLayout<in_addr>.size))
            _ = payload.withUnsafeBytes { bytes in
                withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    private func receive() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var sender = sockaddr_in()
        var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &sender) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &buffer, buffer.count, 0, $0, &senderLength)
            }
        }
        guard count > 0,
              let info = try? JSONDecoder().decode(LocalSendInfo.self, from: Data(buffer[0..<count]))
        else { return }
        onMessage?(info, String(cString: inet_ntoa(sender.sin_addr)))
    }
}

enum LocalSendNetwork {
    struct Interface: Hashable {
        let name: String
        let address: String
        let netmask: String
    }

    /// Interfaces IPv4 ativas com multicast, sem loopback nem VPN ponto a ponto.
    static func ipv4Interfaces() -> [Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var result: [Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  flags & IFF_MULTICAST != 0, flags & IFF_POINTOPOINT == 0,
                  let netmask = entry.ifa_netmask
            else { continue }
            result.append(Interface(name: String(cString: entry.ifa_name), address: ipString(address), netmask: ipString(netmask)))
        }
        return result
    }

    /// Endereços da mesma /24 de cada interface — busca de reserva quando o multicast falha.
    static func subnetHosts() -> [String] {
        var hosts: [String] = []
        for interface in ipv4Interfaces() {
            let parts = interface.address.split(separator: ".")
            guard parts.count == 4 else { continue }
            let prefix = parts.prefix(3).joined(separator: ".")
            for last in 1...254 {
                let host = "\(prefix).\(last)"
                if host != interface.address { hosts.append(host) }
            }
        }
        return hosts
    }

    static func isOwnAddress(_ host: String) -> Bool {
        ipv4Interfaces().contains { $0.address == host }
    }

    private static func ipString(_ address: UnsafeMutablePointer<sockaddr>) -> String {
        address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            String(cString: inet_ntoa($0.pointee.sin_addr))
        }
    }
}
