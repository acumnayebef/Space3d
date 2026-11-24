import Foundation
import simd

struct CelestialBody: Identifiable {
    let id: String
    let name: String
    let type: String
    let semiMajorAxisMeters: Double   // Большая полуось орбиты или дистанция от Солнца (м)
    let orbitalPeriodSeconds: Double  // Сидерический период обращения (сек), 0 для дальних звёзд
    let initialPhaseRad: Double       // Долгота / начальная фаза (рад)
    let latitudeRad: Double           // Широта / наклонение над плоскостью эклиптики (рад)
    let parentId: String?
    let radiusMeters: Double
    let massKg: Double
    let axialTiltRad: Double
    let rotationPeriodSeconds: Double
    let colorHex: UInt32
    let secondaryHex: UInt32
    let isStar: Bool
    let hasAtmosphere: Bool
    let hasRings: Bool

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

    func orbitalVelocity(atRadius r: Double) -> Double {
        let g = 6.67430e-11
        return sqrt((g * massKg) / max(radiusMeters, r))
    }
}

final class UniverseCatalog {
    static let au: Double = 149_597_870_700.0
    static let ly: Double = 9_460_730_472_580_800.0
    static let day: Double = 86_400.0

    static let bodies: [CelestialBody] = [
        CelestialBody(id: "sun", name: "Солнце", type: "Звезда G2V", semiMajorAxisMeters: 0, orbitalPeriodSeconds: 0, initialPhaseRad: 0, latitudeRad: 0, parentId: nil, radiusMeters: 696_340_000, massKg: 1.9885e30, axialTiltRad: 0.126, rotationPeriodSeconds: 25.38 * day, colorHex: 0xFFCC44, secondaryHex: 0xFF6600, isStar: true, hasAtmosphere: false, hasRings: false),
        CelestialBody(id: "mercury", name: "Меркурий", type: "Планета", semiMajorAxisMeters: 0.387098 * au, orbitalPeriodSeconds: 87.969 * day, initialPhaseRad: 0.4, latitudeRad: 0.05, parentId: "sun", radiusMeters: 2_439_700, massKg: 3.3011e23, axialTiltRad: 0.0005, rotationPeriodSeconds: 58.646 * day, colorHex: 0x948F88, secondaryHex: 0x524E48, isStar: false, hasAtmosphere: false, hasRings: false),
        CelestialBody(id: "venus", name: "Венера", type: "Планета", semiMajorAxisMeters: 0.723332 * au, orbitalPeriodSeconds: 224.701 * day, initialPhaseRad: 2.1, latitudeRad: -0.02, parentId: "sun", radiusMeters: 6_051_800, massKg: 4.8675e24, axialTiltRad: 3.095, rotationPeriodSeconds: -243.025 * day, colorHex: 0xE6B87D, secondaryHex: 0xB87A38, isStar: false, hasAtmosphere: true, hasRings: false),
        CelestialBody(id: "earth", name: "Земля", type: "Планета", semiMajorAxisMeters: 1.000000 * au, orbitalPeriodSeconds: 365.256 * day, initialPhaseRad: .pi, latitudeRad: 0, parentId: "sun", radiusMeters: 6_371_000, massKg: 5.97237e24, axialTiltRad: 0.4091, rotationPeriodSeconds: 86_164.1, colorHex: 0x164E9C, secondaryHex: 0x3B8C4E, isStar: false, hasAtmosphere: true, hasRings: false),
        CelestialBody(id: "moon", name: "Луна", type: "Спутник Земли", semiMajorAxisMeters: 384_400_000, orbitalPeriodSeconds: 27.32166 * day, initialPhaseRad: 0.85, latitudeRad: 0.089, parentId: "earth", radiusMeters: 1_737_400, massKg: 7.342e22, axialTiltRad: 0.116, rotationPeriodSeconds: 27.32166 * day, colorHex: 0xC4C4C4, secondaryHex: 0x6A6A6A, isStar: false, hasAtmosphere: false, hasRings: false),
        CelestialBody(id: "mars", name: "Марс", type: "Планета", semiMajorAxisMeters: 1.523679 * au, orbitalPeriodSeconds: 686.980 * day, initialPhaseRad: 1.3, latitudeRad: 0.02, parentId: "sun", radiusMeters: 3_389_500, massKg: 6.4171e23, axialTiltRad: 0.4396, rotationPeriodSeconds: 88_642.6, colorHex: 0xC8522E, secondaryHex: 0x692311, isStar: false, hasAtmosphere: true, hasRings: false),
        CelestialBody(id: "jupiter", name: "Юпитер", type: "Газовый гигант", semiMajorAxisMeters: 5.2044 * au, orbitalPeriodSeconds: 4332.59 * day, initialPhaseRad: 5.2, latitudeRad: -0.01, parentId: "sun", radiusMeters: 69_911_000, massKg: 1.8982e27, axialTiltRad: 0.0546, rotationPeriodSeconds: 35_730, colorHex: 0xD8B088, secondaryHex: 0x8F5230, isStar: false, hasAtmosphere: true, hasRings: false),
        CelestialBody(id: "saturn", name: "Сатурн", type: "Газовый гигант", semiMajorAxisMeters: 9.5826 * au, orbitalPeriodSeconds: 10759.22 * day, initialPhaseRad: 3.7, latitudeRad: 0.03, parentId: "sun", radiusMeters: 58_232_000, massKg: 5.6834e26, axialTiltRad: 0.4665, rotationPeriodSeconds: 38_362, colorHex: 0xE8D49E, secondaryHex: 0xB39252, isStar: false, hasAtmosphere: true, hasRings: true),
        CelestialBody(id: "uranus", name: "Уран", type: "Ледяной гигант", semiMajorAxisMeters: 19.2184 * au, orbitalPeriodSeconds: 30688.5 * day, initialPhaseRad: 4.5, latitudeRad: -0.01, parentId: "sun", radiusMeters: 25_362_000, massKg: 8.6810e25, axialTiltRad: 1.706, rotationPeriodSeconds: -62_064, colorHex: 0x84E6F5, secondaryHex: 0x4CB3C9, isStar: false, hasAtmosphere: true, hasRings: true),
        CelestialBody(id: "neptune", name: "Нептун", type: "Ледяной гигант", semiMajorAxisMeters: 30.11 * au, orbitalPeriodSeconds: 60195.0 * day, initialPhaseRad: 0.2, latitudeRad: 0.02, parentId: "sun", radiusMeters: 24_622_000, massKg: 1.02413e26, axialTiltRad: 0.494, rotationPeriodSeconds: 57_996, colorHex: 0x3666FF, secondaryHex: 0x1A3494, isStar: false, hasAtmosphere: true, hasRings: false),
        CelestialBody(id: "proxima", name: "Проксима Центавра", type: "Звезда M5.5Ve", semiMajorAxisMeters: 4.2465 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: 2.3, latitudeRad: -0.78, parentId: nil, radiusMeters: 107_280_000, massKg: 2.428e29, axialTiltRad: 0, rotationPeriodSeconds: 83.5 * day, colorHex: 0xFF5A36, secondaryHex: 0xB8250A, isStar: true, hasAtmosphere: false, hasRings: false),
        CelestialBody(id: "sirius", name: "Сириус A", type: "Звезда A1V", semiMajorAxisMeters: 8.60 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: 1.7, latitudeRad: -0.29, parentId: nil, radiusMeters: 1_190_000_000, massKg: 4.018e30, axialTiltRad: 0, rotationPeriodSeconds: 5.5 * day, colorHex: 0xD6EAFF, secondaryHex: 0x88B8FF, isStar: true, hasAtmosphere: false, hasRings: false),
        CelestialBody(id: "trappist1", name: "TRAPPIST-1", type: "Система (7 экзопланет)", semiMajorAxisMeters: 39.46 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: 5.8, latitudeRad: -0.09, parentId: nil, radiusMeters: 84_180_000, massKg: 1.787e29, axialTiltRad: 0, rotationPeriodSeconds: 3.3 * day, colorHex: 0xFF4522, secondaryHex: 0x991A00, isStar: true, hasAtmosphere: false, hasRings: false),
        CelestialBody(id: "sgr_a", name: "Стрелец A*", type: "Сверхмассивная ЧД", semiMajorAxisMeters: 26_673.0 * ly, orbitalPeriodSeconds: 0, initialPhaseRad: 4.1, latitudeRad: -0.50, parentId: nil, radiusMeters: 12_000_000_000, massKg: 8.26e36, axialTiltRad: 0.4, rotationPeriodSeconds: 600, colorHex: 0x000000, secondaryHex: 0xFF8811, isStar: true, hasAtmosphere: false, hasRings: true)
    ]
}