import Foundation
import simd

struct CelestialBody: Identifiable {
    let id: String
    let name: String
    let type: String
    let positionMeters: SIMD3<Double>
    let radiusMeters: Double
    let colorHex: UInt32
    let secondaryHex: UInt32
    let isStar: Bool
    let hasAtmosphere: Bool
    let hasRings: Bool
}

final class UniverseCatalog {
    static let au: Double = 149_597_870_700.0
    static let ly: Double = 9_460_730_472_580_800.0

    static let bodies: [CelestialBody] = [
        CelestialBody(id: "sun", name: "Солнце", type: "Звезда G2V", positionMeters: SIMD3(0, 0, 0), radiusMeters: 696_340_000, colorHex: 0xFFCC44, secondaryHex: 0xFF7700, isStar: true, hasAtmosphere: false, hasRings: false),
        CelestialBody(id: "mercury", name: "Меркурий", type: "Планета", positionMeters: SIMD3(0.387 * au, 0, 0), radiusMeters: 2_439_700, colorHex: 0x8C8881, secondaryHex: 0x5A5650, isStar: false, hasAtmosphere: false, hasRings: false),
        CelestialBody(id: "venus", name: "Венера", type: "Планета", positionMeters: SIMD3(0, 0, 0.723 * au), radiusMeters: 6_051_800, colorHex: 0xE6B87D, secondaryHex: 0xC48B45, isStar: false, hasAtmosphere: true, hasRings: false),
        CelestialBody(id: "earth", name: "Земля", type: "Планета", positionMeters: SIMD3(-1.0 * au, 0, 0), radiusMeters: 6_371_000, colorHex: 0x164E9C, secondaryHex: 0x3B8C4E, isStar: false, hasAtmosphere: true, hasRings: false),
        CelestialBody(id: "moon", name: "Луна", type: "Спутник", positionMeters: SIMD3(-1.0 * au + 384_400_000, 18_000_000, -45_000_000), radiusMeters: 1_737_400, colorHex: 0xBDBDBD, secondaryHex: 0x7A7A7A, isStar: false, hasAtmosphere: false, hasRings: false),
        CelestialBody(id: "mars", name: "Марс", type: "Планета", positionMeters: SIMD3(0, 0, -1.524 * au), radiusMeters: 3_389_500, colorHex: 0xC84B28, secondaryHex: 0x7A2814, isStar: false, hasAtmosphere: true, hasRings: false),
        CelestialBody(id: "jupiter", name: "Юпитер", type: "Газовый гигант", positionMeters: SIMD3(5.203 * au, 0, 0), radiusMeters: 69_911_000, colorHex: 0xD4A373, secondaryHex: 0x9C6644, isStar: false, hasAtmosphere: true, hasRings: false),
        CelestialBody(id: "saturn", name: "Сатурн", type: "Газовый гигант", positionMeters: SIMD3(-9.537 * au, 0, 0), radiusMeters: 58_232_000, colorHex: 0xE8D296, secondaryHex: 0xB89B5E, isStar: false, hasAtmosphere: true, hasRings: true),
        CelestialBody(id: "uranus", name: "Уран", type: "Ледяной гигант", positionMeters: SIMD3(19.19 * au, 0, 0), radiusMeters: 25_362_000, colorHex: 0x7DE3F4, secondaryHex: 0x4BB8CC, isStar: false, hasAtmosphere: true, hasRings: true),
        CelestialBody(id: "neptune", name: "Нептун", type: "Ледяной гигант", positionMeters: SIMD3(0, 0, 30.07 * au), radiusMeters: 24_622_000, colorHex: 0x3366FF, secondaryHex: 0x1D3FA8, isStar: false, hasAtmosphere: true, hasRings: false),
        CelestialBody(id: "proxima", name: "Проксима Центавра", type: "Звезда M5.5Ve", positionMeters: SIMD3(-1.62 * ly, -3.58 * ly, -1.53 * ly), radiusMeters: 107_280_000, colorHex: 0xFF5A36, secondaryHex: 0xB8250A, isStar: true, hasAtmosphere: false, hasRings: false),
        CelestialBody(id: "sirius", name: "Сириус A", type: "Звезда A1V", positionMeters: SIMD3(-1.61 * ly, 8.07 * ly, -2.47 * ly), radiusMeters: 1_190_000_000, colorHex: 0xD6EAFF, secondaryHex: 0x88B8FF, isStar: true, hasAtmosphere: false, hasRings: false),
        CelestialBody(id: "trappist1", name: "TRAPPIST-1", type: "Система (7 экзопланет)", positionMeters: SIMD3(39.46 * ly, -1.2 * ly, -3.4 * ly), radiusMeters: 84_180_000, colorHex: 0xFF4522, secondaryHex: 0x991A00, isStar: true, hasAtmosphere: false, hasRings: false),
        CelestialBody(id: "sgr_a", name: "Стрелец A*", type: "Сверхмассивная ЧД", positionMeters: SIMD3(-1480 * ly, -25900 * ly, -2340 * ly), radiusMeters: 12_000_000_000, colorHex: 0x111111, secondaryHex: 0xFF8811, isStar: true, hasAtmosphere: false, hasRings: true)
    ]
}