import Foundation
import simd

enum BodyCategory: String, CaseIterable, Identifiable {
    case all = "Все"
    case solar = "Солнечная"
    case moons = "Спутники"
    case stars = "Звёзды"
    case exoplanets = "Экзопланеты"
    case blackHoles = "Чёрные дыры"
    case galaxies = "Галактики"

    var id: String { rawValue }
}

struct CelestialBody: Identifiable {
    let id: String
    let name: String
    let type: String
    let category: BodyCategory
    let semiMajorAxisMeters: Double   // Большая полуось орбиты или дистанция от Солнца (м)
    let orbitalPeriodSeconds: Double  // Сидерический период обращения (сек), 0 для дальних звёзд
    let initialPhaseRad: Double       // Долгота / прямое восхождение (рад)
    let latitudeRad: Double           // Широта / склонение (рад)
    let parentId: String?
    let radiusMeters: Double
    let massKg: Double
    let axialTiltRad: Double
    let rotationPeriodSeconds: Double
    let meanTempK: Int                // Средняя температура (Кельвины)
    let colorHex: UInt32
    let secondaryHex: UInt32
    let isStar: Bool
    let isBlackHole: Bool
    let isGalaxy: Bool
    let hasAtmosphere: Bool
    let hasRings: Bool
    let cloudCoverage: Float
    let summary: String

    init(
        id: String,
        name: String,
        type: String,
        category: BodyCategory,
        semiMajorAxisMeters: Double,
        orbitalPeriodSeconds: Double,
        initialPhaseRad: Double,
        latitudeRad: Double,
        parentId: String?,
        radiusMeters: Double,
        massKg: Double,
        axialTiltRad: Double,
        rotationPeriodSeconds: Double,
        meanTempK: Int,
        colorHex: UInt32,
        secondaryHex: UInt32,
        isStar: Bool,
        isBlackHole: Bool = false,
        isGalaxy: Bool = false,
        hasAtmosphere: Bool,
        hasRings: Bool,
        cloudCoverage: Float = 0.0,
        summary: String
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.category = category
        self.semiMajorAxisMeters = semiMajorAxisMeters
        self.orbitalPeriodSeconds = orbitalPeriodSeconds
        self.initialPhaseRad = initialPhaseRad
        self.latitudeRad = latitudeRad
        self.parentId = parentId
        self.radiusMeters = radiusMeters
        self.massKg = massKg
        self.axialTiltRad = axialTiltRad
        self.rotationPeriodSeconds = rotationPeriodSeconds
        self.meanTempK = meanTempK
        self.colorHex = colorHex
        self.secondaryHex = secondaryHex
        self.isStar = isStar
        self.isBlackHole = isBlackHole
        self.isGalaxy = isGalaxy
        self.hasAtmosphere = hasAtmosphere
        self.hasRings = hasRings
        self.cloudCoverage = cloudCoverage
        self.summary = summary
    }

    static let G: Double = 6.67430e-11

    /// Текущая 3D-позиция в метрах в гелиоцентрической системе координат (1:1)
    func currentPosition(simulationTime: Double, allBodies: [CelestialBody]) -> SIMD3<Double> {
        let parentPos: SIMD3<Double>
        if let pid = parentId, let parent = allBodies.first(where: { $0.id == pid }) {
            parentPos = parent.currentPosition(simulationTime: simulationTime, allBodies: allBodies)
        } else {
            parentPos = .zero
        }

        guard semiMajorAxisMeters > 0 else {
            return parentPos
        }

        let angle: Double
        if orbitalPeriodSeconds > 0 {
            let angularVelocity = (2.0 * .pi) / orbitalPeriodSeconds
            angle = initialPhaseRad + angularVelocity * simulationTime
        } else {
            angle = initialPhaseRad
        }

        let cosLat = cos(latitudeRad)
        let x = cos(angle) * cosLat * semiMajorAxisMeters
        let y = sin(latitudeRad) * semiMajorAxisMeters
        let z = -sin(angle) * cosLat * semiMajorAxisMeters
        return parentPos + SIMD3<Double>(x, y, z)
    }

    /// Позиция точки на орбите по углу (для отрисовки 3D-линий орбит)
    func orbitPoint(angle: Double, parentPos: SIMD3<Double>) -> SIMD3<Double> {
        let cosLat = cos(latitudeRad)
        let x = cos(angle) * cosLat * semiMajorAxisMeters
        let y = sin(latitudeRad) * semiMajorAxisMeters
        let z = -sin(angle) * cosLat * semiMajorAxisMeters
        return parentPos + SIMD3<Double>(x, y, z)
    }

    /// Гравитация на поверхности в единицах g
    var surfaceGravityG: Double {
        guard radiusMeters > 0 else { return 0 }
        let gSurface = (Self.G * massKg) / (radiusMeters * radiusMeters)
        return gSurface / 9.80665
    }

    /// Первая космическая скорость у поверхности (м/с)
    var firstCosmicVelocityMps: Double {
        guard radiusMeters > 0 else { return 0 }
        return sqrt((Self.G * massKg) / radiusMeters)
    }

    /// Вторая космическая скорость / скорость убегания (м/с)
    var escapeVelocityMps: Double {
        guard radiusMeters > 0 else { return 0 }
        return sqrt((2.0 * Self.G * massKg) / radiusMeters)
    }

    /// Температура в градусах Цельсия
    var meanTempC: Int {
        meanTempK - 273
    }

    var isGasGiant: Bool {
        id == "jupiter" || id == "saturn" || id == "uranus" || id == "neptune" || id == "dimidium" || id == "hd189733b"
    }

    var isHabitableWorld: Bool {
        id == "earth" || id == "proxima_b" || id == "trappist1e" || id == "kepler186f" || id == "kepler442b"
    }

    var isIcyWorld: Bool {
        id == "europa" || id == "enceladus" || id == "ganymede" || id == "callisto" || id == "triton" || id == "pluto" || id == "charon" || id == "eris"
    }

    var isLandable: Bool {
        !isStar && !isGasGiant && !isBlackHole && !isGalaxy
    }

    var atmosphereHeightMeters: Double {
        switch id {
        case "earth", "proxima_b", "trappist1e", "kepler186f", "kepler442b":
            return 120_000
        case "mars", "trappist1d", "trappist1f", "trappist1g":
            return 80_000
        case "venus", "trappist1b":
            return 160_000
        case "titan":
            return 200_000
        case "jupiter", "saturn", "uranus", "neptune", "dimidium", "hd189733b":
            return 240_000
        default:
            return 0
        }
    }

    var atmospherePalette: (zenith: SIMD3<Float>, horizon: SIMD3<Float>, sunset: SIMD3<Float>, fog: SIMD3<Float>) {
        switch id {
        case "earth", "kepler442b":
            return (
                SIMD3<Float>(0.08, 0.28, 0.78),
                SIMD3<Float>(0.48, 0.76, 1.00),
                SIMD3<Float>(1.00, 0.42, 0.14),
                SIMD3<Float>(0.55, 0.74, 0.96)
            )
        case "proxima_b", "trappist1e", "kepler186f":
            return (
                SIMD3<Float>(0.12, 0.34, 0.68),
                SIMD3<Float>(0.52, 0.76, 0.88),
                SIMD3<Float>(1.00, 0.34, 0.16),
                SIMD3<Float>(0.58, 0.68, 0.78)
            )
        case "mars", "trappist1d", "trappist1f", "trappist1g":
            return (
                SIMD3<Float>(0.58, 0.28, 0.16),
                SIMD3<Float>(0.88, 0.56, 0.36),
                SIMD3<Float>(0.82, 0.30, 0.14),
                SIMD3<Float>(0.82, 0.50, 0.34)
            )
        case "venus", "trappist1b":
            return (
                SIMD3<Float>(0.76, 0.54, 0.22),
                SIMD3<Float>(0.95, 0.78, 0.44),
                SIMD3<Float>(0.92, 0.48, 0.16),
                SIMD3<Float>(0.88, 0.70, 0.38)
            )
        case "titan":
            return (
                SIMD3<Float>(0.68, 0.42, 0.14),
                SIMD3<Float>(0.92, 0.64, 0.26),
                SIMD3<Float>(0.88, 0.34, 0.10),
                SIMD3<Float>(0.84, 0.56, 0.24)
            )
        case "neptune", "uranus", "hd189733b":
            return (
                SIMD3<Float>(0.10, 0.36, 0.82),
                SIMD3<Float>(0.34, 0.74, 0.98),
                SIMD3<Float>(0.22, 0.48, 0.88),
                SIMD3<Float>(0.32, 0.68, 0.94)
            )
        default:
            return (
                SIMD3<Float>(0.62, 0.48, 0.34),
                SIMD3<Float>(0.86, 0.72, 0.54),
                SIMD3<Float>(0.88, 0.48, 0.22),
                SIMD3<Float>(0.78, 0.64, 0.48)
            )
        }
    }
}

final class UniverseCatalog {
    static let au: Double = 149_597_870_700.0
    static let ly: Double = 9_460_730_472_580_800.0
    static let day: Double = 86_400.0

    /// Преобразование реальных экваториальных координат J2000 (прямое восхождение в часах и склонение в градусах)
    static func celestialPhaseLat(raHours: Double, decDeg: Double) -> (phase: Double, lat: Double) {
        (raHours * .pi / 12.0, decDeg * .pi / 180.0)
    }

    static let bodies: [CelestialBody] = {
        let pProxima = celestialPhaseLat(raHours: 14.495, decDeg: -62.68)
        let pAlphaCen = celestialPhaseLat(raHours: 14.660, decDeg: -60.83)
        let pSirius = celestialPhaseLat(raHours: 6.752, decDeg: -16.72)
        let pTauCeti = celestialPhaseLat(raHours: 1.735, decDeg: -15.94)
        let pVega = celestialPhaseLat(raHours: 18.616, decDeg: 38.78)
        let pArcturus = celestialPhaseLat(raHours: 14.261, decDeg: 19.18)
        let pTrappist = celestialPhaseLat(raHours: 23.108, decDeg: -5.04)
        let p51Peg = celestialPhaseLat(raHours: 22.958, decDeg: 20.77)
        let pHD189 = celestialPhaseLat(raHours: 20.012, decDeg: 22.71)
        let pAldebaran = celestialPhaseLat(raHours: 4.599, decDeg: 16.51)
        let pPolaris = celestialPhaseLat(raHours: 2.530, decDeg: 89.26)
        let pBetelgeuse = celestialPhaseLat(raHours: 5.919, decDeg: 7.41)
        let pKepler186 = celestialPhaseLat(raHours: 19.910, decDeg: 43.95)
        let pRigel = celestialPhaseLat(raHours: 5.242, decDeg: -8.20)
        let pKepler442 = celestialPhaseLat(raHours: 19.131, decDeg: 39.28)
        let pCrab = celestialPhaseLat(raHours: 5.575, decDeg: 22.01)
        let pUYScuti = celestialPhaseLat(raHours: 18.460, decDeg: -12.46)
        let pStephens = celestialPhaseLat(raHours: 18.651, decDeg: -6.03)

        let pSgrA = celestialPhaseLat(raHours: 17.761, decDeg: -29.01)
        let pCygX1 = celestialPhaseLat(raHours: 19.973, decDeg: 35.20)
        let pM87 = celestialPhaseLat(raHours: 12.514, decDeg: 12.39)
        let pTON618 = celestialPhaseLat(raHours: 12.473, decDeg: 31.48)

        let pLMC = celestialPhaseLat(raHours: 5.393, decDeg: -69.76)
        let pM31 = celestialPhaseLat(raHours: 0.712, decDeg: 41.27)
        let pM33 = celestialPhaseLat(raHours: 1.564, decDeg: 30.66)
        let pM51 = celestialPhaseLat(raHours: 13.498, decDeg: 47.20)
        let pM104 = celestialPhaseLat(raHours: 12.667, decDeg: -11.62)
        let pIC1101 = celestialPhaseLat(raHours: 15.183, decDeg: 5.74)

        return [
            // MARK: - Солнечная система
            CelestialBody(id: "sun", name: "Солнце", type: "Звезда G2V", category: .solar, semiMajorAxisMeters: 0, orbitalPeriodSeconds: 0, initialPhaseRad: 0, latitudeRad: 0, parentId: nil, radiusMeters: 696_340_000, massKg: 1.9885e30, axialTiltRad: 0.126, rotationPeriodSeconds: 25.38 * day, meanTempK: 5778, colorHex: 0xFFCC44, secondaryHex: 0xFF6600, isStar: true, hasAtmosphere: false, hasRings: false, summary: "Жёлтый карлик главной последовательности, содержащий 99.86% массы Солнечной системы."),
            CelestialBody(id: "mercury", name: "Меркурий", type: "Планета земной группы", category: .solar, semiMajorAxisMeters: 0.387098 * au, orbitalPeriodSeconds: 87.969 * day, initialPhaseRad: 0.4, latitudeRad: 0.05, parentId: "sun", radiusMeters: 2_439_700, massKg: 3.3011e23, axialTiltRad: 0.0005, rotationPeriodSeconds: 58.646 * day, meanTempK: 440, colorHex: 0x948F88, secondaryHex: 0x524E48, isStar: false, hasAtmosphere: false, hasRings: false, summary: "Ближайшая к Солнцу и самая маленькая планета системы с огромным железным ядром."),
            CelestialBody(id: "venus", name: "Венера", type: "Планета земной группы", category: .solar, semiMajorAxisMeters: 0.723332 * au, orbitalPeriodSeconds: 224.701 * day, initialPhaseRad: 2.1, latitudeRad: -0.02, parentId: "sun", radiusMeters: 6_051_800, massKg: 4.8675e24, axialTiltRad: 3.095, rotationPeriodSeconds: -243.025 * day, meanTempK: 737, colorHex: 0xE6B87D, secondaryHex: 0xB87A38, isStar: false, hasAtmosphere: true, hasRings: false, cloudCoverage: 0.96, summary: "Плотная углекислотная атмосфера создаёт экстремальный парниковый эффект и давление 92 атм."),
            CelestialBody(id: "earth", name: "Земля", type: "Обитаемая планета", category: .solar, semiMajorAxisMeters: 1.000000 * au, orbitalPeriodSeconds: 365.256 * day, initialPhaseRad: .pi, latitudeRad: 0, parentId: "sun", radiusMeters: 6_371_000, massKg: 5.97237e24, axialTiltRad: 0.4091, rotationPeriodSeconds: 86_164.1, meanTempK: 288, colorHex: 0x164E9C, secondaryHex: 0x3B8C4E, isStar: false, hasAtmosphere: true, hasRings: false, cloudCoverage: 0.72, summary: "Единственное известное небесное тело с жидкой водой на поверхности и развитой биосферой."),
            CelestialBody(id: "mars", name: "Марс", type: "Планета земной группы", category: .solar, semiMajorAxisMeters: 1.523679 * au, orbitalPeriodSeconds: 686.980 * day, initialPhaseRad: 1.3, latitudeRad: 0.02, parentId: "sun", radiusMeters: 3_389_500, massKg: 6.4171e23, axialTiltRad: 0.4396, rotationPeriodSeconds: 88_642.6, meanTempK: 210, colorHex: 0xC8522E, secondaryHex: 0x692311, isStar: false, hasAtmosphere: true, hasRings: false, cloudCoverage: 0.22, summary: "Холодная пустынная планета с разреженной атмосферой и крупнейшим вулканом Олимп."),
            CelestialBody(id: "ceres", name: "Церера", type: "Карликовая планета", category: .solar, semiMajorAxisMeters: 2.7675 * au, orbitalPeriodSeconds: 1681.63 * day, initialPhaseRad: 3.1, latitudeRad: 0.185, parentId: "sun", radiusMeters: 469_730, massKg: 9.3835e20, axialTiltRad: 0.07, rotationPeriodSeconds: 32_666.0, meanTempK: 168, colorHex: 0x7A7875, secondaryHex: 0x454340, isStar: false, hasAtmosphere: false, hasRings: false, summary: "Крупнейший объект Главного пояса астероидов между орбитами Марса и Юпитера."),
            CelestialBody(id: "jupiter", name: "Юпитер", type: "Газовый гигант", category: .solar, semiMajorAxisMeters: 5.2044 * au, orbitalPeriodSeconds: 4332.59 * day, initialPhaseRad: 5.2, latitudeRad: -0.01, parentId: "sun", radiusMeters: 69_911_000, massKg: 1.8982e27, axialTiltRad: 0.0546, rotationPeriodSeconds: 35_730, meanTempK: 165, colorHex: 0xD8B088, secondaryHex: 0x8F5230, isStar: false, hasAtmosphere: true, hasRings: false, cloudCoverage: 0.85, summary: "Крупнейшая планета Солнечной системы с мощнейшим магнитным полем и ураганами."),
            CelestialBody(id: "saturn", name: "Сатурн", type: "Газовый гигант", category: .solar, semiMajorAxisMeters: 9.5826 * au, orbitalPeriodSeconds: 10759.22 * day, initialPhaseRad: 3.7, latitudeRad: 0.03, parentId: "sun", radiusMeters: 58_232_000, massKg: 5.6834e26, axialTiltRad: 0.4665, rotationPeriodSeconds: 38_362, meanTempK: 134, colorHex: 0xE8D49E, secondaryHex: 0xB39252, isStar: false, hasAtmosphere: true, hasRings: true, cloudCoverage: 0.80, summary: "Обладает самой развитой системой ледяных колец и средней плотностью ниже воды."),
            CelestialBody(id: "uranus", name: "Уран", type: "Ледяной гигант", category: .solar, semiMajorAxisMeters: 19.2184 * au, orbitalPeriodSeconds: 30688.5 * day, initialPhaseRad: 4.5, latitudeRad: -0.01, parentId: "sun", radiusMeters: 25_362_000, massKg: 8.6810e25, axialTiltRad: 1.706, rotationPeriodSeconds: -62_064, meanTempK: 76, colorHex: 0x84E6F5, secondaryHex: 0x4CB3C9, isStar: false, hasAtmosphere: true, hasRings: true, cloudCoverage: 0.75, summary: "Вращается практически «лёжа на боку» с наклоном оси 97.7° и тонкими тёмными кольцами."),
            CelestialBody(id: "neptune", name: "Нептун", type: "Ледяной гигант", category: .solar, semiMajorAxisMeters: 30.11 * au, orbitalPeriodSeconds: 60195.0 * day, initialPhaseRad: 0.2, latitudeRad: 0.02, parentId: "sun", radiusMeters: 24_622_000, massKg: 1.02413e26, axialTiltRad: 0.494, rotationPeriodSeconds: 57_996, meanTempK: 72, colorHex: 0x3666FF, secondaryHex: 0x1A3494, isStar: false, hasAtmosphere: true, hasRings: false, cloudCoverage: 0.78, summary: "Самая далёкая планета системы со сверхзвуковыми ветрами до 2100 км/ч."),
            CelestialBody(id: "pluto", name: "Плутон", type: "Карликовая планета", category: .solar, semiMajorAxisMeters: 39.482 * au, orbitalPeriodSeconds: 90560.0 * day, initialPhaseRad: 5.05, latitudeRad: 0.299, parentId: "sun", radiusMeters: 1_188_300, massKg: 1.303e22, axialTiltRad: 2.138, rotationPeriodSeconds: -6.387 * day, meanTempK: 44, colorHex: 0xD4B99B, secondaryHex: 0x6E4836, isStar: false, hasAtmosphere: false, hasRings: false, summary: "Ледяной карлик пояса Койпера с азотными ледниками Равнины Спутника и наклоном орбиты 17°."),
            CelestialBody(id: "eris", name: "Эрида", type: "Карликовая планета", category: .solar, semiMajorAxisMeters: 67.864 * au, orbitalPeriodSeconds: 204199.0 * day, initialPhaseRad: 0.65, latitudeRad: 0.769, parentId: "sun", radiusMeters: 1_163_000, massKg: 1.6466e22, axialTiltRad: 0.78, rotationPeriodSeconds: 93_240.0, meanTempK: 42, colorHex: 0xE6EAEF, secondaryHex: 0x9AA6B5, isStar: false, hasAtmosphere: false, hasRings: false, summary: "Массивная карликовая планета рассеянного диска с крайне высоким альбедо метанового льда."),

            // MARK: - Спутники
            CelestialBody(id: "moon", name: "Луна", type: "Спутник Земли", category: .moons, semiMajorAxisMeters: 384_400_000, orbitalPeriodSeconds: 27.32166 * day, initialPhaseRad: 0.85, latitudeRad: 0.089, parentId: "earth", radiusMeters: 1_737_400, massKg: 7.342e22, axialTiltRad: 0.116, rotationPeriodSeconds: 27.32166 * day, meanTempK: 220, colorHex: 0xC4C4C4, secondaryHex: 0x6A6A6A, isStar: false, hasAtmosphere: false, hasRings: false, summary: "Естественный спутник Земли, находящийся в приливном захвате."),
            CelestialBody(id: "phobos", name: "Фобос", type: "Спутник Марса", category: .moons, semiMajorAxisMeters: 9_376_000, orbitalPeriodSeconds: 0.3189 * day, initialPhaseRad: 1.1, latitudeRad: 0.019, parentId: "mars", radiusMeters: 11_267, massKg: 1.0659e16, axialTiltRad: 0, rotationPeriodSeconds: 0.3189 * day, meanTempK: 233, colorHex: 0x7A6C64, secondaryHex: 0x423833, isStar: false, hasAtmosphere: false, hasRings: false, summary: "Крошечный спутник Марса на сверхнизкой орбите с гигантским кратером Стикни."),
            CelestialBody(id: "io", name: "Ио", type: "Спутник Юпитера", category: .moons, semiMajorAxisMeters: 421_700_000, orbitalPeriodSeconds: 1.7691 * day, initialPhaseRad: 0.5, latitudeRad: 0.001, parentId: "jupiter", radiusMeters: 1_821_600, massKg: 8.9319e22, axialTiltRad: 0, rotationPeriodSeconds: 1.7691 * day, meanTempK: 110, colorHex: 0xE6C43E, secondaryHex: 0x9C4018, isStar: false, hasAtmosphere: false, hasRings: false, summary: "Самое вулканически активное тело Солнечной системы из-за приливного разогрева Юпитером."),
            CelestialBody(id: "europa", name: "Европа", type: "Ледяной спутник Юпитера", category: .moons, semiMajorAxisMeters: 671_034_000, orbitalPeriodSeconds: 3.5512 * day, initialPhaseRad: 2.2, latitudeRad: 0.008, parentId: "jupiter", radiusMeters: 1_560_800, massKg: 4.7998e22, axialTiltRad: 0.002, rotationPeriodSeconds: 3.5512 * day, meanTempK: 102, colorHex: 0xD2E4F0, secondaryHex: 0x8A6D54, isStar: false, hasAtmosphere: false, hasRings: false, summary: "Гладкая ледяная кора скрывает глобальный подлёдный солёный океан глубиной ~100 км."),
            CelestialBody(id: "ganymede", name: "Ганимед", type: "Спутник Юпитера", category: .moons, semiMajorAxisMeters: 1_070_412_000, orbitalPeriodSeconds: 7.1546 * day, initialPhaseRad: 3.9, latitudeRad: 0.003, parentId: "jupiter", radiusMeters: 2_634_100, massKg: 1.4819e23, axialTiltRad: 0.003, rotationPeriodSeconds: 7.1546 * day, meanTempK: 110, colorHex: 0xA49C94, secondaryHex: 0x5E5852, isStar: false, hasAtmosphere: false, hasRings: false, summary: "Крупнейший спутник Солнечной системы (больше Меркурия), обладающий собственным магнитным полем."),
            CelestialBody(id: "callisto", name: "Каллисто", type: "Спутник Юпитера", category: .moons, semiMajorAxisMeters: 1_882_709_000, orbitalPeriodSeconds: 16.689 * day, initialPhaseRad: 5.1, latitudeRad: 0.003, parentId: "jupiter", radiusMeters: 2_410_300, massKg: 1.0759e23, axialTiltRad: 0, rotationPeriodSeconds: 16.689 * day, meanTempK: 134, colorHex: 0x7E7872, secondaryHex: 0x3D3A37, isStar: false, hasAtmosphere: false, hasRings: false, summary: "Древнейшая сильно кратерированная ледово-каменная поверхность у внешней границы магнитосферы Юпитера."),
            CelestialBody(id: "titan", name: "Титан", type: "Спутник Сатурна", category: .moons, semiMajorAxisMeters: 1_221_870_000, orbitalPeriodSeconds: 15.945 * day, initialPhaseRad: 1.8, latitudeRad: 0.006, parentId: "saturn", radiusMeters: 2_574_730, massKg: 1.3452e23, axialTiltRad: 0.005, rotationPeriodSeconds: 15.945 * day, meanTempK: 94, colorHex: 0xD9963A, secondaryHex: 0x8F5618, isStar: false, hasAtmosphere: true, hasRings: false, cloudCoverage: 0.96, summary: "Единственный спутник с плотной азотно-метановой атмосферой (1.45 атм) и углеводородными морями."),
            CelestialBody(id: "enceladus", name: "Энцелад", type: "Ледяной спутник Сатурна", category: .moons, semiMajorAxisMeters: 237_948_000, orbitalPeriodSeconds: 1.3702 * day, initialPhaseRad: 4.4, latitudeRad: 0.0003, parentId: "saturn", radiusMeters: 252_100, massKg: 1.0802e20, axialTiltRad: 0, rotationPeriodSeconds: 1.3702 * day, meanTempK: 75, colorHex: 0xF0F6FC, secondaryHex: 0x7EAED4, isStar: false, hasAtmosphere: false, hasRings: false, summary: "Ослепительно белый ледяной мир с криовулканами, выбрасывающими гейзеры водяного пара в космос."),
            CelestialBody(id: "triton", name: "Тритон", type: "Спутник Нептуна", category: .moons, semiMajorAxisMeters: 354_759_000, orbitalPeriodSeconds: 5.8769 * day, initialPhaseRad: 2.9, latitudeRad: 0.40, parentId: "neptune", radiusMeters: 1_353_400, massKg: 2.139e22, axialTiltRad: 0, rotationPeriodSeconds: 5.8769 * day, meanTempK: 38, colorHex: 0xD8CCD2, secondaryHex: 0x8A7880, isStar: false, hasAtmosphere: false, hasRings: false, summary: "Захваченный объект пояса Койпера с действующими азотными гейзерами и экстремальным холодом -235 °C."),
            CelestialBody(id: "charon", name: "Харон", type: "Спутник Плутона", category: .moons, semiMajorAxisMeters: 19_591_000, orbitalPeriodSeconds: 6.3872 * day, initialPhaseRad: 1.5, latitudeRad: 0.01, parentId: "pluto", radiusMeters: 606_000, massKg: 1.586e21, axialTiltRad: 0, rotationPeriodSeconds: 6.3872 * day, meanTempK: 53, colorHex: 0x9B9794, secondaryHex: 0x5E4742, isStar: false, hasAtmosphere: false, hasRings: false, summary: "Крупнейший спутник Плутона, образующий с ним двойную планетную систему."),

            // MARK: - Звёзды (реальные координаты J2000)
            CelestialBody(id: "proxima", name: "Проксима Центавра", type: "Звезда M5.5Ve", category: .stars, semiMajorAxisMeters: 4.2465 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pProxima.phase, latitudeRad: pProxima.lat, parentId: nil, radiusMeters: 107_280_000, massKg: 2.428e29, axialTiltRad: 0, rotationPeriodSeconds: 83.5 * day, meanTempK: 3042, colorHex: 0xFF5A36, secondaryHex: 0xB8250A, isStar: true, hasAtmosphere: false, hasRings: false, summary: "Ближайшая к Солнцу звезда — красный карлик с подтверждённой экзопланетой Proxima b."),
            CelestialBody(id: "alpha_cen_a", name: "Альфа Центавра A", type: "Звезда G2V", category: .stars, semiMajorAxisMeters: 4.344 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pAlphaCen.phase, latitudeRad: pAlphaCen.lat, parentId: nil, radiusMeters: 851_000_000, massKg: 2.14e30, axialTiltRad: 0, rotationPeriodSeconds: 22.0 * day, meanTempK: 5790, colorHex: 0xFFD970, secondaryHex: 0xFF8811, isStar: true, hasAtmosphere: false, hasRings: false, summary: "Ближайшая солнцеподобная звезда, главный компонент тройной системы Альфа Центавра."),
            CelestialBody(id: "sirius", name: "Сириус A", type: "Звезда A1V", category: .stars, semiMajorAxisMeters: 8.60 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pSirius.phase, latitudeRad: pSirius.lat, parentId: nil, radiusMeters: 1_190_000_000, massKg: 4.018e30, axialTiltRad: 0, rotationPeriodSeconds: 5.5 * day, meanTempK: 9940, colorHex: 0xD6EAFF, secondaryHex: 0x88B8FF, isStar: true, hasAtmosphere: false, hasRings: false, summary: "Ярчайшая звезда земного ночного неба, в 25 раз превосходящая Солнце по светимости."),
            CelestialBody(id: "tau_ceti", name: "Тау Кита", type: "Звезда G8V", category: .stars, semiMajorAxisMeters: 11.91 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pTauCeti.phase, latitudeRad: pTauCeti.lat, parentId: nil, radiusMeters: 552_000_000, massKg: 1.557e30, axialTiltRad: 0, rotationPeriodSeconds: 34.0 * day, meanTempK: 5344, colorHex: 0xFFC56E, secondaryHex: 0xD96B18, isStar: true, hasAtmosphere: false, hasRings: false, summary: "Близкий жёлтый карлик в созвездии Кита с пылевым диском и несколькими суперземлями."),
            CelestialBody(id: "vega", name: "Вега", type: "Звезда A0Va", category: .stars, semiMajorAxisMeters: 25.04 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pVega.phase, latitudeRad: pVega.lat, parentId: nil, radiusMeters: 1_643_000_000, massKg: 4.24e30, axialTiltRad: 0, rotationPeriodSeconds: 0.52 * day, meanTempK: 9602, colorHex: 0xCBE5FF, secondaryHex: 0x6AA8FF, isStar: true, hasAtmosphere: false, hasRings: false, summary: "Быстро вращающийся бело-голубой гигант созвездия Лиры, сплюснутый у полюсов."),
            CelestialBody(id: "arcturus", name: "Арктур", type: "Красный гигант K1.5III", category: .stars, semiMajorAxisMeters: 36.7 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pArcturus.phase, latitudeRad: pArcturus.lat, parentId: nil, radiusMeters: 17_687_000_000, massKg: 2.15e30, axialTiltRad: 0, rotationPeriodSeconds: 2.0 * 365 * day, meanTempK: 4286, colorHex: 0xFF9442, secondaryHex: 0xCC3300, isStar: true, hasAtmosphere: false, hasRings: false, summary: "Ярчайшая звезда северного неба, оранжевый гигант радиусом в 25.4 солнечных."),
            CelestialBody(id: "trappist1", name: "TRAPPIST-1", type: "Звезда M8V (7 планет)", category: .stars, semiMajorAxisMeters: 40.66 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pTrappist.phase, latitudeRad: pTrappist.lat, parentId: nil, radiusMeters: 84_180_000, massKg: 1.787e29, axialTiltRad: 0, rotationPeriodSeconds: 3.3 * day, meanTempK: 2566, colorHex: 0xFF4522, secondaryHex: 0x991A00, isStar: true, hasAtmosphere: false, hasRings: false, summary: "Ультрахолодный красный карлик в созвездии Водолея с 7 землеподобными экзопланетами."),
            CelestialBody(id: "pegasi51", name: "51 Пегаса", type: "Звезда G2IV", category: .stars, semiMajorAxisMeters: 50.9 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: p51Peg.phase, latitudeRad: p51Peg.lat, parentId: nil, radiusMeters: 861_000_000, massKg: 2.21e30, axialTiltRad: 0, rotationPeriodSeconds: 37.0 * day, meanTempK: 5793, colorHex: 0xFFE080, secondaryHex: 0xFF8C1A, isStar: true, hasAtmosphere: false, hasRings: false, summary: "Первая солнцеподобная звезда, у которой в 1995 году открыли экзопланету (горячий юпитер Димидий)."),
            CelestialBody(id: "hd189733", name: "HD 189733", type: "Звезда K2V", category: .stars, semiMajorAxisMeters: 64.5 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pHD189.phase, latitudeRad: pHD189.lat, parentId: nil, radiusMeters: 557_000_000, massKg: 1.59e30, axialTiltRad: 0, rotationPeriodSeconds: 11.9 * day, meanTempK: 5050, colorHex: 0xFFB058, secondaryHex: 0xC84B12, isStar: true, hasAtmosphere: false, hasRings: false, summary: "Оранжевый карлик в созвездии Лисички с синим газовым гигантом HD 189733 b."),
            CelestialBody(id: "aldebaran", name: "Альдебаран", type: "Красный гигант K5III", category: .stars, semiMajorAxisMeters: 65.3 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pAldebaran.phase, latitudeRad: pAldebaran.lat, parentId: nil, radiusMeters: 30_640_000_000, massKg: 2.31e30, axialTiltRad: 0, rotationPeriodSeconds: 643 * day, meanTempK: 3910, colorHex: 0xFF7B38, secondaryHex: 0xB82800, isStar: true, hasAtmosphere: false, hasRings: false, summary: "Оранжевый гигант «Глаз Тельца» радиусом 44 радиуса Солнца."),
            CelestialBody(id: "polaris", name: "Полярная звезда", type: "Цефеида F7Ib", category: .stars, semiMajorAxisMeters: 433.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pPolaris.phase, latitudeRad: pPolaris.lat, parentId: nil, radiusMeters: 26_110_000_000, massKg: 1.07e31, axialTiltRad: 0, rotationPeriodSeconds: 119 * day, meanTempK: 6015, colorHex: 0xFFF2B8, secondaryHex: 0xE6A845, isStar: true, hasAtmosphere: false, hasRings: false, summary: "Жёлтый сверхгигант почти точно над северным полюсом Земли, в 1260 раз ярче Солнца."),
            CelestialBody(id: "betelgeuse", name: "Бетельгейзе", type: "Красный сверхгигант M1Ia", category: .stars, semiMajorAxisMeters: 548.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pBetelgeuse.phase, latitudeRad: pBetelgeuse.lat, parentId: nil, radiusMeters: 532_000_000_000, massKg: 3.30e31, axialTiltRad: 0, rotationPeriodSeconds: 36 * 365 * day, meanTempK: 3600, colorHex: 0xFF5020, secondaryHex: 0x8F1500, isStar: true, hasAtmosphere: false, hasRings: false, summary: "Красный сверхгигант в Орионе; помещённый вместо Солнца, поглотил бы орбиту Марса."),
            CelestialBody(id: "kepler186", name: "Kepler-186", type: "Звезда M1V", category: .stars, semiMajorAxisMeters: 582.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pKepler186.phase, latitudeRad: pKepler186.lat, parentId: nil, radiusMeters: 364_000_000, massKg: 1.08e30, axialTiltRad: 0, rotationPeriodSeconds: 33.7 * day, meanTempK: 3755, colorHex: 0xFF6A38, secondaryHex: 0xA82208, isStar: true, hasAtmosphere: false, hasRings: false, summary: "Красный карлик в созвездии Лебедя, вокруг которого вращается первая открытая землеразмерная планета в зоне обитаемости."),
            CelestialBody(id: "rigel", name: "Ригель", type: "Голубой сверхгигант B8Ia", category: .stars, semiMajorAxisMeters: 863.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pRigel.phase, latitudeRad: pRigel.lat, parentId: nil, radiusMeters: 54_940_000_000, massKg: 4.18e31, axialTiltRad: 0, rotationPeriodSeconds: 60 * day, meanTempK: 12100, colorHex: 0xB8DAFF, secondaryHex: 0x4A90FF, isStar: true, hasAtmosphere: false, hasRings: false, summary: "Голубой сверхгигант Ориона светимостью около 120 000 солнечных."),
            CelestialBody(id: "kepler442", name: "Kepler-442", type: "Звезда K-типа", category: .stars, semiMajorAxisMeters: 1_206.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pKepler442.phase, latitudeRad: pKepler442.lat, parentId: nil, radiusMeters: 416_000_000, massKg: 1.21e30, axialTiltRad: 0, rotationPeriodSeconds: 28 * day, meanTempK: 4402, colorHex: 0xFF9848, secondaryHex: 0xC44A10, isStar: true, hasAtmosphere: false, hasRings: false, summary: "Оранжевый карлик в созвездии Лиры с одной из самых пригодных для жизни экзопланет Kepler-442b."),
            CelestialBody(id: "crab_pulsar", name: "Пульсар Крабовидной", type: "Нейтронная звезда", category: .stars, semiMajorAxisMeters: 6_500.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pCrab.phase, latitudeRad: pCrab.lat, parentId: nil, radiusMeters: 10_500, massKg: 2.78e30, axialTiltRad: 0.45, rotationPeriodSeconds: 0.033, meanTempK: 1_600_000, colorHex: 0x99EEFF, secondaryHex: 0x3377FF, isStar: true, hasAtmosphere: false, hasRings: false, summary: "Сверхплотный остаток сверхновой 1054 года радиусом 10.5 км, делающий 30 оборотов в секунду."),
            CelestialBody(id: "uy_scuti", name: "UY Щита", type: "Красный гипергигант", category: .stars, semiMajorAxisMeters: 5_100.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pUYScuti.phase, latitudeRad: pUYScuti.lat, parentId: nil, radiusMeters: 1_189_000_000_000, massKg: 1.6e31, axialTiltRad: 0, rotationPeriodSeconds: 50 * 365 * day, meanTempK: 3365, colorHex: 0xFF4418, secondaryHex: 0x7A0E00, isStar: true, hasAtmosphere: false, hasRings: false, summary: "Одна из крупнейших известных звёзд (~1708 радиусов Солнца, почти до орбиты Сатурна)."),
            CelestialBody(id: "stephenson2_18", name: "Stephenson 2-18", type: "Красный гипергигант", category: .stars, semiMajorAxisMeters: 18_900.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pStephens.phase, latitudeRad: pStephens.lat, parentId: nil, radiusMeters: 1_497_000_000_000, massKg: 2.0e31, axialTiltRad: 0, rotationPeriodSeconds: 60 * 365 * day, meanTempK: 3200, colorHex: 0xFF3612, secondaryHex: 0x6A0800, isStar: true, hasAtmosphere: false, hasRings: false, summary: "Крупнейший известный гипергигант Вселенной — около 2150 радиусов Солнца (~10 а.е.)."),

            // MARK: - Экзопланеты
            CelestialBody(id: "proxima_b", name: "Proxima b", type: "Экзопланета (зона обитаемости)", category: .exoplanets, semiMajorAxisMeters: 0.04856 * au, orbitalPeriodSeconds: 11.186 * day, initialPhaseRad: 0.9, latitudeRad: 0.02, parentId: "proxima", radiusMeters: 6_817_000, massKg: 6.39e24, axialTiltRad: 0.05, rotationPeriodSeconds: 11.186 * day, meanTempK: 268, colorHex: 0x22689C, secondaryHex: 0x4A8C4E, isStar: false, hasAtmosphere: true, hasRings: false, cloudCoverage: 0.70, summary: "Ближайшая к Земле землеподобная экзопланета в зоне обитаемости красного карлика Проксима Центавра."),
            CelestialBody(id: "trappist1b", name: "TRAPPIST-1b", type: "Горячая суперземля", category: .exoplanets, semiMajorAxisMeters: 0.01154 * au, orbitalPeriodSeconds: 1.5109 * day, initialPhaseRad: 0.4, latitudeRad: 0.01, parentId: "trappist1", radiusMeters: 7_110_000, massKg: 8.20e24, axialTiltRad: 0, rotationPeriodSeconds: 1.5109 * day, meanTempK: 400, colorHex: 0xC86B38, secondaryHex: 0x5E2812, isStar: false, hasAtmosphere: true, hasRings: false, cloudCoverage: 0.90, summary: "Ближайшая к звезде планета системы TRAPPIST-1 с горячей плотной атмосферой."),
            CelestialBody(id: "trappist1d", name: "TRAPPIST-1d", type: "Каменистая экзопланета", category: .exoplanets, semiMajorAxisMeters: 0.02227 * au, orbitalPeriodSeconds: 4.0492 * day, initialPhaseRad: 1.9, latitudeRad: -0.01, parentId: "trappist1", radiusMeters: 4_995_000, massKg: 2.32e24, axialTiltRad: 0.02, rotationPeriodSeconds: 4.0492 * day, meanTempK: 288, colorHex: 0xB86442, secondaryHex: 0x6E321D, isStar: false, hasAtmosphere: true, hasRings: false, cloudCoverage: 0.25, summary: "Лёгкая каменистая планета у внутреннего края зоны обитаемости TRAPPIST-1."),
            CelestialBody(id: "trappist1e", name: "TRAPPIST-1e", type: "Обитаемый океанический мир", category: .exoplanets, semiMajorAxisMeters: 0.02925 * au, orbitalPeriodSeconds: 6.1010 * day, initialPhaseRad: 3.4, latitudeRad: 0.01, parentId: "trappist1", radiusMeters: 5_861_000, massKg: 4.13e24, axialTiltRad: 0.02, rotationPeriodSeconds: 6.1010 * day, meanTempK: 275, colorHex: 0x1B5EA8, secondaryHex: 0x3D8A52, isStar: false, hasAtmosphere: true, hasRings: false, cloudCoverage: 0.72, summary: "Главный кандидат на наличие жидких океанов и жизни среди всех 7 планет TRAPPIST-1."),
            CelestialBody(id: "trappist1f", name: "TRAPPIST-1f", type: "Холодная экзопланета", category: .exoplanets, semiMajorAxisMeters: 0.03849 * au, orbitalPeriodSeconds: 9.2075 * day, initialPhaseRad: 4.9, latitudeRad: -0.01, parentId: "trappist1", radiusMeters: 6_658_000, massKg: 6.21e24, axialTiltRad: 0.02, rotationPeriodSeconds: 9.2075 * day, meanTempK: 219, colorHex: 0x8CA8BE, secondaryHex: 0x4E6478, isStar: false, hasAtmosphere: true, hasRings: false, cloudCoverage: 0.45, summary: "Богатая водой планета с обширными ледниками и тонкой атмосферой."),
            CelestialBody(id: "trappist1g", name: "TRAPPIST-1g", type: "Суперземля", category: .exoplanets, semiMajorAxisMeters: 0.04683 * au, orbitalPeriodSeconds: 12.3529 * day, initialPhaseRad: 5.7, latitudeRad: 0.01, parentId: "trappist1", radiusMeters: 7_193_000, massKg: 7.89e24, axialTiltRad: 0.02, rotationPeriodSeconds: 12.3529 * day, meanTempK: 199, colorHex: 0x7A8FA4, secondaryHex: 0x445264, isStar: false, hasAtmosphere: true, hasRings: false, cloudCoverage: 0.35, summary: "Крупнейшая планета системы TRAPPIST-1 на внешнем краю обитаемой зоны."),
            CelestialBody(id: "dimidium", name: "51 Пегаса b (Димидий)", type: "Горячий юпитер", category: .exoplanets, semiMajorAxisMeters: 0.0527 * au, orbitalPeriodSeconds: 4.2308 * day, initialPhaseRad: 1.2, latitudeRad: 0.03, parentId: "pegasi51", radiusMeters: 132_800_000, massKg: 8.73e26, axialTiltRad: 0.02, rotationPeriodSeconds: 4.2308 * day, meanTempK: 1284, colorHex: 0xE8965A, secondaryHex: 0x7A2E14, isStar: false, hasAtmosphere: true, hasRings: false, cloudCoverage: 0.85, summary: "Исторически первая открытая экзопланета у солнцеподобной звезды; раскалена до ~1000 °C."),
            CelestialBody(id: "hd189733b", name: "HD 189733 b", type: "Кобальтовый газовый гигант", category: .exoplanets, semiMajorAxisMeters: 0.0314 * au, orbitalPeriodSeconds: 2.2186 * day, initialPhaseRad: 2.6, latitudeRad: 0.02, parentId: "hd189733", radiusMeters: 79_560_000, massKg: 2.17e27, axialTiltRad: 0.02, rotationPeriodSeconds: 2.2186 * day, meanTempK: 1200, colorHex: 0x2255EE, secondaryHex: 0x10288A, isStar: false, hasAtmosphere: true, hasRings: false, cloudCoverage: 0.88, summary: "Ярко-синий горячий юпитер со сверхзвуковыми ветрами и горизонтальными дождями из расплавленного стекла."),
            CelestialBody(id: "kepler186f", name: "Kepler-186f", type: "Экзопланета земного типа", category: .exoplanets, semiMajorAxisMeters: 0.432 * au, orbitalPeriodSeconds: 129.94 * day, initialPhaseRad: 4.0, latitudeRad: 0.01, parentId: "kepler186", radiusMeters: 7_454_000, massKg: 8.60e24, axialTiltRad: 0.04, rotationPeriodSeconds: 42 * 3600, meanTempK: 245, colorHex: 0x3D6A8A, secondaryHex: 0x784E3A, isStar: false, hasAtmosphere: true, hasRings: false, cloudCoverage: 0.65, summary: "Первая открытая землеразмерная экзопланета в обитаемой зоне другой звезды."),
            CelestialBody(id: "kepler442b", name: "Kepler-442b", type: "Обитаемая суперземля", category: .exoplanets, semiMajorAxisMeters: 0.409 * au, orbitalPeriodSeconds: 112.31 * day, initialPhaseRad: 0.7, latitudeRad: -0.02, parentId: "kepler442", radiusMeters: 8_537_000, massKg: 1.41e25, axialTiltRad: 0.15, rotationPeriodSeconds: 32 * 3600, meanTempK: 282, colorHex: 0x1C6A9E, secondaryHex: 0x3E8A44, isStar: false, hasAtmosphere: true, hasRings: false, cloudCoverage: 0.72, summary: "Суперземля с индексом сходства с Землёй ESI 0.84 — один из лучших миров для колонизации."),

            // MARK: - Чёрные дыры
            CelestialBody(id: "sgr_a", name: "Стрелец A*", type: "Сверхмассивная ЧД", category: .blackHoles, semiMajorAxisMeters: 26_673.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pSgrA.phase, latitudeRad: pSgrA.lat, parentId: nil, radiusMeters: 12_000_000_000, massKg: 8.26e36, axialTiltRad: 0.4, rotationPeriodSeconds: 600, meanTempK: 0, colorHex: 0x000000, secondaryHex: 0xFF8811, isStar: false, isBlackHole: true, hasAtmosphere: false, hasRings: true, summary: "Сверхмассивная чёрная дыра в центре Млечного Пути массой ~4.15 млн масс Солнца."),
            CelestialBody(id: "cygnus_x1", name: "Лебедь X-1", type: "ЧД звёздной массы", category: .blackHoles, semiMajorAxisMeters: 7_200.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pCygX1.phase, latitudeRad: pCygX1.lat, parentId: nil, radiusMeters: 62_600, massKg: 4.215e31, axialTiltRad: 0.52, rotationPeriodSeconds: 120, meanTempK: 0, colorHex: 0x000000, secondaryHex: 0x55AAFF, isStar: false, isBlackHole: true, hasAtmosphere: false, hasRings: true, summary: "Знаменитая рентгеновская чёрная дыра массой 21.2 массы Солнца с горизонтом событий ~62.6 км."),
            CelestialBody(id: "m87_star", name: "M87* (Повехи)", type: "Сверхмассивная ЧД", category: .blackHoles, semiMajorAxisMeters: 53_500_000.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pM87.phase, latitudeRad: pM87.lat, parentId: nil, radiusMeters: 19_200_000_000_000, massKg: 1.29e40, axialTiltRad: 0.30, rotationPeriodSeconds: 86_400, meanTempK: 0, colorHex: 0x000000, secondaryHex: 0xFF6600, isStar: false, isBlackHole: true, hasAtmosphere: false, hasRings: true, summary: "Первая сфотографированная чёрная дыра (EHT) массой 6.5 млрд масс Солнца в галактике M87."),
            CelestialBody(id: "ton618", name: "TON 618", type: "Ультрамассивная ЧД", category: .blackHoles, semiMajorAxisMeters: 10_370_000_000.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pTON618.phase, latitudeRad: pTON618.lat, parentId: nil, radiusMeters: 120_000_000_000_000, massKg: 8.09e40, axialTiltRad: 0.42, rotationPeriodSeconds: 172_800, meanTempK: 0, colorHex: 0x000000, secondaryHex: 0xFFAA33, isStar: false, isBlackHole: true, hasAtmosphere: false, hasRings: true, summary: "Гиперяркий квазар и одна из крупнейших чёрных дыр Вселенной (~40.7 млрд масс Солнца, горизонт ~120 млрд км)."),

            // MARK: - Галактики
            CelestialBody(id: "milky_way", name: "Млечный Путь", type: "Спиральная галактика SBbc", category: .galaxies, semiMajorAxisMeters: 26_673.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pSgrA.phase, latitudeRad: pSgrA.lat, parentId: nil, radiusMeters: 52_850.0 * ly, massKg: 2.3e42, axialTiltRad: 0.48, rotationPeriodSeconds: 0, meanTempK: 0, colorHex: 0xFFE6B8, secondaryHex: 0x6AA8FF, isStar: false, isGalaxy: true, hasAtmosphere: false, hasRings: false, summary: "Наша родная спиральная галактика с перемычкой диаметром ~105 700 световых лет и сотнями миллиардов звёзд."),
            CelestialBody(id: "lmc", name: "Большое Магелланово Облако", type: "Карликовая галактика SB(s)m", category: .galaxies, semiMajorAxisMeters: 163_000.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pLMC.phase, latitudeRad: pLMC.lat, parentId: nil, radiusMeters: 16_100.0 * ly, massKg: 2.7e41, axialTiltRad: 0.62, rotationPeriodSeconds: 0, meanTempK: 0, colorHex: 0xDDEEFF, secondaryHex: 0xFF88AA, isStar: false, isGalaxy: true, hasAtmosphere: false, hasRings: false, summary: "Крупнейший спутник Млечного Пути в южном полушарии неба с туманностью Тарантул."),
            CelestialBody(id: "m31", name: "Туманность Андромеды (M31)", type: "Спиральная галактика SA(s)b", category: .galaxies, semiMajorAxisMeters: 2_537_000.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pM31.phase, latitudeRad: pM31.lat, parentId: nil, radiusMeters: 110_000.0 * ly, massKg: 3.0e42, axialTiltRad: 0.85, rotationPeriodSeconds: 0, meanTempK: 0, colorHex: 0xFFE8C4, secondaryHex: 0x7AB4FF, isStar: false, isGalaxy: true, hasAtmosphere: false, hasRings: false, summary: "Крупнейшая галактика Местной группы (около триллиона звёзд), сближающаяся с Млечным Путём."),
            CelestialBody(id: "m33", name: "Галактика Треугольника (M33)", type: "Спиральная галактика SA(s)cd", category: .galaxies, semiMajorAxisMeters: 2_730_000.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pM33.phase, latitudeRad: pM33.lat, parentId: nil, radiusMeters: 30_000.0 * ly, massKg: 1.0e41, axialTiltRad: 0.55, rotationPeriodSeconds: 0, meanTempK: 0, colorHex: 0xD8ECFF, secondaryHex: 0x629EFF, isStar: false, isGalaxy: true, hasAtmosphere: false, hasRings: false, summary: "Третья по величине спиральная галактика Местной группы с активным звездообразованием."),
            CelestialBody(id: "m51", name: "Галактика Водоворот (M51)", type: "Спиральная галактика SA(s)bc", category: .galaxies, semiMajorAxisMeters: 31_000_000.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pM51.phase, latitudeRad: pM51.lat, parentId: nil, radiusMeters: 38_000.0 * ly, massKg: 3.2e41, axialTiltRad: 0.35, rotationPeriodSeconds: 0, meanTempK: 0, colorHex: 0xFFF0D4, secondaryHex: 0x68ACFF, isStar: false, isGalaxy: true, hasAtmosphere: false, hasRings: false, summary: "Эталонная галактика с чётко выраженными спиральными рукавами в созвездии Гончих Псов."),
            CelestialBody(id: "m104", name: "Галактика Сомбреро (M104)", type: "Линзовидная / спиральная SA(s)a", category: .galaxies, semiMajorAxisMeters: 31_100_000.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pM104.phase, latitudeRad: pM104.lat, parentId: nil, radiusMeters: 25_000.0 * ly, massKg: 1.6e42, axialTiltRad: 1.38, rotationPeriodSeconds: 0, meanTempK: 0, colorHex: 0xFFE2A8, secondaryHex: 0xD48844, isStar: false, hasAtmosphere: false, hasRings: false, summary: "Галактика в созвездии Девы с огромным светящимся балджем и тёмной пылевой полосой по краю диска."),
            CelestialBody(id: "ic1101", name: "IC 1101", type: "Сверхгигантская эллиптическая", category: .galaxies, semiMajorAxisMeters: 1_045_000_000.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: pIC1101.phase, latitudeRad: pIC1101.lat, parentId: nil, radiusMeters: 2_000_000.0 * ly, massKg: 2.0e44, axialTiltRad: 0.30, rotationPeriodSeconds: 0, meanTempK: 0, colorHex: 0xFFD998, secondaryHex: 0xD89050, isStar: false, isGalaxy: true, hasAtmosphere: false, hasRings: false, summary: "Одна из крупнейших известных галактик во Вселенной диаметром ~4 млн световых лет в скоплении Abell 2029.")
        ]
    }()
}
