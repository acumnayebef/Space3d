import Foundation
import simd

struct CelestialBody: Identifiable {
    let id: String
    let name: String
    let type: String
    /// Реальные координаты в метрах относительно Солнца (64-битная точность double)
    let positionMeters: SIMD3<Double>
    let radiusMeters: Double
    let colorHex: UInt32
    let isStar: Bool
}

final class UniverseCatalog {
    static let au: Double = 149_597_870_700.0        // 1 а.е. в метрах
    static let ly: Double = 9_460_730_472_580_800.0  // 1 световой год в метрах

    static let bodies: [CelestialBody] = [
        CelestialBody(id: "sun", name: "Солнце", type: "Звезда G2V", positionMeters: SIMD3(0, 0, 0), radiusMeters: 696_340_000, colorHex: 0xFFCC44, isStar: true),
        CelestialBody(id: "mercury", name: "Меркурий", type: "Планета", positionMeters: SIMD3(0.387 * au, 0, 0), radiusMeters: 2_439_700, colorHex: 0x9E9E9E, isStar: false),
        CelestialBody(id: "venus", name: "Венера", type: "Планета", positionMeters: SIMD3(0, 0, 0.723 * au), radiusMeters: 6_051_800, colorHex: 0xE6B87D, isStar: false),
        CelestialBody(id: "earth", name: "Земля", type: "Планета", positionMeters: SIMD3(-1.0 * au, 0, 0), radiusMeters: 6_371_000, colorHex: 0x2E7DFF, isStar: false),
        CelestialBody(id: "moon", name: "Луна", type: "Спутник", positionMeters: SIMD3(-1.0 * au + 384_400_000, 12_000_000, 0), radiusMeters: 1_737_400, colorHex: 0xCFCFCF, isStar: false),
        CelestialBody(id: "mars", name: "Марс", type: "Планета", positionMeters: SIMD3(0, 0, -1.524 * au), radiusMeters: 3_389_500, colorHex: 0xD95B38, isStar: false),
        CelestialBody(id: "jupiter", name: "Юпитер", type: "Газовый гигант", positionMeters: SIMD3(5.203 * au, 0, 0), radiusMeters: 69_911_000, colorHex: 0xD4A373, isStar: false),
        CelestialBody(id: "saturn", name: "Сатурн", type: "Газовый гигант", positionMeters: SIMD3(-9.537 * au, 0, 0), radiusMeters: 58_232_000, colorHex: 0xE8D296, isStar: false),
        CelestialBody(id: "proxima", name: "Проксима Центавра", type: "Звезда M5.5Ve", positionMeters: SIMD3(-1.62 * ly, -3.58 * ly, -1.53 * ly), radiusMeters: 107_280_000, colorHex: 0xFF6B4A, isStar: true),
        CelestialBody(id: "sirius", name: "Сириус A", type: "Звезда A1V", positionMeters: SIMD3(-1.61 * ly, 8.07 * ly, -2.47 * ly), radiusMeters: 1_190_000_000, colorHex: 0xCBE4FF, isStar: true),
        CelestialBody(id: "trappist1", name: "TRAPPIST-1", type: "Система (7 экзопланет)", positionMeters: SIMD3(39.46 * ly, -1.2 * ly, -3.4 * ly), radiusMeters: 84_180_000, colorHex: 0xFF5533, isStar: true),
        CelestialBody(id: "sgr_a", name: "Стрелец A*", type: "Сверхмассивная ЧД", positionMeters: SIMD3(-1480 * ly, -25900 * ly, -2340 * ly), radiusMeters: 12_000_000_000, colorHex: 0xFF9922, isStar: true)
    ]
}