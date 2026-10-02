//
//  ClipboardTabView.swift
//  boringCode
//
//  Aba "Clipboard" do notch aberto: o que você copiou por último, em cartões lado
//  a lado (texto, links, imagens, arquivos), com busca e filtros por tipo no topo.
//  Clique num cartão para colar no app em que você estava; botão direito para
//  copiar, abrir ou apagar.
//
//  Animações no mesmo jeito do monitor: ao abrir, os cartões chegam em cascata
//  (desfoque → nítido, com mola); item novo entra pela esquerda; o filtro
//  escolhido desliza como a cápsula da barra de abas.
//

import Defaults
import SwiftUI

struct ClipboardTabView: View {
    @ObservedObject private var history = ClipboardHistory.shared
    @EnvironmentObject private var vm: BoringViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var filter: ClipboardFilter = .all
    @State private var query = ""
    @State private var appeared = false
    @State private var window: NSWindow?
    @State private var confirmingClear = false
    @State private var clearResetTask: Task<Void, Never>?
    /// Cartão que acabou de ser copiado (sem colar sozinho): mostra "Copiado".
    @State private var copiedID: UUID?
    @FocusState private var searchFocused: Bool
    @Namespace private var filterNamespace

    private var filtered: [ClipboardItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return history.items.filter { item in
            filter.matches(item) && (trimmed.isEmpty || item.searchableText.localizedCaseInsensitiveContains(trimmed))
        }
    }

    private var listAnimation: Animation {
        reduceMotion ? .smooth(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.86)
    }

    var body: some View {
        Group {
            if history.access != .allowed {
                accessPrompt
            } else {
                VStack(spacing: 8) {
                    toolbar
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared || reduceMotion ? 0 : -4)
                        .animation(reduceMotion ? .smooth(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.85), value: appeared)
                    content
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ClipboardWindowReader(window: $window))
        .onAppear {
            history.refreshAccess()
            if reduceMotion {
                appeared = true
            } else {
                // Um quadro depois, para a cascata sair do começo.
                DispatchQueue.main.async { appeared = true }
            }
        }
        .onDisappear {
            appeared = false
            endSearch()
            confirmingClear = false
        }
        .onChange(of: searchFocused) { _, focused in
            if !focused { setTextInput(false) }
        }
    }

    // MARK: - Topo

    private var toolbar: some View {
        HStack(spacing: 8) {
            searchField
            filters
            Spacer(minLength: 0)
            clearButton
        }
        .frame(height: 26)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.gray)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .focused($searchFocused)
                .onSubmit {
                    if let first = filtered.first { select(first) }
                }
                .onExitCommand { endSearch() }
            if !query.isEmpty {
                Button {
                    withAnimation(.smooth(duration: 0.2)) { query = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 150, height: 26)
        .background(Capsule().fill(Color.white.opacity(searchFocused ? 0.12 : 0.06)))
        .animation(.smooth(duration: 0.2), value: searchFocused)
        .contentShape(Capsule())
        .onTapGesture { beginSearch() }
    }

    /// Como a barra de abas: a cápsula do filtro escolhido desliza até o novo.
    private var filters: some View {
        HStack(spacing: 0) {
            ForEach(ClipboardFilter.allCases) { option in
                let selected = filter == option
                Button {
                    withAnimation(reduceMotion ? .smooth(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.82)) {
                        filter = option
                    }
                } label: {
                    Text(option.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? .white : .gray)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color(nsColor: .secondarySystemFill))
                                    .matchedGeometryEffect(id: "filter", in: filterNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Lixeira que pede confirmação no próprio botão (sem janela): o primeiro clique
    /// vira "Limpar tudo", o segundo apaga; sozinho volta em 3 s.
    private var clearButton: some View {
        Button {
            if confirmingClear {
                clearResetTask?.cancel()
                withAnimation(listAnimation) {
                    history.clear()
                    confirmingClear = false
                }
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { confirmingClear = true }
                clearResetTask?.cancel()
                clearResetTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { confirmingClear = false }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                if confirmingClear {
                    Text("Clear All")
                        .font(.system(size: 11, weight: .semibold))
                        .fixedSize()
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .foregroundStyle(confirmingClear ? .white : .gray)
            .padding(.horizontal, confirmingClear ? 10 : 0)
            .frame(minWidth: 26, minHeight: 26)
            .background(Capsule().fill(confirmingClear ? Color.red.opacity(0.85) : Color.white.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(history.items.isEmpty)
        .opacity(history.items.isEmpty ? 0.4 : 1)
        .help(Text("Clear history"))
        .accessibilityLabel(Text("Clear history"))
    }

    // MARK: - Cartões

    @ViewBuilder
    private var content: some View {
        if history.items.isEmpty {
            emptyState(symbol: "doc.on.clipboard", title: "Copy something and it shows up here")
        } else if filtered.isEmpty {
            emptyState(symbol: "magnifyingglass", title: "Nothing found")
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                            ClipboardItemCard(
                                item: item,
                                appeared: appeared,
                                order: min(index, 7),
                                copied: copiedID == item.id,
                                onSelect: { select(item) },
                                onCopy: { copyOnly(item) },
                                onDelete: {
                                    withAnimation(listAnimation) { history.remove(item) }
                                }
                            )
                            .id(item.id)
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.88)),
                                    removal: .opacity.combined(with: .scale(scale: 0.88))
                                )
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.never)
                .animation(listAnimation, value: filtered.map(\.id))
                .onChange(of: history.items.first?.id) { _, id in
                    // Cópia nova com a aba aberta: volta ao começo para ela aparecer.
                    guard let id else { return }
                    withAnimation(listAnimation) { proxy.scrollTo(id, anchor: .leading) }
                }
            }
        }
    }

    private func emptyState(symbol: String, title: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.gray)
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.medium)
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(appeared ? 1 : 0)
        .blur(radius: appeared || reduceMotion ? 0 : 4)
        .animation(.smooth(duration: 0.35), value: appeared)
    }

    // MARK: - Permissão

    private var accessPrompt: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.gray)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("See everything you copy")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(history.access == .notRequested
                     ? "macOS will ask if boringCode can paste from other apps. Your history stays on this Mac."
                     : "Turn on boringCode in Privacy & Security › Paste from Other Apps.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                Task { await history.requestAccess() }
            } label: {
                Group {
                    if history.isRequestingAccess {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(history.access == .notRequested ? "Allow Access" : "Go to Settings")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(Color.white))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(history.isRequestingAccess)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.96)
        .blur(radius: appeared || reduceMotion ? 0 : 6)
        .animation(reduceMotion ? .smooth(duration: 0.2) : .spring(response: 0.6, dampingFraction: 0.82), value: appeared)
        .animation(.smooth(duration: 0.3), value: history.access)
    }

    // MARK: - Ações

    /// Cola no app em que você estava (o notch fecha); sem permissão para colar, só copia.
    private func select(_ item: ClipboardItem) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Com a busca em uso o notch tem o teclado: o ⌘V vai direto para o app de destino.
        let target = window?.isKeyWindow == true ? front : nil
        endSearch()
        Task { @MainActor in
            guard front != ownPID, await history.canPaste() else {
                copyOnly(item)
                return
            }
            history.copyToPasteboard(item)
            vm.close()
            _ = await history.sendPaste(targetPID: target)
        }
    }

    private func copyOnly(_ item: ClipboardItem) {
        history.copyToPasteboard(item)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { copiedID = item.id }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard copiedID == item.id else { return }
            withAnimation(.smooth(duration: 0.3)) { copiedID = nil }
        }
    }

    // MARK: - Teclado da busca

    /// O painel do notch só aceita teclado enquanto a busca está em uso.
    private func beginSearch() {
        setTextInput(true)
        DispatchQueue.main.async { searchFocused = true }
    }

    private func endSearch() {
        searchFocused = false
        setTextInput(false)
    }

    private func setTextInput(_ enabled: Bool) {
        (window as? BoringNotchSkyLightWindow)?.wantsKeyForTextInput = enabled
    }
}

/// Descobre a NSWindow onde a view está.
private struct ClipboardWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window !== nsView.window {
            DispatchQueue.main.async { window = nsView.window }
        }
    }
}
