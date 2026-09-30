//
//  LocalSendService.swift
//  boringCode
//
//  LocalSend integrado ao notch: acha os aparelhos da rede, envia o que você
//  arrasta para o slot do Shelf e recebe sozinho (vai para Downloads e aparece
//  no Shelf). Não precisa do app LocalSend no Mac.
//

import AppKit
import Combine
import Defaults
import Foundation
import Network
import os
import SwiftUI

@MainActor
final class LocalSendService: ObservableObject {
    static let shared = LocalSendService()

    enum SendPhase: Equatable {
        /// Esperando o outro aparelho aceitar.
        case waiting
        case sending(Double)
        case done
        case failed(String)
    }

    struct Outgoing: Equatable {
        let deviceID: String
        var phase: SendPhase
    }

    struct Incoming: Equatable, Identifiable {
        let id: String
        let senderAlias: String
        let symbolName: String
        var fraction: Double
        var finished = false
        var failed = false
    }

    /// Aparelhos na rede, em ordem alfabética.
    @Published private(set) var devices: [LocalSendDevice] = []
    @Published private(set) var isSearching = false
    @Published private(set) var outgoing: Outgoing?
    /// Recebimento em andamento (ou acabou de terminar) — vira atividade no notch fechado.
    @Published private(set) var incoming: Incoming?
    @Published private(set) var isRunning = false

    private let queue = DispatchQueue(label: "com.reesoousa.boringcode.localsend")
    private lazy var server = LocalSendServer(queue: queue)
    private lazy var multicast = LocalSendMulticast(queue: queue)
    private let receiver = LocalSendReceiver()
    private var identity: LocalSendIdentity?
    private var client: LocalSendClient?
    /// Cópia do "quem sou eu" lida pela fila de rede.
    private let ownInfoLock = OSAllocatedUnfairLock(initialState: LocalSendInfo(alias: "boringCode", version: LocalSendProtocol.version, fingerprint: ""))
    private var serverPort = LocalSendProtocol.port
    private var sendTask: Task<Void, Never>?
    private var activeSession: (device: LocalSendDevice, id: String)?
    private var lastRefresh = Date.distantPast
    private var pathMonitor: NWPathMonitor?
    private var cancellables: Set<AnyCancellable> = []
    private var starting = false
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "boringcode", category: "LocalSend")

    private init() {}

    // MARK: - Ciclo de vida

    func start() {
        Defaults.publisher(.localSendEnabled)
            .map(\.newValue)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                if enabled { self?.startNetworking() } else { self?.stopNetworking() }
            }
            .store(in: &cancellables)
        Defaults.publisher(.localSendAlias)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateOwnInfo()
                self?.announce()
            }
            .store(in: &cancellables)
    }

    private func startNetworking() {
        guard !isRunning, !starting else { return }
        starting = true
        Task {
            let result = await Task.detached(priority: .utility) { Result { try LocalSendIdentity.loadOrCreate() } }.value
            starting = false
            switch result {
            case .success(let identity):
                guard Defaults[.localSendEnabled] else { return }
                launch(with: identity)
            case .failure(let error):
                log.error("LocalSend: sem identidade TLS: \(String(describing: error))")
            }
        }
    }

    private func launch(with identity: LocalSendIdentity) {
        self.identity = identity
        client = LocalSendClient(identity: identity)
        updateOwnInfo()

        receiver.ownInfo = { [ownInfoLock] in ownInfoLock.withLock { $0 } }
        receiver.isAccepting = { Defaults[.localSendReceive] }
        receiver.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        server.route = { [receiver] request in receiver.route(request) }
        server.onReady = { [weak self] port in
            Task { @MainActor in
                self?.serverPort = port
                self?.updateOwnInfo()
                self?.announce()
            }
        }
        multicast.onMessage = { [weak self] info, host in
            Task { @MainActor in self?.handleAnnouncement(info, host: host) }
        }

        server.start(identity: identity)
        multicast.start()
        watchNetwork()
        isRunning = true
    }

    private func stopNetworking() {
        guard isRunning else { return }
        cancelSend()
        server.stop()
        multicast.stop()
        pathMonitor?.cancel()
        pathMonitor = nil
        devices = []
        isRunning = false
    }

    /// Rede mudou (outro Wi-Fi, cabo): se anuncia de novo; quem sumiu sai na poda do refresh.
    private func watchNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self?.refresh(force: true)
            }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    private func updateOwnInfo() {
        let custom = Defaults[.localSendAlias].trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = custom.isEmpty ? (Host.current().localizedName ?? "boringCode") : custom
        let info = LocalSendInfo(
            alias: alias,
            version: LocalSendProtocol.version,
            deviceModel: "boringCode",
            deviceType: .desktop,
            fingerprint: identity?.fingerprint ?? "",
            port: serverPort,
            protocol: "https",
            download: false
        )
        ownInfoLock.withLock { $0 = info }
    }

    private var ownInfo: LocalSendInfo { ownInfoLock.withLock { $0 } }

    // MARK: - Descoberta

    /// Procura aparelhos (o Shelf chama ao abrir). Aparelhos que não responderem somem da lista.
    func refresh(force: Bool = false) {
        guard isRunning else { return }
        guard force || Date().timeIntervalSince(lastRefresh) > 4 else { return }
        let roundStart = Date()
        lastRefresh = roundStart
        isSearching = true
        announce()

        Task {
            await confirmKnownDevices()
            try? await Task.sleep(for: .seconds(2.5))
            if devices.isEmpty { await scanSubnet() }
            try? await Task.sleep(for: .seconds(2))
            guard lastRefresh == roundStart else { return }
            withAnimation(.smooth(duration: 0.3)) {
                devices.removeAll { $0.lastSeen < roundStart && $0.id != outgoing?.deviceID }
            }
            isSearching = false
        }
    }

    private func announce() {
        guard isRunning, identity != nil else { return }
        multicast.announce(ownInfo)
    }

    /// Aparelhos neste mesmo Mac (ex.: o app LocalSend) ficam fora da lista. Para testar:
    /// `defaults write com.reesoousa.boringcode localSendShowThisMac -bool true`.
    private func isThisMac(_ host: String) -> Bool {
        !UserDefaults.standard.bool(forKey: "localSendShowThisMac") && LocalSendNetwork.isOwnAddress(host)
    }

    private func handleAnnouncement(_ info: LocalSendInfo, host: String) {
        guard let client, info.fingerprint.uppercased() != identity?.fingerprint, !isThisMac(host) else { return }
        let https = info.protocol?.lowercased() != "http"
        let port = info.port ?? LocalSendProtocol.port
        if info.announce == false {
            upsert(LocalSendDevice(info: info, host: host))
            return
        }
        let own = ownInfo
        Task {
            // Responder por HTTP é o que o protocolo pede; o aparelho só entra na lista se responder.
            guard let response = try? await client.register(host: host, port: port, https: https, expectedFingerprint: info.fingerprint, info: own) else { return }
            upsert(LocalSendDevice(info: response, host: host, port: port, https: https, fingerprint: info.fingerprint))
        }
    }

    /// Pergunta direto aos aparelhos já conhecidos — não depende do multicast,
    /// que o macOS às vezes bloqueia (permissão de Rede Local).
    private func confirmKnownDevices() async {
        guard let client else { return }
        let own = ownInfo
        await withTaskGroup(of: LocalSendDevice?.self) { group in
            for device in devices {
                group.addTask {
                    guard let info = try? await client.register(host: device.host, port: device.port, https: device.https, expectedFingerprint: device.fingerprint, info: own, timeout: 2) else { return nil }
                    return LocalSendDevice(info: info, host: device.host, port: device.port, https: device.https, fingerprint: device.fingerprint)
                }
            }
            while let found = await group.next() {
                if let found { upsert(found) }
            }
        }
    }

    /// Reserva quando o multicast não chega (rede que bloqueia, macOS instável):
    /// pergunta direto a cada endereço da /24.
    private func scanSubnet() async {
        guard let client else { return }
        let own = ownInfo
        let hosts = LocalSendNetwork.subnetHosts()
        await withTaskGroup(of: LocalSendDevice?.self) { group in
            var iterator = hosts.makeIterator()
            func addNext() -> Bool {
                guard let host = iterator.next() else { return false }
                group.addTask {
                    guard let info = try? await client.register(host: host, port: LocalSendProtocol.port, https: true, expectedFingerprint: nil, info: own, timeout: 1.5) else { return nil }
                    return LocalSendDevice(info: info, host: host, port: LocalSendProtocol.port, https: true)
                }
                return true
            }
            for _ in 0..<48 where addNext() {}
            while let found = await group.next() {
                if let found { upsert(found) }
                _ = addNext()
            }
        }
    }

    private func upsert(_ device: LocalSendDevice) {
        guard device.fingerprint != identity?.fingerprint, !device.fingerprint.isEmpty,
              !isThisMac(device.host)
        else { return }
        var updated = devices
        if let index = updated.firstIndex(where: { $0.id == device.id }) {
            updated[index] = device
        } else {
            updated.append(device)
        }
        updated.sort { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
        if updated.map(\.id) != devices.map(\.id) {
            withAnimation(.smooth(duration: 0.3)) { devices = updated }
        } else {
            devices = updated
        }
    }

    // MARK: - Enviar

    /// Arquivos soltos no slot (ou escolhidos no clique) esperando você tocar num aparelho.
    struct Pending: Equatable {
        let id = UUID()
        let urls: [URL]
        let texts: [String]
        var count: Int { urls.count + texts.count }
    }

    @Published private(set) var pending: Pending?
    /// Lendo o que foi solto — o slot continua aberto enquanto isso (sem piscar).
    @Published private(set) var isPreparingPending = false

    func arm(_ providers: [NSItemProvider]) {
        isPreparingPending = true
        Task {
            let (urls, texts) = await Self.payload(from: providers)
            arm(urls: urls, texts: texts)
            isPreparingPending = false
        }
    }

    func arm(urls: [URL], texts: [String]) {
        guard !urls.isEmpty || !texts.isEmpty else { return }
        withAnimation(.smooth(duration: 0.3)) { pending = Pending(urls: urls, texts: texts) }
        refresh()
    }

    func sendPending(to device: LocalSendDevice) {
        guard let pending, !isSending else { return }
        withAnimation(.smooth(duration: 0.3)) { self.pending = nil }
        send(urls: pending.urls, texts: pending.texts, to: device)
    }

    func clearPending() {
        guard pending != nil else { return }
        withAnimation(.smooth(duration: 0.3)) { pending = nil }
    }

    var isSending: Bool {
        switch outgoing?.phase {
        case .waiting?, .sending?: true
        default: false
        }
    }

    /// Envia o que foi arrastado para o slot.
    func send(_ providers: [NSItemProvider], to device: LocalSendDevice) {
        guard !isSending else { return }
        withAnimation(.smooth(duration: 0.3)) { outgoing = Outgoing(deviceID: device.id, phase: .waiting) }
        Task {
            let (urls, texts) = await Self.payload(from: providers)
            send(urls: urls, texts: texts, to: device)
        }
    }

    func send(urls: [URL], texts: [String], to device: LocalSendDevice) {
        guard let client else { return }
        let files = LocalSendClient.outgoingFiles(for: urls) + texts.map(LocalSendClient.outgoingText)
        guard !files.isEmpty else {
            withAnimation(.smooth(duration: 0.3)) { outgoing = nil }
            return
        }
        withAnimation(.smooth(duration: 0.3)) { outgoing = Outgoing(deviceID: device.id, phase: .waiting) }

        let request = LocalSendPrepareUploadRequest(
            info: ownInfo,
            files: Dictionary(files.map { ($0.dto.id, $0.dto) }, uniquingKeysWith: { first, _ in first })
        )
        sendTask?.cancel()
        sendTask = Task {
            do {
                guard let response = try await client.prepareUpload(to: device, request: request) else {
                    finishSend(.done)
                    return
                }
                activeSession = (device, response.sessionId)
                let accepted = files.filter { response.files[$0.dto.id] != nil }
                let total = max(1, accepted.reduce(Int64(0)) { $0 + $1.dto.size })
                var completed: Int64 = 0
                setPhase(.sending(0))
                for file in accepted {
                    try Task.checkCancellation()
                    guard let token = response.files[file.dto.id] else { continue }
                    let base = completed
                    try await client.upload(to: device, sessionID: response.sessionId, fileID: file.dto.id, token: token, file: file.url, data: file.data) { sent in
                        Task { @MainActor [weak self] in
                            self?.setPhase(.sending(min(1, Double(base + sent) / Double(total))))
                        }
                    }
                    completed += file.dto.size
                }
                activeSession = nil
                finishSend(.done)
            } catch is CancellationError {
                if let activeSession { await client.cancel(device: activeSession.device, sessionID: activeSession.id) }
                activeSession = nil
                withAnimation(.smooth(duration: 0.3)) { outgoing = nil }
            } catch {
                activeSession = nil
                if case LocalSendError.unreachable = error {
                    withAnimation(.smooth(duration: 0.3)) { devices.removeAll { $0.id == device.id } }
                }
                finishSend(.failed(error.localizedDescription))
            }
        }
    }

    func cancelSend() {
        sendTask?.cancel()
        sendTask = nil
    }

    private func setPhase(_ phase: SendPhase) {
        guard outgoing != nil else { return }
        if case .sending = phase, case .sending = outgoing?.phase {
            outgoing?.phase = phase  // progresso: sem animar cada passo
        } else {
            withAnimation(.smooth(duration: 0.3)) { outgoing?.phase = phase }
        }
    }

    /// Mostra ✓ ou o erro por um instante e volta ao normal.
    private func finishSend(_ phase: SendPhase) {
        setPhase(phase)
        let deviceID = outgoing?.deviceID
        Task {
            try? await Task.sleep(for: .seconds(phase == .done ? 1.6 : 2.4))
            guard outgoing?.deviceID == deviceID, outgoing?.phase == phase else { return }
            withAnimation(.smooth(duration: 0.3)) { outgoing = nil }
        }
    }

    /// Arquivos, links e texto de um arraste.
    static func payload(from providers: [NSItemProvider]) async -> (urls: [URL], texts: [String]) {
        var urls: [URL] = []
        var texts: [String] = []
        for provider in providers {
            if let webURL = await provider.extractURL() {
                texts.append(webURL.absoluteString)
            } else if let fileURL = await provider.extractItem() {
                urls.append(fileURL)
            } else if let text = await provider.extractText() {
                texts.append(text)
            }
        }
        return (urls, texts)
    }

    // MARK: - Receber

    private func handle(_ event: LocalSendReceiver.Event) {
        switch event {
        case .register(let device):
            upsert(device)
        case .started(let id, let sender, _, _):
            withAnimation(.smooth(duration: 0.3)) {
                incoming = Incoming(id: id, senderAlias: sender.alias, symbolName: sender.symbolName, fraction: 0)
            }
        case .progress(let id, let fraction):
            guard incoming?.id == id else { return }
            incoming?.fraction = fraction
        case .finished(let id, let items):
            addToShelf(items)
            finishIncoming(id: id, failed: false)
        case .failed(let id):
            finishIncoming(id: id, failed: true)
        case .text(let text, let sender):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                ShelfStateViewModel.shared.add([ShelfItem(kind: .link(url: url))])
            } else {
                ShelfStateViewModel.shared.add([ShelfItem(kind: .text(string: text))])
            }
            let id = UUID().uuidString
            withAnimation(.smooth(duration: 0.3)) {
                incoming = Incoming(id: id, senderAlias: sender.alias, symbolName: sender.symbolName, fraction: 1)
            }
            finishIncoming(id: id, failed: false)
        }
    }

    private func addToShelf(_ urls: [URL]) {
        let items = urls.compactMap { url -> ShelfItem? in
            guard let bookmark = try? Bookmark(url: url) else { return nil }
            return ShelfItem(kind: .file(bookmark: bookmark.data))
        }
        ShelfStateViewModel.shared.add(items)
    }

    private func finishIncoming(id: String, failed: Bool) {
        guard incoming?.id == id else { return }
        withAnimation(.smooth(duration: 0.3)) {
            incoming?.fraction = failed ? (incoming?.fraction ?? 0) : 1
            incoming?.finished = true
            incoming?.failed = failed
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard incoming?.id == id else { return }
            withAnimation(.smooth(duration: 0.3)) { incoming = nil }
        }
    }
}
