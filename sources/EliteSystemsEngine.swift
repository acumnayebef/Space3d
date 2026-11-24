import Foundation
import SceneKit
import SwiftUI
import simd

enum StationEconomy: String {
    case highTech = "Высокие технологии"
    case mining = "Добыча"
    case industrial = "Индустриальная"
    case science = "Научная"
    case refinery = "Топливная"
    case frontier = "Фронтир"
}

struct SpaceStation: Identifiable {
    let id: String
    let name: String
    let parentBodyId: String
    let economy: StationEconomy
    let orbitAltitudeMeters: Double
    let orbitalPeriodSeconds: Double
    let initialPhaseRad: Double
    let inclinationRad: Double
    let radiusMeters: Double
    let accentHex: UInt32
    let summary: String

    func currentPosition(
        simulationTime: Double,
        cachedPositions: [String: SIMD3<Double>],
        allBodies: [CelestialBody]
    ) -> SIMD3<Double> {
        let parent = allBodies.first(where: { $0.id == parentBodyId })
        let parentPos = cachedPositions[parentBodyId]
            ?? parent?.currentPosition(simulationTime: simulationTime, allBodies: allBodies)
            ?? .zero
        let orbitRadius = (parent?.radiusMeters ?? 6_371_000.0) + orbitAltitudeMeters
        let angle: Double
        if orbitalPeriodSeconds > 0 {
            let omega = (2.0 * .pi) / orbitalPeriodSeconds
            angle = initialPhaseRad + omega * simulationTime
        } else {
            angle = initialPhaseRad
        }
        let cosLat = cos(inclinationRad)
        let offset = SIMD3<Double>(
            cos(angle) * cosLat * orbitRadius,
            sin(inclinationRad) * orbitRadius,
            -sin(angle) * cosLat * orbitRadius
        )
        return parentPos + offset
    }
}

struct TradeCommodity: Identifiable {
    let id: String
    let name: String
    let basePrice: Int

    func price(at economy: StationEconomy) -> Int {
        let mult: Double
        switch id {
        case "water_ice":
            switch economy {
            case .science: mult = 0.55
            case .refinery: mult = 0.65
            case .mining, .industrial: mult = 1.65
            case .frontier: mult = 1.45
            case .highTech: mult = 1.05
            }
        case "titanium":
            switch economy {
            case .mining: mult = 0.60
            case .industrial, .highTech: mult = 1.55
            case .frontier: mult = 1.30
            case .refinery, .science: mult = 1.00
            }
        case "deuterium":
            switch economy {
            case .refinery: mult = 0.55
            case .highTech, .frontier: mult = 1.50
            case .science: mult = 1.25
            case .mining, .industrial: mult = 1.15
            }
        case "superconductors":
            switch economy {
            case .industrial: mult = 0.65
            case .highTech, .science: mult = 1.50
            case .frontier: mult = 1.35
            case .mining, .refinery: mult = 1.05
            }
        case "med_tech":
            switch economy {
            case .highTech: mult = 0.65
            case .frontier, .mining: mult = 1.55
            case .industrial: mult = 1.20
            case .science, .refinery: mult = 1.05
            }
        case "exocrystals":
            switch economy {
            case .frontier: mult = 0.50
            case .highTech: mult = 1.65
            case .science: mult = 1.50
            case .industrial: mult = 1.25
            case .mining, .refinery: mult = 1.10
            }
        default:
            mult = 1.0
        }
        return max(10, Int((Double(basePrice) * mult).rounded()))
    }

    func demandTag(at economy: StationEconomy) -> String {
        let p = price(at: economy)
        if Double(p) <= Double(basePrice) * 0.72 { return "ЭКСПОРТ ↓" }
        if Double(p) >= Double(basePrice) * 1.40 { return "СПРОС ↑" }
        return "БАЛАНС"
    }
}

struct ExplorationScanRecord: Identifiable, Codable, Equatable {
    let id: String
    let bodyId: String
    let bodyName: String
    let scanType: String
    let payoutCredits: Int
    var sold: Bool
}

struct PilotProfile: Codable {
    var credits: Int = 10_000
    var cargo: [String: Int] = [:]
    var scans: [ExplorationScanRecord] = []
    var cargoLevel: Int = 0
    var fssLevel: Int = 0
    var jetpackLevel: Int = 0

    static let cargoCapacities = [20, 40, 80, 160]
    static let cargoUpgradeCosts = [15_000, 45_000, 120_000]
    static let fssMultipliers = [1.0, 1.5, 2.0, 3.0]
    static let fssUpgradeCosts = [12_000, 36_000, 90_000]
    static let jetpackDrains = [0.28, 0.18, 0.12]
    static let jetpackUpgradeCosts = [10_000, 32_000]

    private static let storageKey = "com.xantapers.spacesim.pilotProfile.v1"

    var cargoCapacityTons: Int {
        Self.cargoCapacities[max(0, min(Self.cargoCapacities.count - 1, cargoLevel))]
    }

    var usedCargoTons: Int {
        cargo.values.reduce(0, +)
    }

    var fssPayoutMultiplier: Double {
        Self.fssMultipliers[max(0, min(Self.fssMultipliers.count - 1, fssLevel))]
    }

    var jetpackDrainPerSec: Double {
        Self.jetpackDrains[max(0, min(Self.jetpackDrains.count - 1, jetpackLevel))]
    }

    var nextCargoUpgradeCost: Int? {
        (cargoLevel >= 0 && cargoLevel < Self.cargoUpgradeCosts.count) ? Self.cargoUpgradeCosts[cargoLevel] : nil
    }

    var nextFSSUpgradeCost: Int? {
        (fssLevel >= 0 && fssLevel < Self.fssUpgradeCosts.count) ? Self.fssUpgradeCosts[fssLevel] : nil
    }

    var nextJetpackUpgradeCost: Int? {
        (jetpackLevel >= 0 && jetpackLevel < Self.jetpackUpgradeCosts.count) ? Self.jetpackUpgradeCosts[jetpackLevel] : nil
    }

    var unsoldScanTotal: Int {
        scans.filter { !$0.sold }.reduce(0) { $0 + $1.payoutCredits }
    }

    var unsoldScanCount: Int {
        scans.filter { !$0.sold }.count
    }

    static func load() -> PilotProfile {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(PilotProfile.self, from: data) else {
            return PilotProfile()
        }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

final class EliteSystemsEngine {
    static let stations: [SpaceStation] = [
        SpaceStation(
            id: "station_earth_gateway",
            name: "Врата Земли",
            parentBodyId: "earth",
            economy: .highTech,
            orbitAltitudeMeters: 1_200_000,
            orbitalPeriodSeconds: 6_550,
            initialPhaseRad: 0.45,
            inclinationRad: 0.12,
            radiusMeters: 280.0,
            accentHex: 0x00E5FF,
            summary: "Главный орбитальный хаб человечества на низкой геоцентрической орбите."
        ),
        SpaceStation(
            id: "station_lunar_port",
            name: "Лунный Порт Артемида",
            parentBodyId: "moon",
            economy: .mining,
            orbitAltitudeMeters: 350_000,
            orbitalPeriodSeconds: 8_400,
            initialPhaseRad: 1.65,
            inclinationRad: 0.08,
            radiusMeters: 260.0,
            accentHex: 0xFFAA33,
            summary: "Орбитальный перевалочный узел добычи гелия-3, титана и лунного реголита."
        ),
        SpaceStation(
            id: "station_mars_olympus",
            name: "Олимп-Орбиталь",
            parentBodyId: "mars",
            economy: .industrial,
            orbitAltitudeMeters: 650_000,
            orbitalPeriodSeconds: 7_200,
            initialPhaseRad: 2.85,
            inclinationRad: 0.15,
            radiusMeters: 290.0,
            accentHex: 0xFF5A2A,
            summary: "Крупнейшая орбитальная верфь и машиностроительный комплекс Красной планеты."
        ),
        SpaceStation(
            id: "station_europa_lab",
            name: "Крио-Станция Европа",
            parentBodyId: "europa",
            economy: .science,
            orbitAltitudeMeters: 420_000,
            orbitalPeriodSeconds: 9_100,
            initialPhaseRad: 4.10,
            inclinationRad: 0.06,
            radiusMeters: 250.0,
            accentHex: 0x77DDFF,
            summary: "Научный комплекс Юпитерианской системы для изучения подлёдного океана Европы."
        ),
        SpaceStation(
            id: "station_titan_refinery",
            name: "Титан-Синтез",
            parentBodyId: "titan",
            economy: .refinery,
            orbitAltitudeMeters: 580_000,
            orbitalPeriodSeconds: 10_800,
            initialPhaseRad: 5.20,
            inclinationRad: 0.10,
            radiusMeters: 270.0,
            accentHex: 0xFFCC44,
            summary: "Топливный терминал Сатурна по переработке метана и синтезу дейтерия."
        ),
        SpaceStation(
            id: "station_proxima_outpost",
            name: "Аванпост Проксима",
            parentBodyId: "proxima_b",
            economy: .frontier,
            orbitAltitudeMeters: 900_000,
            orbitalPeriodSeconds: 6_900,
            initialPhaseRad: 0.95,
            inclinationRad: 0.18,
            radiusMeters: 300.0,
            accentHex: 0xAA66FF,
            summary: "Дальний межзвёздный форпост на орбите Proxima b — источник редких экзо-кристаллов."
        )
    ]

    static let commodities: [TradeCommodity] = [
        TradeCommodity(id: "water_ice", name: "Водяной лёд", basePrice: 140),
        TradeCommodity(id: "titanium", name: "Титановая руда", basePrice: 480),
        TradeCommodity(id: "deuterium", name: "Дейтерий-топливо", basePrice: 820),
        TradeCommodity(id: "superconductors", name: "Сверхпроводники", basePrice: 1_950),
        TradeCommodity(id: "med_tech", name: "Колониальное медоборудование", basePrice: 2_600),
        TradeCommodity(id: "exocrystals", name: "Экзо-кристаллы", basePrice: 5_400)
    ]

    static func fssFrequencyMHz(for body: CelestialBody) -> Double {
        let range: (min: Double, span: Double)
        switch body.category {
        case .solar, .all:
            range = (15.0, 13.0)
        case .moons, .stations:
            range = (29.0, 13.0)
        case .stars:
            range = (43.0, 15.0)
        case .exoplanets:
            range = (59.0, 15.0)
        case .blackHoles:
            range = (75.0, 11.0)
        case .galaxies:
            range = (87.0, 11.0)
        }
        var h: UInt64 = 0x9E3779B185EBCA87
        for byte in body.id.utf8 {
            h = (h ^ UInt64(byte)) &* 0x100000001B3
        }
        h ^= h >> 30
        let unit = Double(h & 0xFFFF) / 65535.0
        return ((range.min + unit * range.span) * 10.0).rounded() / 10.0
    }

    static func fssBasePayout(for body: CelestialBody) -> Int {
        switch body.category {
        case .moons: return 1_500
        case .solar: return 3_000
        case .stars: return 6_000
        case .exoplanets: return 12_000
        case .blackHoles: return 20_000
        case .galaxies: return 25_000
        case .all, .stations: return 3_000
        }
    }

    static func buildStationNode(for station: SpaceStation) -> SCNNode {
        let root = SCNNode()

        let hullDark = SCNMaterial()
        hullDark.lightingModel = .physicallyBased
        hullDark.diffuse.contents = UIColor(red: 0.16, green: 0.19, blue: 0.24, alpha: 1.0)
        hullDark.metalness.contents = 0.85
        hullDark.roughness.contents = 0.34

        let hullLight = SCNMaterial()
        hullLight.lightingModel = .physicallyBased
        hullLight.diffuse.contents = UIColor(red: 0.78, green: 0.82, blue: 0.88, alpha: 1.0)
        hullLight.metalness.contents = 0.65
        hullLight.roughness.contents = 0.26

        let solarMat = SCNMaterial()
        solarMat.lightingModel = .physicallyBased
        solarMat.diffuse.contents = UIColor(red: 0.06, green: 0.16, blue: 0.36, alpha: 1.0)
        solarMat.metalness.contents = 0.90
        solarMat.roughness.contents = 0.14

        let accentColor = UIColor(
            red: CGFloat((station.accentHex >> 16) & 0xFF) / 255.0,
            green: CGFloat((station.accentHex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(station.accentHex & 0xFF) / 255.0,
            alpha: 1.0
        )
        let glowMat = SCNMaterial()
        glowMat.lightingModel = .constant
        glowMat.diffuse.contents = accentColor
        glowMat.emission.contents = accentColor

        let slotInteriorMat = SCNMaterial()
        slotInteriorMat.lightingModel = .constant
        slotInteriorMat.diffuse.contents = UIColor(red: 0.05, green: 0.10, blue: 0.16, alpha: 1.0)
        slotInteriorMat.emission.contents = UIColor(red: 1.0, green: 0.72, blue: 0.24, alpha: 1.0)

        let windowTrimMat = SCNMaterial()
        windowTrimMat.lightingModel = .constant
        windowTrimMat.diffuse.contents = UIColor(red: 0.85, green: 0.94, blue: 1.0, alpha: 1.0)

        // Бронированная центральная ось вдоль Z
        let hubGeo = SCNCylinder(radius: 0.22, height: 1.48)
        hubGeo.radialSegmentCount = 24
        hubGeo.materials = [hullDark]
        let hubNode = SCNNode(geometry: hubGeo)
        hubNode.eulerAngles.x = .pi / 2.0
        root.addChildNode(hubNode)

        // Передний и кормовой док-модули со светящимся стыковочным шлюзом
        for zSign: Float in [1.0, -1.0] {
            let capGeo = SCNBox(width: 0.32, height: 0.24, length: 0.12, chamferRadius: 0.02)
            capGeo.materials = [hullLight]
            let cap = SCNNode(geometry: capGeo)
            cap.position = SCNVector3(0, 0, zSign * 0.74)
            root.addChildNode(cap)

            let slotGeo = SCNBox(width: 0.20, height: 0.08, length: 0.04, chamferRadius: 0.01)
            slotGeo.materials = [slotInteriorMat]
            let slot = SCNNode(geometry: slotGeo)
            slot.position = SCNVector3(0, 0, zSign * 0.80)
            root.addChildNode(slot)
        }

        // Жилой вращающийся тор
        let torusGeo = SCNTorus(ringRadius: 0.80, pipeRadius: 0.10)
        torusGeo.ringSegmentCount = 48
        torusGeo.pipeSegmentCount = 20
        torusGeo.materials = [hullLight]
        let torusNode = SCNNode(geometry: torusGeo)
        torusNode.eulerAngles.x = .pi / 2.0
        torusNode.position = SCNVector3(0, 0, 0.14)
        root.addChildNode(torusNode)

        // Светящееся кольцо иллюминаторов жилого тора
        let trimGeo = SCNTorus(ringRadius: 0.88, pipeRadius: 0.016)
        trimGeo.ringSegmentCount = 48
        trimGeo.pipeSegmentCount = 10
        trimGeo.materials = [windowTrimMat]
        let trimNode = SCNNode(geometry: trimGeo)
        trimNode.eulerAngles.x = .pi / 2.0
        trimNode.position = SCNVector3(0, 0, 0.14)
        root.addChildNode(trimNode)

        // 4 радиальные спицы
        let spokeGeo = SCNBox(width: 0.06, height: 1.56, length: 0.07, chamferRadius: 0.01)
        spokeGeo.materials = [hullDark]
        for angleDeg in [0.0, 90.0] {
            let spoke = SCNNode(geometry: spokeGeo)
            spoke.position = SCNVector3(0, 0, 0.14)
            spoke.eulerAngles.z = Float(angleDeg * .pi / 180.0)
            root.addChildNode(spoke)
        }

        // Солнечные батареи и радиаторы
        let wingGeo = SCNBox(width: 0.26, height: 0.72, length: 0.018, chamferRadius: 0.005)
        wingGeo.materials = [solarMat]
        for ySign: Float in [1.0, -1.0] {
            let wing = SCNNode(geometry: wingGeo)
            wing.position = SCNVector3(0, ySign * 0.58, -0.45)
            root.addChildNode(wing)
        }

        // Навигационные маяки
        let beaconGeo = SCNSphere(radius: 0.032)
        beaconGeo.segmentCount = 12
        beaconGeo.materials = [glowMat]
        let beaconOffsets: [SCNVector3] = [
            SCNVector3(0.82, 0, 0.22),
            SCNVector3(-0.82, 0, 0.22),
            SCNVector3(0, 0.94, -0.45),
            SCNVector3(0, -0.94, -0.45)
        ]
        for pos in beaconOffsets {
            let b = SCNNode(geometry: beaconGeo)
            b.position = pos
            root.addChildNode(b)
        }

        return root
    }
}

enum StationTab: String, CaseIterable, Identifiable {
    case market = "РЫНОК"
    case cartography = "КАРТОГРАФИЯ"
    case shipyard = "ВЕРФЬ"

    var id: String { rawValue }
}

struct StationServicesOverlay: View {
    @ObservedObject var sim: SpaceSimulationController
    @State private var activeTab: StationTab = .market

    var body: some View {
        if let station = sim.dockedStation {
            let profile = sim.pilotProfile
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(station.name.uppercased())
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .foregroundColor(.orange)
                        Text("Экономика: \(station.economy.rawValue)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.75))
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(profile.credits) CR")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow)
                        Text("Трюм: \(profile.usedCargoTons) / \(profile.cargoCapacityTons) т")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.cyan)
                    }

                    Button("ОТСТЫКОВКА") {
                        sim.undockFromStation()
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.red.opacity(0.82))
                    .clipShape(Capsule())
                }

                HStack(spacing: 8) {
                    ForEach(StationTab.allCases) { tab in
                        Button(action: { activeTab = tab }) {
                            HStack(spacing: 4) {
                                Text(tab.rawValue)
                                if tab == .cartography && profile.unsoldScanCount > 0 {
                                    Text("(\(profile.unsoldScanCount))")
                                        .foregroundColor(.yellow)
                                }
                            }
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(activeTab == tab ? .black : .white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(activeTab == tab ? Color.orange : Color.white.opacity(0.12))
                            .cornerRadius(6)
                        }
                    }
                    Spacer()
                }

                Divider().background(Color.orange.opacity(0.35))

                ScrollView {
                    switch activeTab {
                    case .market:
                        VStack(spacing: 6) {
                            ForEach(EliteSystemsEngine.commodities) { item in
                                let unitPrice = item.price(at: station.economy)
                                let tag = item.demandTag(at: station.economy)
                                let held = profile.cargo[item.id] ?? 0
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        HStack(spacing: 6) {
                                            Text("\(unitPrice) CR/т")
                                                .foregroundColor(.yellow)
                                            Text(tag)
                                                .foregroundColor(tag.contains("СПРОС") ? .green : (tag.contains("ЭКСПОРТ") ? .cyan : .gray))
                                            Text("• В трюме: \(held) т")
                                                .foregroundColor(.white.opacity(0.75))
                                        }
                                        .font(.system(size: 10, design: .monospaced))
                                    }
                                    Spacer()

                                    Button("Продать всё") {
                                        sim.sellCommodity(item, qty: held)
                                    }
                                    .disabled(held <= 0)
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(held > 0 ? Color.orange.opacity(0.75) : Color.white.opacity(0.08))
                                    .cornerRadius(6)

                                    Button("−1") {
                                        sim.sellCommodity(item, qty: 1)
                                    }
                                    .disabled(held <= 0)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(held > 0 ? Color.red.opacity(0.65) : Color.white.opacity(0.08))
                                    .cornerRadius(6)

                                    let freeSpace = profile.cargoCapacityTons - profile.usedCargoTons
                                    Button("+1") {
                                        sim.buyCommodity(item, qty: 1)
                                    }
                                    .disabled(freeSpace < 1 || profile.credits < unitPrice)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background((freeSpace >= 1 && profile.credits >= unitPrice) ? Color.cyan.opacity(0.55) : Color.white.opacity(0.08))
                                    .cornerRadius(6)

                                    Button("+5") {
                                        sim.buyCommodity(item, qty: 5)
                                    }
                                    .disabled(freeSpace < 5 || profile.credits < unitPrice * 5)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background((freeSpace >= 5 && profile.credits >= unitPrice * 5) ? Color.green.opacity(0.65) : Color.white.opacity(0.08))
                                    .cornerRadius(6)
                                }
                                .padding(8)
                                .background(Color.white.opacity(0.07))
                                .cornerRadius(8)
                            }
                        }

                    case .cartography:
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Universal Cartographics • Множитель FSS: ×\(String(format: "%.1f", profile.fssPayoutMultiplier))")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.cyan)
                                Spacer()
                                if profile.unsoldScanTotal > 0 {
                                    Button("ПРОДАТЬ ВСЕ ДАННЫЕ (+\(profile.unsoldScanTotal) CR)") {
                                        sim.sellAllCartographics()
                                    }
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Color.green)
                                    .cornerRadius(6)
                                }
                            }

                            if profile.scans.isEmpty {
                                Text("Пока нет разведданных. Используйте FSS-сканер в космосе или СКАНЕР при прогулке на планете.")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.65))
                                    .padding(.top, 16)
                            } else {
                                ForEach(profile.scans.reversed()) { rec in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(rec.bodyName)
                                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                            Text(rec.scanType)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.gray)
                                        }
                                        Spacer()
                                        if rec.sold {
                                            Text("ПРОДАНО")
                                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                                .foregroundColor(.gray)
                                        } else {
                                            Text("+\(rec.payoutCredits) CR")
                                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                .foregroundColor(.yellow)
                                        }
                                    }
                                    .padding(8)
                                    .background(Color.white.opacity(0.07))
                                    .cornerRadius(8)
                                }
                            }
                        }

                    case .shipyard:
                        VStack(spacing: 8) {
                            upgradeRow(
                                title: "Грузовой отсек (Ур. \(profile.cargoLevel + 1)/4)",
                                desc: "Текущая вместимость: \(profile.cargoCapacityTons) т",
                                cost: profile.nextCargoUpgradeCost,
                                credits: profile.credits
                            ) {
                                sim.upgradeCargo()
                            }

                            upgradeRow(
                                title: "Усилитель FSS-сканера (Ур. \(profile.fssLevel + 1)/4)",
                                desc: "Множитель выплат за открытия: ×\(String(format: "%.1f", profile.fssPayoutMultiplier))",
                                cost: profile.nextFSSUpgradeCost,
                                credits: profile.credits
                            ) {
                                sim.upgradeFSS()
                            }

                            upgradeRow(
                                title: "Реактивный ранец EVA (Ур. \(profile.jetpackLevel + 1)/3)",
                                desc: String(format: "Расход топлива: %.2f/с (заряд дольше на поверхностях)", profile.jetpackDrainPerSec),
                                cost: profile.nextJetpackUpgradeCost,
                                credits: profile.credits
                            ) {
                                sim.upgradeJetpack()
                            }
                        }
                    }
                }
            }
            .foregroundColor(.white)
            .padding(14)
            .frame(maxWidth: 660, maxHeight: 335)
            .background(Color.black.opacity(0.92))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.65), lineWidth: 1.5))
            .cornerRadius(14)
        }
    }

    @ViewBuilder
    private func upgradeRow(title: String, desc: String, cost: Int?, credits: Int, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                Text(desc)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.cyan)
            }
            Spacer()
            if let nextCost = cost {
                Button("Улучшить • \(nextCost) CR") {
                    action()
                }
                .disabled(credits < nextCost)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(credits >= nextCost ? Color.orange : Color.gray.opacity(0.4))
                .cornerRadius(6)
            } else {
                Text("МАКС. УРОВЕНЬ")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.green.opacity(0.18))
                    .cornerRadius(6)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.07))
        .cornerRadius(8)
    }
}

struct FSSScannerOverlay: View {
    @ObservedObject var sim: SpaceSimulationController

    var body: some View {
        let targetFreq = EliteSystemsEngine.fssFrequencyMHz(for: sim.targetBody)
        let isLocked = abs(sim.fssFrequencyMHz - targetFreq) <= 4.0
        let estPayout = Int((Double(EliteSystemsEngine.fssBasePayout(for: sim.targetBody)) * sim.pilotProfile.fssPayoutMultiplier).rounded())
        let alreadyScanned = sim.pilotProfile.scans.contains(where: { $0.id == "fss_\(sim.targetBody.id)" })

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundColor(.cyan)
                    Text("FSS-СКАНЕР ПОЛНОГО СПЕКТРА")
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                }
                Spacer()
                Button("ЗАКРЫТЬ") {
                    sim.isFSSOpen = false
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.cyan)
            }

            HStack(spacing: 10) {
                Text("Цель: \(sim.targetBody.name)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text(String(format: "%.1f МГц", sim.fssFrequencyMHz))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(isLocked ? .green : .orange)
                Spacer()
                Text(isLocked ? "ЗАХВАТ СИГНАЛА" : "ПОИСК ЧАСТОТЫ")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(isLocked ? .green : .yellow)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((isLocked ? Color.green : Color.orange).opacity(0.20))
                    .clipShape(Capsule())
            }

            // 36-полосный спектральный анализатор
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<36, id: \.self) { idx in
                    let barFreq = 10.0 + (Double(idx) / 35.0) * 90.0
                    let targetPeak = exp(-pow((barFreq - targetFreq) / 4.2, 2.0)) * 38.0
                    let cursorBoost = exp(-pow((barFreq - sim.fssFrequencyMHz) / 3.0, 2.0)) * 12.0
                    let otherPeak = UniverseCatalog.bodies.prefix(16).reduce(0.0) { acc, b in
                        let f = EliteSystemsEngine.fssFrequencyMHz(for: b)
                        return max(acc, exp(-pow((barFreq - f) / 2.2, 2.0)) * 18.0)
                    }
                    let barH = CGFloat(min(44.0, 6.0 + max(targetPeak, otherPeak) + cursorBoost * 0.35))
                    let nearCursor = abs(barFreq - sim.fssFrequencyMHz) < 2.8
                    RoundedRectangle(cornerRadius: 2)
                        .fill(nearCursor ? (isLocked ? Color.green : Color.orange) : Color.cyan.opacity(0.55))
                        .frame(width: 8, height: barH)
                }
            }
            .frame(height: 46, alignment: .bottom)
            .frame(maxWidth: .infinity)
            .padding(6)
            .background(Color.white.opacity(0.05))
            .cornerRadius(8)

            HStack(spacing: 8) {
                Text("10 МГц")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray)
                Slider(value: $sim.fssFrequencyMHz, in: 10.0...100.0)
                    .tint(isLocked ? .green : .cyan)
                Text("100 МГц")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray)
            }

            HStack(spacing: 10) {
                Button("АВТОНАСТРОЙКА НА ЦЕЛЬ") {
                    sim.autoTuneFSSToTarget()
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(Color.blue.opacity(0.8))
                .cornerRadius(8)

                Spacer()

                Button(alreadyScanned ? "УЖЕ ИЗУЧЕНО" : "СКАНИРОВАТЬ (+\(estPayout) CR)") {
                    sim.performFSSScan()
                }
                .disabled(!isLocked || alreadyScanned)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background((isLocked && !alreadyScanned) ? Color.green : Color.gray.opacity(0.4))
                .cornerRadius(8)
            }

            if !sim.lastFSSMessage.isEmpty {
                Text(sim.lastFSSMessage)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.cyan)
            }
        }
        .foregroundColor(.white)
        .padding(14)
        .frame(maxWidth: 460)
        .background(Color.black.opacity(0.90))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.cyan.opacity(0.55), lineWidth: 1.2))
        .cornerRadius(14)
    }
}
