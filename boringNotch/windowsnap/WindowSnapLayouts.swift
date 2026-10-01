//
//  WindowSnapLayouts.swift
//  boringCode
//
//  Layouts de encaixe de janelas: arraste uma janela até o notch e solte numa
//  zona para ela ocupar aquele pedaço da tela. Ideia inspirada nas "Snap Zones"
//  do Sapphire (github.com/cshariq/Sapphire, AGPL-3.0); código próprio.
//

import CoreGraphics
import Foundation

/// Um pedaço da área útil da tela (sem barra de menus e Dock), em frações de 0 a 1
/// com origem no canto superior esquerdo — o jeito como a gente desenha a miniatura.
struct SnapZone: Identifiable, Hashable {
    let id: String
    let rect: CGRect
    let title: String
}

struct SnapLayout: Identifiable, Hashable {
    let id: String
    let title: String
    let zones: [SnapZone]
}

extension SnapLayout {
    static let all: [SnapLayout] = [halves, thirds, focus, quarters, center, fill]

    static let halves = SnapLayout(
        id: "halves",
        title: String(localized: "Halves"),
        zones: [
            .init(id: "left", rect: .init(x: 0, y: 0, width: 0.5, height: 1), title: String(localized: "Left Half")),
            .init(id: "right", rect: .init(x: 0.5, y: 0, width: 0.5, height: 1), title: String(localized: "Right Half")),
        ]
    )

    static let thirds = SnapLayout(
        id: "thirds",
        title: String(localized: "Thirds"),
        zones: [
            .init(id: "left", rect: .init(x: 0, y: 0, width: 1.0 / 3, height: 1), title: String(localized: "Left Third")),
            .init(id: "center", rect: .init(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1), title: String(localized: "Center Third")),
            .init(id: "right", rect: .init(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1), title: String(localized: "Right Third")),
        ]
    )

    /// Uma janela principal larga e duas de apoio empilhadas à direita.
    static let focus = SnapLayout(
        id: "focus",
        title: String(localized: "Focus"),
        zones: [
            .init(id: "main", rect: .init(x: 0, y: 0, width: 2.0 / 3, height: 1), title: String(localized: "Left Two Thirds")),
            .init(id: "topRight", rect: .init(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 0.5), title: String(localized: "Top Right")),
            .init(id: "bottomRight", rect: .init(x: 2.0 / 3, y: 0.5, width: 1.0 / 3, height: 0.5), title: String(localized: "Bottom Right")),
        ]
    )

    static let quarters = SnapLayout(
        id: "quarters",
        title: String(localized: "Quarters"),
        zones: [
            .init(id: "topLeft", rect: .init(x: 0, y: 0, width: 0.5, height: 0.5), title: String(localized: "Top Left")),
            .init(id: "topRight", rect: .init(x: 0.5, y: 0, width: 0.5, height: 0.5), title: String(localized: "Top Right")),
            .init(id: "bottomLeft", rect: .init(x: 0, y: 0.5, width: 0.5, height: 0.5), title: String(localized: "Bottom Left")),
            .init(id: "bottomRight", rect: .init(x: 0.5, y: 0.5, width: 0.5, height: 0.5), title: String(localized: "Bottom Right")),
        ]
    )

    static let center = SnapLayout(
        id: "center",
        title: String(localized: "Center"),
        zones: [
            .init(id: "center", rect: .init(x: 0.2, y: 0.1, width: 0.6, height: 0.8), title: String(localized: "Center")),
        ]
    )

    static let fill = SnapLayout(
        id: "fill",
        title: String(localized: "Fill"),
        zones: [
            .init(id: "fill", rect: .init(x: 0, y: 0, width: 1, height: 1), title: String(localized: "Fill")),
        ]
    )
}

/// Zona escolhida durante o arraste (o mesmo id de zona pode existir em layouts diferentes).
struct SnapTarget: Equatable {
    let layoutID: String
    let zone: SnapZone
}
