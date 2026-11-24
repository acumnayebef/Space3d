import Foundation
import SceneKit
import UIKit
import simd

struct TerrainSample {
    let heightMeters: Double
    let color: SIMD3<Float>
    let isWater: Bool
}

struct SurfaceScanReport: Equatable {
    let planetName: String
    let biomeName: String
    let elevationMeters: Int
    let gravityG: Double
    let gravityMps2: Double
    let tempC: Int
    let atmosphereText: String
    let compositionText: String
}

final class SurfaceTerrainEngine {

    struct TerrainCollisionGrid {
        let bodyId: String
        let gridN: Int
        let uCoords: [Double]
        let vCoords: [Double]
        let east: SIMD3<Double>
        let north: SIMD3<Double>
        let upWorld: SIMD3<Double>
        let buildPlanetRot: simd_quatd
        let bodyRadius: Double
        let patchHalfExtent: Double
        let vertexHeights: [Double]
        let isHabitableWorld: Bool

        func sampleHeight(
            worldPos: SIMD3<Double>,
            currentPlanetRot: simd_quatd,
            currentBodyPos: SIMD3<Double>
        ) -> Double? {
            let rel = worldPos - currentBodyPos
            let invDeltaRot = simd_normalize(buildPlanetRot * simd_inverse(currentPlanetRot))
            let rawBuild = invDeltaRot.act(rel)
            guard simd_length_squared(rawBuild) > 1e-12 else { return nil }
            let dirBuild = simd_normalize(rawBuild)

            let dUp = simd_dot(dirBuild, upWorld)
            guard dUp > 0.1 else { return nil }

            let uNorm = ((simd_dot(dirBuild, east) / dUp) * bodyRadius) / patchHalfExtent
            let vNorm = ((simd_dot(dirBuild, north) / dUp) * bodyRadius) / patchHalfExtent

            guard let uFirst = uCoords.first, let uLast = uCoords.last,
                  let vFirst = vCoords.first, let vLast = vCoords.last,
                  uNorm >= uFirst, uNorm <= uLast,
                  vNorm >= vFirst, vNorm <= vLast else {
                return nil
            }

            let ix = Self.findCellIndex(in: uCoords, value: uNorm, count: gridN)
            let iz = Self.findCellIndex(in: vCoords, value: vNorm, count: gridN)

            let fx = (uNorm - uCoords[ix]) / max(1e-12, uCoords[ix + 1] - uCoords[ix])
            let fz = (vNorm - vCoords[iz]) / max(1e-12, vCoords[iz + 1] - vCoords[iz])

            let h00 = vertexHeights[iz * gridN + ix]
            let h10 = vertexHeights[iz * gridN + (ix + 1)]
            let h01 = vertexHeights[(iz + 1) * gridN + ix]
            let h11 = vertexHeights[(iz + 1) * gridN + (ix + 1)]

            let h = (fx >= fz)
                ? (h00 + fx * (h10 - h00) + fz * (h11 - h10))
                : (h00 + fz * (h01 - h00) + fx * (h11 - h01))

            return isHabitableWorld ? max(0.0, h) : h
        }

        private static func findCellIndex(in coords: [Double], value: Double, count: Int) -> Int {
            var lo = 0
            var hi = count - 2
            while lo < hi {
                let mid = (lo + hi + 1) >> 1
                if coords[mid] <= value {
                    lo = mid
                } else {
                    hi = mid - 1
                }
            }
            return max(0, min(count - 2, lo))
        }
    }

    private static let cacheLock = NSLock()
    private static var pbrTextureCache: [String: (diffuse: UIImage, normal: UIImage)] = [:]

    private static func hash2DWrapped(_ ix: Int, _ iy: Int, period: Int, seed: UInt64) -> Double {
        let mask = period - 1
        let wx = ix & mask
        let wy = iy & mask
        return hash31(wx, wy, period, seed: seed)
    }

    private static func periodicNoise2D(_ u: Double, _ v: Double, period: Int, seed: UInt64) -> Double {
        let x = u * Double(period)
        let y = v * Double(period)
        let fx = floor(x)
        let fy = floor(y)
        let dx = x - fx
        let dy = y - fy
        let ux = dx * dx * (3.0 - 2.0 * dx)
        let uy = dy * dy * (3.0 - 2.0 * dy)
        let ix = Int(fx)
        let iy = Int(fy)

        let n00 = hash2DWrapped(ix, iy, period: period, seed: seed)
        let n10 = hash2DWrapped(ix + 1, iy, period: period, seed: seed)
        let n01 = hash2DWrapped(ix, iy + 1, period: period, seed: seed)
        let n11 = hash2DWrapped(ix + 1, iy + 1, period: period, seed: seed)

        let nx0 = n00 + (n10 - n00) * ux
        let nx1 = n01 + (n11 - n01) * ux
        return nx0 + (nx1 - nx0) * uy
    }

    private static func periodicFbm2D(_ u: Double, _ v: Double, basePeriod: Int, octaves: Int, seed: UInt64) -> Double {
        var val = 0.0
        var amp = 0.5
        var norm = 0.0
        var period = basePeriod
        for i in 0..<octaves {
            val += amp * periodicNoise2D(u, v, period: period, seed: seed &+ UInt64(i * 131))
            norm += amp
            period *= 2
            amp *= 0.5
        }
        return norm > 0.0 ? (val / norm) : 0.0
    }

    private static func periodicCrater2D(_ u: Double, _ v: Double, period: Int, seed: UInt64) -> Double {
        let mask = period - 1
        let x = u * Double(period)
        let y = v * Double(period)
        let cx0 = Int(floor(x))
        let cy0 = Int(floor(y))
        var total = 0.0

        for dy in -1...1 {
            for dx in -1...1 {
                let ix = cx0 + dx
                let iy = cy0 + dy
                let wx = ix & mask
                let wy = iy & mask
                let prob = hash31(wx, wy, 19, seed: seed)
                if prob < 0.48 { continue }
                let jx = hash31(wx, wy, 31, seed: seed &+ 7)
                let jy = hash31(wx, wy, 47, seed: seed &+ 13)
                let px = Double(ix) + 0.18 + 0.64 * jx
                let py = Double(iy) + 0.18 + 0.64 * jy
                let r = 0.16 + 0.24 * hash31(wx, wy, 71, seed: seed &+ 29)
                let dist = sqrt((x - px) * (x - px) + (y - py) * (y - py)) / r
                if dist < 1.35 {
                    let bowl = (dist < 1.0) ? (dist * dist - 1.0) * 0.85 : 0.0
                    let rimT = (dist - 1.0) * 5.0
                    let rim = exp(-(rimT * rimT)) * 0.36
                    total += (bowl + rim) * (0.45 + 0.55 * prob)
                }
            }
        }
        return max(-1.0, min(0.8, total))
    }

    private static func themeKey(for body: CelestialBody) -> String {
        if body.isHabitableWorld { return "habitable" }
        if body.id == "mars" || body.id == "trappist1d" { return "mars" }
        if body.isIcyWorld || body.id == "trappist1f" || body.id == "trappist1g" { return "icy" }
        if body.id == "venus" || body.id == "trappist1b" || body.id == "titan" || body.id == "io" { return "volcanic" }
        return "lunar"
    }

    private static func makeRGBAImage(bytes: [UInt8], width: Int, height: Int) -> UIImage {
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            return UIImage()
        }
        return UIImage(cgImage: cg)
    }

    static func surfacePBRTextures(for body: CelestialBody) -> (diffuse: UIImage, normal: UIImage) {
        let key = themeKey(for: body)
        cacheLock.lock()
        if let cached = pbrTextureCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let size = 512
        let invSize = 1.0 / Double(size)
        var heights = [Double](repeating: 0.0, count: size * size)
        var diffBytes = [UInt8](repeating: 255, count: size * size * 4)
        var normBytes = [UInt8](repeating: 255, count: size * size * 4)

        for py in 0..<size {
            let v = Double(py) * invSize
            for px in 0..<size {
                let u = Double(px) * invSize
                let idx = py * size + px
                let bIdx = idx * 4

                let macro = periodicFbm2D(u, v, basePeriod: 8, octaves: 4, seed: 101)
                let grain = periodicFbm2D(u, v, basePeriod: 32, octaves: 3, seed: 307)
                let grit = periodicNoise2D(u, v, period: 128, seed: 709)

                var h = 0.0
                var r = 0.70
                var g = 0.70
                var b = 0.70

                switch key {
                case "lunar":
                    let cMed = periodicCrater2D(u, v, period: 8, seed: 911)
                    let cSmall = periodicCrater2D(u, v, period: 16, seed: 1201) * 0.55
                    let pebbles = smoothstep(0.76, 0.94, grit)
                    let crSum = cMed + cSmall
                    h = macro * 0.35 + grain * 0.30 + grit * 0.14 + crSum * 0.65 + pebbles * 0.22
                    let shade = 0.52 + 0.30 * grain + 0.12 * (grit - 0.5)
                    let rimGlow = max(0.0, crSum) * 0.28 - max(0.0, -crSum) * 0.34
                    let lum = max(0.32, min(0.98, shade + rimGlow - pebbles * 0.14))
                    r = lum * (0.98 + 0.04 * macro)
                    g = lum * 0.99
                    b = lum * (1.02 - 0.04 * pebbles)

                case "mars":
                    let warp = (macro - 0.5) * 0.14
                    let ripple = sin((v + warp) * 2.0 * .pi * 16.0) * 0.5 + 0.5
                    let gravel = smoothstep(0.78, 0.96, grit)
                    let cSmall = periodicCrater2D(u, v, period: 8, seed: 521) * 0.4
                    h = macro * 0.35 + ripple * 0.34 + grain * 0.24 + grit * 0.12 + cSmall * 0.35 + gravel * 0.18
                    let baseLum = 0.54 + 0.26 * grain + 0.14 * ripple - gravel * 0.18
                    r = max(0.34, min(0.98, baseLum * 1.08))
                    g = max(0.30, min(0.92, baseLum * 0.93))
                    b = max(0.26, min(0.86, baseLum * 0.80))

                case "habitable":
                    let blade = periodicNoise2D(u, v, period: 64, seed: 401)
                    let pebbles = smoothstep(0.82, 0.96, grit)
                    let dirtPatch = smoothstep(0.32, 0.64, macro)
                    h = macro * 0.36 + grain * 0.34 + blade * 0.22 + grit * 0.10 + pebbles * 0.16
                    let organic = 0.52 + 0.28 * grain + 0.14 * (blade - 0.5)
                    r = max(0.34, min(0.95, organic * (0.90 + 0.18 * (1.0 - dirtPatch))))
                    g = max(0.36, min(0.98, organic * (1.04 - 0.10 * pebbles)))
                    b = max(0.32, min(0.90, organic * (0.86 + 0.10 * pebbles)))

                case "icy":
                    let r1 = 1.0 - abs(periodicNoise2D(u, v, period: 8, seed: 601) * 2.0 - 1.0)
                    let r2 = 1.0 - abs(periodicNoise2D(u, v, period: 16, seed: 617) * 2.0 - 1.0)
                    let crack = pow(max(0.0, r1 * 0.65 + r2 * 0.35), 3.0)
                    h = macro * 0.30 + grain * 0.28 + grit * 0.14 - crack * 0.55
                    let frost = 0.58 + 0.28 * grain + 0.12 * grit - crack * 0.36
                    r = max(0.34, min(0.98, frost * 0.94))
                    g = max(0.38, min(0.99, frost * 0.99))
                    b = max(0.44, min(1.00, frost * 1.05))

                default: // "volcanic"
                    let r1 = 1.0 - abs(periodicNoise2D(u, v, period: 8, seed: 809) * 2.0 - 1.0)
                    let fissure = pow(max(0.0, r1), 4.0)
                    let sulfur = smoothstep(0.65, 0.92, grain)
                    h = macro * 0.34 + grain * 0.32 + grit * 0.14 - fissure * 0.62
                    let crust = 0.48 + 0.32 * grain + 0.10 * grit - fissure * 0.32
                    r = max(0.28, min(0.98, crust * (1.02 + 0.10 * sulfur)))
                    g = max(0.26, min(0.94, crust * (0.94 + 0.08 * sulfur)))
                    b = max(0.24, min(0.88, crust * 0.82))
                }

                heights[idx] = h
                diffBytes[bIdx] = UInt8(max(0, min(255, Int(r * 255.0))))
                diffBytes[bIdx + 1] = UInt8(max(0, min(255, Int(g * 255.0))))
                diffBytes[bIdx + 2] = UInt8(max(0, min(255, Int(b * 255.0))))
                diffBytes[bIdx + 3] = 255
            }
        }

        let normStrength: Double = (key == "lunar" || key == "volcanic") ? 4.2 : 3.4
        let mask = size - 1
        for py in 0..<size {
            let ym = (py - 1) & mask
            let yp = (py + 1) & mask
            for px in 0..<size {
                let xm = (px - 1) & mask
                let xp = (px + 1) & mask
                let dhx = (heights[py * size + xp] - heights[py * size + xm]) * normStrength
                let dhy = (heights[yp * size + px] - heights[ym * size + px]) * normStrength
                let invLen = 1.0 / sqrt(dhx * dhx + dhy * dhy + 1.0)
                let nx = (-dhx * invLen) * 0.5 + 0.5
                let ny = (-dhy * invLen) * 0.5 + 0.5
                let nz = invLen * 0.5 + 0.5
                let bIdx = (py * size + px) * 4
                normBytes[bIdx] = UInt8(max(0, min(255, Int(nx * 255.0))))
                normBytes[bIdx + 1] = UInt8(max(0, min(255, Int(ny * 255.0))))
                normBytes[bIdx + 2] = UInt8(max(0, min(255, Int(nz * 255.0))))
                normBytes[bIdx + 3] = 255
            }
        }

        let pair = (
            diffuse: makeRGBAImage(bytes: diffBytes, width: size, height: size),
            normal: makeRGBAImage(bytes: normBytes, width: size, height: size)
        )
        cacheLock.lock()
        pbrTextureCache[key] = pair
        cacheLock.unlock()
        return pair
    }

    static func surfaceScanReport(
        body: CelestialBody,
        localDir: SIMD3<Double>,
        elevationMeters: Double
    ) -> SurfaceScanReport {
        let lat = abs(localDir.y)
        let biomeName: String
        if body.isHabitableWorld {
            if elevationMeters <= 1.0 {
                biomeName = "Прибрежная полоса океана"
            } else if lat > 0.80 {
                biomeName = "Полярная ледяная шапка"
            } else if elevationMeters > 2_500.0 {
                biomeName = "Высокогорные хребты"
            } else if elevationMeters > 1_100.0 {
                biomeName = "Скалистое нагорье"
            } else {
                biomeName = "Умеренные холмы и леса"
            }
        } else if body.id == "mars" || body.id == "trappist1d" {
            if lat > 0.84 {
                biomeName = "Полярная ледяная шапка"
            } else if elevationMeters > 1_600.0 {
                biomeName = "Скалистые хребты и каньоны"
            } else {
                biomeName = "Оксидные дюны и пустыня"
            }
        } else if body.isIcyWorld || body.id == "trappist1f" || body.id == "trappist1g" {
            biomeName = "Ледяная кора и криоразломы"
        } else if body.id == "venus" || body.id == "trappist1b" || body.id == "io" {
            biomeName = (body.id == "io") ? "Серные вулканические поля" : "Базальтовые лавовые плато"
        } else if body.id == "titan" {
            biomeName = "Дюны толинов и замёрзший метан"
        } else {
            biomeName = (elevationMeters < -250.0) ? "Базальтовое море" : "Реголит и ударные кратеры"
        }

        let atmoText: String
        switch body.id {
        case "earth":
            atmoText = "1.0 атм (N₂ 78%, O₂ 21%)"
        case "mars", "trappist1d":
            atmoText = "0.006 атм (CO₂ 95%)"
        case "venus", "trappist1b":
            atmoText = "92 атм (CO₂ 96%)"
        case "titan":
            atmoText = "1.45 атм (N₂ 95%, CH₄ 5%)"
        default:
            if body.isHabitableWorld {
                atmoText = "Кислородно-азотная плотная"
            } else if body.hasAtmosphere {
                atmoText = "Разрежённая газовая оболочка"
            } else {
                atmoText = "Отсутствует (вакуум)"
            }
        }

        let compText: String
        switch body.id {
        case "earth", "proxima_b", "trappist1e", "kepler186f", "kepler442b":
            compText = "Силикаты (SiO₂), полевой шпат, биоорганика"
        case "mars", "trappist1d":
            compText = "Оксид железа (Fe₂O₃), базальт, перхлораты"
        case "moon", "mercury", "ceres", "phobos":
            compText = "Анортизит, базальт, ильменит (FeTiO₃)"
        case "europa", "enceladus", "ganymede", "callisto", "pluto", "triton", "eris", "trappist1f", "trappist1g":
            compText = "Водяной лёд (H₂O), твёрдый азот, силикаты"
        case "io":
            compText = "Сера (S), диоксид серы, силикатная лава"
        case "titan":
            compText = "Водяной лёд, толины, углеводороды"
        case "venus", "trappist1b":
            compText = "Базальт, пироксены, сульфидные породы"
        default:
            compText = "Кремнезём (SiO₂), железо-магниевые минералы"
        }

        return SurfaceScanReport(
            planetName: body.name,
            biomeName: biomeName,
            elevationMeters: Int(round(elevationMeters)),
            gravityG: body.surfaceGravityG,
            gravityMps2: body.surfaceGravityG * 9.80665,
            tempC: body.meanTempC,
            atmosphereText: atmoText,
            compositionText: compText
        )
    }

    // MARK: - Deterministic 3D Procedural Noise & Cratering (Zero Heap Allocations)

    private static func hash31(_ ix: Int, _ iy: Int, _ iz: Int, seed: UInt64 = 0) -> Double {
        var h = UInt64(bitPattern: Int64(ix)) &* 0x9E3779B185EBCA87
        h ^= UInt64(bitPattern: Int64(iy)) &* 0xC2B2AE3D27D4EB4F
        h ^= UInt64(bitPattern: Int64(iz)) &* 0x165667B19E3779F9
        h ^= seed &* 0x85EBCA77C2B2AE63
        h ^= h >> 33
        h &*= 0xFF51AFD7ED558CCD
        h ^= h >> 33
        h &*= 0xC4CEB9FE1A85EC53
        h ^= h >> 33
        return Double(h & 0x00FF_FFFF) / Double(0x0100_0000)
    }

    private static func valueNoise3D(_ p: SIMD3<Double>) -> Double {
        let fx = floor(p.x)
        let fy = floor(p.y)
        let fz = floor(p.z)

        let ix = Int(fx)
        let iy = Int(fy)
        let iz = Int(fz)

        let dx = p.x - fx
        let dy = p.y - fy
        let dz = p.z - fz

        let ux = dx * dx * (3.0 - 2.0 * dx)
        let uy = dy * dy * (3.0 - 2.0 * dy)
        let uz = dz * dz * (3.0 - 2.0 * dz)

        let n000 = hash31(ix, iy, iz)
        let n100 = hash31(ix &+ 1, iy, iz)
        let n010 = hash31(ix, iy &+ 1, iz)
        let n110 = hash31(ix &+ 1, iy &+ 1, iz)

        let n001 = hash31(ix, iy, iz &+ 1)
        let n101 = hash31(ix &+ 1, iy, iz &+ 1)
        let n011 = hash31(ix, iy &+ 1, iz &+ 1)
        let n111 = hash31(ix &+ 1, iy &+ 1, iz &+ 1)

        let nx00 = n000 + (n100 - n000) * ux
        let nx10 = n010 + (n110 - n010) * ux
        let nx01 = n001 + (n101 - n001) * ux
        let nx11 = n011 + (n111 - n011) * ux

        let nxy0 = nx00 + (nx10 - nx00) * uy
        let nxy1 = nx01 + (nx11 - nx01) * uy

        return nxy0 + (nxy1 - nxy0) * uz
    }

    private static func fbm3D(_ p: SIMD3<Double>, octaves: Int) -> Double {
        var q = p
        var v = 0.0
        var a = 0.5
        for _ in 0..<octaves {
            v += a * valueNoise3D(q)
            q = q * 2.07 + SIMD3<Double>(13.1, 7.4, 19.7)
            a *= 0.49
        }
        return v
    }

    private static func ridgedFbm3D(_ p: SIMD3<Double>, octaves: Int) -> Double {
        var q = p
        var v = 0.0
        var a = 0.5
        var norm = 0.0
        for _ in 0..<octaves {
            let n = valueNoise3D(q)
            let r = 1.0 - abs(n * 2.0 - 1.0)
            v += a * (r * r)
            norm += a
            q = q * 2.13 + SIMD3<Double>(7.7, 17.3, 11.9)
            a *= 0.5
        }
        return norm > 0 ? (v / norm) : 0.0
    }

    private static func craterField3D(_ p: SIMD3<Double>) -> Double {
        let cx = Int(floor(p.x))
        let cy = Int(floor(p.y))
        let cz = Int(floor(p.z))

        var delta = 0.0
        for dz in -1...1 {
            for dy in -1...1 {
                for dx in -1...1 {
                    let ix = cx &+ dx
                    let iy = cy &+ dy
                    let iz = cz &+ dz

                    let prob = hash31(ix, iy, iz, seed: 11)
                    if prob < 0.42 { continue }

                    let jx = hash31(ix, iy, iz, seed: 23)
                    let jy = hash31(ix, iy, iz, seed: 37)
                    let jz = hash31(ix, iy, iz, seed: 53)
                    let center = SIMD3<Double>(
                        Double(ix) + 0.18 + 0.64 * jx,
                        Double(iy) + 0.18 + 0.64 * jy,
                        Double(iz) + 0.18 + 0.64 * jz
                    )
                    let radius = 0.16 + 0.24 * hash31(ix, iy, iz, seed: 71)
                    let dist = simd_length(p - center) / radius
                    if dist < 1.35 {
                        let depthWeight = 0.45 + 0.55 * prob
                        if dist < 1.0 {
                            let bowl = (dist * dist - 1.0) * 0.85
                            let rim = exp(-pow((dist - 1.0) * 5.2, 2.0)) * 0.36
                            delta += (bowl + rim) * depthWeight
                        } else {
                            let rim = exp(-pow((dist - 1.0) * 5.2, 2.0)) * 0.36
                            delta += rim * depthWeight
                        }
                    }
                }
            }
        }
        return max(-1.2, min(0.8, delta))
    }

    private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Double) -> SIMD3<Float> {
        let clamped = Float(max(0.0, min(1.0, t)))
        return a + (b - a) * clamped
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let denom = max(1e-9, edge1 - edge0)
        let t = max(0.0, min(1.0, (x - edge0) / denom))
        return t * t * (3.0 - 2.0 * t)
    }

    // MARK: - Unified Planetary Terrain Sampler (Including Human-Scale Hills & Craters)

    static func sampleTerrain(localDir: SIMD3<Double>, body: CelestialBody) -> TerrainSample {
        let dir = simd_length_squared(localDir) > 1e-12 ? simd_normalize(localDir) : SIMD3<Double>(0, 1, 0)
        let lat = abs(dir.y)
        let scale800m = max(12.0, body.radiusMeters / 800.0)
        let scale140m = max(60.0, body.radiusMeters / 140.0)

        if body.isHabitableWorld {
            let n = fbm3D(dir * 3.6, octaves: 4)
            let warp = fbm3D(dir * 2.2 + SIMD3<Double>(4.1, 1.7, 8.3), octaves: 3) * 0.25
            let elev = n + warp - 0.12
            let detail = fbm3D(dir * 18.0, octaves: 3)

            if lat + detail * 0.10 > 0.84 {
                let localHills = (fbm3D(dir * scale800m, octaves: 3) - 0.45) * 90.0 + (valueNoise3D(dir * scale140m) - 0.5) * 11.0
                let iceHeight = max(8.0, 60.0 + detail * 480.0 + localHills)
                return TerrainSample(
                    heightMeters: iceHeight,
                    color: SIMD3<Float>(0.76, 0.80, 0.85),
                    isWater: false
                )
            }

            if elev < 0.475 {
                let depthNorm = max(0.0, min(1.0, elev / 0.475))
                let bathymetry = (elev - 0.475) * 4_500.0
                let deepOcean = SIMD3<Float>(0.01, 0.04, 0.14)
                let shallowOcean = SIMD3<Float>(0.02, 0.18, 0.34)
                return TerrainSample(
                    heightMeters: bathymetry,
                    color: mix(deepOcean, shallowOcean, pow(depthNorm, 2.0)),
                    isWater: true
                )
            }

            let landFrac = max(0.0, (elev - 0.475) / 0.44)
            let mountainMask = smoothstep(0.18, 0.72, landFrac)
            let ridges = ridgedFbm3D(dir * 28.0, octaves: 4)
            let hills = fbm3D(dir * 140.0, octaves: 3)
            let localHills = (fbm3D(dir * scale800m, octaves: 3) - 0.45) * 140.0
            let microMounds = (valueNoise3D(dir * scale140m) - 0.5) * 13.0
            let height = max(2.0, landFrac * 1_200.0 + ridges * mountainMask * 4_400.0 + hills * 480.0 + localHills + microMounds)

            let sand = SIMD3<Float>(0.48, 0.42, 0.28)
            let forest = SIMD3<Float>(0.04, 0.16, 0.05)
            let meadow = SIMD3<Float>(0.17, 0.24, 0.09)
            let aridHighland = SIMD3<Float>(0.36, 0.29, 0.18)
            let rock = SIMD3<Float>(0.22, 0.21, 0.20)
            let snow = SIMD3<Float>(0.76, 0.80, 0.85)

            let isCold = (body.id == "proxima_b" || body.id == "kepler186f")
            let arid = smoothstep(0.06, 0.30, abs(lat - 0.26)) * smoothstep(0.18, 0.78, detail)
            var col = mix(aridHighland, mix(meadow, forest, detail), arid)
            if isCold {
                col = mix(col, SIMD3<Float>(0.22, 0.14, 0.12), 0.32)
            }
            col = mix(sand, col, smoothstep(8.0, 55.0, height))
            col = mix(col, rock, smoothstep(1_150.0, 2_200.0, height))
            col = mix(col, snow, smoothstep(2_800.0, 3_900.0, height + lat * 680.0))

            return TerrainSample(heightMeters: height, color: col, isWater: false)
        }

        if body.isIcyWorld || body.id == "trappist1f" || body.id == "trappist1g" {
            let base = fbm3D(dir * 4.0, octaves: 4)
            let ridges = ridgedFbm3D(dir * 20.0, octaves: 4)
            let localRidges = (ridgedFbm3D(dir * scale800m, octaves: 3) - 0.35) * 140.0
            let craters = craterField3D(dir * 26.0) * 900.0
            let micro = (valueNoise3D(dir * scale140m) - 0.5) * 11.0
            let height = (base - 0.48) * 1_800.0 + ridges * 1_600.0 + craters + localRidges + micro

            let crevasse = SIMD3<Float>(0.20, 0.34, 0.48)
            let iceSheet = SIMD3<Float>(0.54, 0.65, 0.74)
            let frostPeak = SIMD3<Float>(0.74, 0.80, 0.86)
            var col = mix(crevasse, iceSheet, smoothstep(-700.0, 900.0, height))
            col = mix(col, frostPeak, smoothstep(1_000.0, 2_400.0, height))
            return TerrainSample(heightMeters: height, color: col, isWater: false)
        }

        switch body.id {
        case "mars", "trappist1d":
            let base = fbm3D(dir * 3.8, octaves: 4)
            let ridges = ridgedFbm3D(dir * 19.0, octaves: 4)
            let micro = fbm3D(dir * 110.0, octaves: 3)
            let craters = craterField3D(dir * 34.0)
            let localRidges = (ridgedFbm3D(dir * scale800m, octaves: 3) - 0.35) * 160.0
            let localBumps = (valueNoise3D(dir * scale140m) - 0.5) * 12.0
            let height = (base - 0.48) * 3_800.0 + ridges * 3_200.0 + craters * 950.0 + (micro - 0.45) * 420.0 + localRidges + localBumps

            let darkBasalt = SIMD3<Float>(0.18, 0.07, 0.04)
            let terracotta = SIMD3<Float>(0.44, 0.18, 0.09)
            let ochre = SIMD3<Float>(0.58, 0.31, 0.16)
            var col = mix(darkBasalt, terracotta, smoothstep(-700.0, 1_500.0, height))
            col = mix(col, ochre, smoothstep(1_200.0, 4_200.0, height + ridges * 700.0))
            if lat + micro * 0.09 > 0.86 {
                col = SIMD3<Float>(0.78, 0.76, 0.74)
            }
            return TerrainSample(heightMeters: height, color: col, isWater: false)

        case "moon", "mercury", "ceres", "phobos":
            let maria = fbm3D(dir * 3.2, octaves: 4)
            let rough = fbm3D(dir * 26.0, octaves: 3)
            let largeCraters = craterField3D(dir * 16.0)
            let smallCraters = craterField3D(dir * 52.0)
            let localCraters = craterField3D(dir * scale800m) * 110.0
            let microBumps = (valueNoise3D(dir * scale140m) - 0.5) * 10.0
            let ampScale = (body.id == "phobos") ? 0.25 : 1.0
            let height = ((maria - 0.48) * 2_400.0 + (rough - 0.45) * 850.0 + largeCraters * 2_200.0 + smallCraters * 650.0) * ampScale + localCraters + microBumps

            let isMercury = (body.id == "mercury" || body.id == "phobos")
            let darkFloor = isMercury ? SIMD3<Float>(0.12, 0.11, 0.10) : SIMD3<Float>(0.11, 0.115, 0.125)
            let midRegolith = isMercury ? SIMD3<Float>(0.26, 0.24, 0.22) : SIMD3<Float>(0.24, 0.245, 0.255)
            let brightEjecta = isMercury ? SIMD3<Float>(0.42, 0.39, 0.36) : SIMD3<Float>(0.44, 0.445, 0.46)

            var col = mix(darkFloor, midRegolith, smoothstep(-1_200.0 * ampScale, 1_400.0 * ampScale, height))
            let rimHighlight = max(0.0, largeCraters + smallCraters * 0.5)
            col = mix(col, brightEjecta, smoothstep(0.05, 0.42, rimHighlight + (rough - 0.45) * 0.35))
            return TerrainSample(heightMeters: height, color: col, isWater: false)

        case "venus", "trappist1b", "titan", "io":
            let plains = fbm3D(dir * 4.2, octaves: 4)
            let volcanic = ridgedFbm3D(dir * 22.0, octaves: 4)
            let detail = fbm3D(dir * 95.0, octaves: 3)
            let localRidges = (ridgedFbm3D(dir * scale800m, octaves: 3) - 0.35) * 155.0
            let localBumps = (valueNoise3D(dir * scale140m) - 0.5) * 12.0
            let height = (plains - 0.48) * 2_800.0 + volcanic * 2_800.0 + (detail - 0.45) * 380.0 + localRidges + localBumps

            let isIo = (body.id == "io")
            let basalt = isIo ? SIMD3<Float>(0.22, 0.09, 0.03) : SIMD3<Float>(0.16, 0.10, 0.06)
            let sulfur = isIo ? SIMD3<Float>(0.68, 0.54, 0.12) : SIMD3<Float>(0.42, 0.28, 0.14)
            let peak = isIo ? SIMD3<Float>(0.80, 0.32, 0.08) : SIMD3<Float>(0.56, 0.42, 0.22)
            var col = mix(basalt, sulfur, smoothstep(-400.0, 1_600.0, height))
            col = mix(col, peak, smoothstep(1_800.0, 3_900.0, height))
            return TerrainSample(heightMeters: height, color: col, isWater: false)

        default:
            let base = fbm3D(dir * 5.0, octaves: 4)
            let localCraters = craterField3D(dir * scale800m) * 100.0
            let height = (base - 0.48) * 2_500.0 + localCraters
            let col = SIMD3<Float>(
                Float((body.colorHex >> 16) & 0xFF) / 255.0 * 0.55,
                Float((body.colorHex >> 8) & 0xFF) / 255.0 * 0.55,
                Float(body.colorHex & 0xFF) / 255.0 * 0.55
            )
            return TerrainSample(heightMeters: height, color: col, isWater: false)
        }
    }

    // MARK: - Scenic Approach Direction (Low-Angle Sunlight + Lush Rolling Land)

    static func findScenicApproachDirection(
        for body: CelestialBody,
        bodyPos: SIMD3<Double>,
        invPlanetRot: simd_quatd
    ) -> SIMD3<Double> {
        let toSun = simd_length_squared(bodyPos) > 1e6
            ? simd_normalize(-bodyPos)
            : simd_normalize(SIMD3<Double>(0.6, 0.25, 0.75))
        let refAxis = abs(toSun.y) > 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let right = simd_normalize(simd_cross(refAxis, toSun))
        let up = simd_normalize(simd_cross(toSun, right))
        let defaultDir = simd_normalize(toSun * 0.46 + right * 0.84 + up * 0.26)

        guard body.isHabitableWorld else {
            return defaultDir
        }

        var fallbackLandDir: SIMD3<Double>?
        var fallbackMaxHeight = -Double.greatestFiniteMagnitude

        for i in 0..<24 {
            let az = Double(i) * (.pi / 12.0)
            let candidate = simd_normalize(toSun * 0.46 + (right * cos(az) + up * sin(az)) * 0.88)
            let localDir = invPlanetRot.act(candidate)
            let lat = abs(localDir.y)
            let sample = sampleTerrain(localDir: localDir, body: body)
            if !sample.isWater {
                if lat >= 0.20 && lat <= 0.68 && sample.heightMeters > 220.0 && sample.heightMeters < 1_400.0 {
                    return candidate
                }
                if sample.heightMeters > fallbackMaxHeight {
                    fallbackMaxHeight = sample.heightMeters
                    fallbackLandDir = candidate
                }
            }
        }
        return fallbackLandDir ?? defaultDir
    }

    // MARK: - Curved Spherical-Tangent 3D Terrain Mesh Builder

    private static func projectKmUV(localDir: SIMD3<Double>, dominantAxis: Int, radiusKm: Double) -> CGPoint {
        switch dominantAxis {
        case 1:
            return CGPoint(x: localDir.x * radiusKm, y: localDir.z * radiusKm)
        case 0:
            return CGPoint(x: localDir.z * radiusKm, y: localDir.y * radiusKm)
        default:
            return CGPoint(x: localDir.x * radiusKm, y: localDir.y * radiusKm)
        }
    }

    static func buildTerrainGeometry(
        body: CelestialBody,
        bodyPos: SIMD3<Double>,
        anchorWorld: SIMD3<Double>,
        planetRot: simd_quatd,
        invPlanetRot: simd_quatd,
        altitudeMeters: Double,
        whitePixel: UIImage,
        compress: (SIMD3<Double>) -> (pos: SIMD3<Float>, scaleFactor: Double)
    ) -> (terrain: SCNGeometry, ocean: SCNGeometry?, collision: TerrainCollisionGrid) {
        let rawUp = anchorWorld - bodyPos
        let upWorld = simd_length_squared(rawUp) > 1e-12 ? simd_normalize(rawUp) : SIMD3<Double>(0, 1, 0)
        let refAxis = abs(upWorld.y) > 0.95 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let north = simd_normalize(simd_cross(upWorld, refAxis))
        let east = simd_normalize(simd_cross(north, upWorld))
        let upF = SIMD3<Float>(Float(upWorld.x), Float(upWorld.y), Float(upWorld.z))

        let localUp = invPlanetRot.act(upWorld)
        let ax = abs(localUp.x)
        let ay = abs(localUp.y)
        let az = abs(localUp.z)
        let dominantAxis = (ay >= ax && ay >= az) ? 1 : ((ax >= ay && ax >= az) ? 0 : 2)
        let radiusKm = body.radiusMeters / 1_000.0

        let isLowAlt = altitudeMeters < 1_500.0
        let gridN = isLowAlt ? 85 : 73
        let vertexCount = gridN * gridN
        let horizonDist = sqrt(max(1.0, 2.0 * body.radiusMeters * max(50.0, altitudeMeters)))
        let patchHalfExtent = isLowAlt
            ? min(body.radiusMeters * 0.30, max(12_000.0, horizonDist * 1.15))
            : min(body.radiusMeters * 0.36, max(22_000.0, horizonDist * 1.05))

        var uCoords = [Double](repeating: 0.0, count: gridN)
        var vCoords = [Double](repeating: 0.0, count: gridN)
        for idx in 0..<gridN {
            let t = (Double(idx) / Double(gridN - 1)) * 2.0 - 1.0
            let sign = t >= 0 ? 1.0 : -1.0
            let c = isLowAlt
                ? sign * (0.015 * abs(t) + 0.985 * abs(t * t * t))
                : sign * (0.12 * abs(t) + 0.88 * t * t)
            uCoords[idx] = c
            vCoords[idx] = c
        }

        var positionsSIMD = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        var vertexHeights = [Double](repeating: 0.0, count: vertexCount)
        var colorFloats = [Float](repeating: 0.5, count: vertexCount * 3)
        var uvs = [CGPoint](repeating: .zero, count: vertexCount)

        for iz in 0..<gridN {
            let v = vCoords[iz]
            for ix in 0..<gridN {
                let u = uCoords[ix]

                let offset = east * (u * patchHalfExtent) + north * (v * patchHalfExtent)
                let dirWorld = simd_normalize(upWorld * body.radiusMeters + offset)
                let localDir = invPlanetRot.act(dirWorld)
                let sample = sampleTerrain(localDir: localDir, body: body)

                let rawHeight = sample.isWater ? (sample.heightMeters - 28.0) : sample.heightMeters
                let vertexHeight = body.isHabitableWorld ? max(-120.0, rawHeight) : sample.heightMeters
                let ptWorld = bodyPos + dirWorld * (body.radiusMeters + vertexHeight)
                let (scenePos, _) = compress(ptWorld - anchorWorld)

                let idx = iz * gridN + ix
                positionsSIMD[idx] = scenePos
                vertexHeights[idx] = vertexHeight
                uvs[idx] = projectKmUV(localDir: localDir, dominantAxis: dominantAxis, radiusKm: radiusKm)
                let cBase = idx * 3
                colorFloats[cBase] = sample.color.x
                colorFloats[cBase + 1] = sample.color.y
                colorFloats[cBase + 2] = sample.color.z
            }
        }

        var positions = [SCNVector3]()
        positions.reserveCapacity(vertexCount)
        var normals = [SCNVector3]()
        normals.reserveCapacity(vertexCount)

        for iz in 0..<gridN {
            for ix in 0..<gridN {
                let idx = iz * gridN + ix
                let p = positionsSIMD[idx]
                positions.append(SCNVector3(p.x, p.y, p.z))

                let pL = positionsSIMD[iz * gridN + max(0, ix - 1)]
                let pR = positionsSIMD[iz * gridN + min(gridN - 1, ix + 1)]
                let pD = positionsSIMD[max(0, iz - 1) * gridN + ix]
                let pU = positionsSIMD[min(gridN - 1, iz + 1) * gridN + ix]

                var n = simd_cross(pR - pL, pU - pD)
                if simd_length_squared(n) < 1e-12 {
                    n = upF
                } else {
                    n = simd_normalize(n)
                    if simd_dot(n, upF) < 0 { n = -n }
                }
                normals.append(SCNVector3(n.x, n.y, n.z))
            }
        }

        let quadCount = (gridN - 1) * (gridN - 1)
        var indices = [Int32]()
        indices.reserveCapacity(quadCount * 6)

        for iz in 0..<(gridN - 1) {
            for ix in 0..<(gridN - 1) {
                let i00 = Int32(iz * gridN + ix)
                let i10 = Int32(iz * gridN + (ix + 1))
                let i01 = Int32((iz + 1) * gridN + ix)
                let i11 = Int32((iz + 1) * gridN + (ix + 1))

                appendOutwardTriangle(i00, i10, i11, positions: positionsSIMD, up: upF, into: &indices)
                appendOutwardTriangle(i00, i11, i01, positions: positionsSIMD, up: upF, into: &indices)
            }
        }

        let posSource = SCNGeometrySource(vertices: positions)
        let normSource = SCNGeometrySource(normals: normals)
        let texcoordSource = SCNGeometrySource(textureCoordinates: uvs)
        let colorData = colorFloats.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)

        let tex = surfacePBRTextures(for: body)
        let terrainMat = SCNMaterial()
        terrainMat.lightingModel = .physicallyBased
        terrainMat.diffuse.contents = tex.diffuse
        terrainMat.diffuse.wrapS = .repeat
        terrainMat.diffuse.wrapT = .repeat
        terrainMat.diffuse.mipFilter = .linear
        terrainMat.diffuse.maxAnisotropy = 8
        terrainMat.diffuse.contentsTransform = SCNMatrix4MakeScale(36.0, 36.0, 1.0)
        terrainMat.normal.contents = tex.normal
        terrainMat.normal.wrapS = .repeat
        terrainMat.normal.wrapT = .repeat
        terrainMat.normal.mipFilter = .linear
        terrainMat.normal.maxAnisotropy = 8
        terrainMat.normal.contentsTransform = SCNMatrix4MakeScale(36.0, 36.0, 1.0)
        terrainMat.normal.intensity = 1.15
        terrainMat.roughness.contents = body.isIcyWorld ? 0.42 : 0.90
        terrainMat.metalness.contents = 0.02
        terrainMat.shaderModifiers = [.surface: terrainShaderModifier(for: body)]

        let terrainGeo = SCNGeometry(sources: [posSource, normSource, texcoordSource, colorSource], elements: [element])
        terrainGeo.materials = [terrainMat]

        var oceanGeo: SCNGeometry? = nil
        if body.isHabitableWorld {
            oceanGeo = buildEarthOceanGeometry(
                body: body,
                bodyPos: bodyPos,
                anchorWorld: anchorWorld,
                invPlanetRot: invPlanetRot,
                upWorld: upWorld,
                east: east,
                north: north,
                upF: upF,
                dominantAxis: dominantAxis,
                radiusKm: radiusKm,
                patchHalfExtent: patchHalfExtent,
                whitePixel: whitePixel,
                compress: compress
            )
        }

        let collision = TerrainCollisionGrid(
            bodyId: body.id,
            gridN: gridN,
            uCoords: uCoords,
            vCoords: vCoords,
            east: east,
            north: north,
            upWorld: upWorld,
            buildPlanetRot: planetRot,
            bodyRadius: body.radiusMeters,
            patchHalfExtent: patchHalfExtent,
            vertexHeights: vertexHeights,
            isHabitableWorld: body.isHabitableWorld
        )

        return (terrainGeo, oceanGeo, collision)
    }

    private static func buildEarthOceanGeometry(
        body: CelestialBody,
        bodyPos: SIMD3<Double>,
        anchorWorld: SIMD3<Double>,
        invPlanetRot: simd_quatd,
        upWorld: SIMD3<Double>,
        east: SIMD3<Double>,
        north: SIMD3<Double>,
        upF: SIMD3<Float>,
        dominantAxis: Int,
        radiusKm: Double,
        patchHalfExtent: Double,
        whitePixel: UIImage,
        compress: (SIMD3<Double>) -> (pos: SIMD3<Float>, scaleFactor: Double)
    ) -> SCNGeometry {
        let oceanN = 33
        let vCount = oceanN * oceanN
        var posSIMD = [SIMD3<Float>](repeating: .zero, count: vCount)
        var positions = [SCNVector3]()
        positions.reserveCapacity(vCount)
        var normals = [SCNVector3]()
        normals.reserveCapacity(vCount)
        var uvs = [CGPoint]()
        uvs.reserveCapacity(vCount)

        for iz in 0..<oceanN {
            let tz = (Double(iz) / Double(oceanN - 1)) * 2.0 - 1.0
            let v = (tz >= 0 ? 1.0 : -1.0) * (0.12 * abs(tz) + 0.88 * tz * tz)
            for ix in 0..<oceanN {
                let tx = (Double(ix) / Double(oceanN - 1)) * 2.0 - 1.0
                let u = (tx >= 0 ? 1.0 : -1.0) * (0.12 * abs(tx) + 0.88 * tx * tx)

                let offset = east * (u * patchHalfExtent) + north * (v * patchHalfExtent)
                let dirWorld = simd_normalize(upWorld * body.radiusMeters + offset)
                let localDir = invPlanetRot.act(dirWorld)
                let ptWorld = bodyPos + dirWorld * body.radiusMeters
                let (scenePos, _) = compress(ptWorld - anchorWorld)

                posSIMD[iz * oceanN + ix] = scenePos
                positions.append(SCNVector3(scenePos.x, scenePos.y, scenePos.z))
                normals.append(SCNVector3(Float(dirWorld.x), Float(dirWorld.y), Float(dirWorld.z)))
                uvs.append(projectKmUV(localDir: localDir, dominantAxis: dominantAxis, radiusKm: radiusKm))
            }
        }

        var indices = [Int32]()
        indices.reserveCapacity((oceanN - 1) * (oceanN - 1) * 6)
        for iz in 0..<(oceanN - 1) {
            for ix in 0..<(oceanN - 1) {
                let i00 = Int32(iz * oceanN + ix)
                let i10 = Int32(iz * oceanN + (ix + 1))
                let i01 = Int32((iz + 1) * oceanN + ix)
                let i11 = Int32((iz + 1) * oceanN + (ix + 1))

                appendOutwardTriangle(i00, i10, i11, positions: posSIMD, up: upF, into: &indices)
                appendOutwardTriangle(i00, i11, i01, positions: posSIMD, up: upF, into: &indices)
            }
        }

        let oceanMat = SCNMaterial()
        oceanMat.lightingModel = .physicallyBased
        oceanMat.diffuse.contents = whitePixel
        oceanMat.roughness.contents = 0.09
        oceanMat.metalness.contents = 0.12
        oceanMat.writesToDepthBuffer = true
        oceanMat.shaderModifiers = [.surface: """
        float hash21(vec2 p) {
            p = fract(p * vec2(123.34, 456.21));
            p += dot(p, p + 45.32);
            return fract(p.x * p.y);
        }

        float noise2D(vec2 p) {
            vec2 i = floor(p);
            vec2 f = fract(p);
            f = f * f * (3.0 - 2.0 * f);
            float a = hash21(i);
            float b = hash21(i + vec2(1.0, 0.0));
            float c = hash21(i + vec2(0.0, 1.0));
            float d = hash21(i + vec2(1.0, 1.0));
            return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
        }

        float waterFbm(vec2 p) {
            float v = 0.0;
            float a = 0.5;
            for (int i = 0; i < 3; i++) {
                v += a * noise2D(p);
                p = p * 2.08 + vec2(11.3, 17.7);
                a *= 0.48;
            }
            return v;
        }

        #pragma body
        vec2 uv = _surface.diffuseTexcoord;
        float pixKm = max(0.0005, length(vec2(dFdx(uv.x), dFdy(uv.x))) + length(vec2(dFdx(uv.y), dFdy(uv.y))));

        float swellFade = 1.0 - smoothstep(0.08, 0.35, pixKm);
        float waveFade = 1.0 - smoothstep(0.015, 0.07, pixKm);
        float rippleFade = 1.0 - smoothstep(0.002, 0.012, pixKm);

        float wSwell = waterFbm(uv * 4.5 + vec2(u_time * 0.08, -u_time * 0.05));
        float wMed = waterFbm(uv * 22.0 + vec2(-u_time * 0.35, u_time * 0.25));
        float wRipple = noise2D(uv * 110.0 + vec2(u_time * 0.9, u_time * 0.6));

        float waveH = wSwell * 0.55 * swellFade + wMed * 0.32 * waveFade + wRipple * 0.13 * rippleFade;
        vec3 dN = vec3(dFdx(waveH), dFdy(waveH), 0.0);
        _surface.normal = normalize(_surface.normal - dN * (3.2 * (swellFade * 0.4 + waveFade * 0.6)));

        float ndotv = clamp(abs(dot(normalize(_surface.normal), normalize(_surface.view))), 0.0, 1.0);
        float fresnel = pow(clamp(1.0 - ndotv, 0.0001, 1.0), 3.5);
        vec3 waterCol = mix(vec3(0.008, 0.055, 0.14), vec3(0.26, 0.50, 0.78), fresnel * 0.72);
        waterCol += vec3(0.18) * rippleFade * smoothstep(0.68, 0.85, wMed);

        _surface.diffuse = vec4(waterCol, 0.96);
        _surface.roughness = mix(0.08, 0.18, rippleFade * 0.4);
        """]

        let geo = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: positions),
                SCNGeometrySource(normals: normals),
                SCNGeometrySource(textureCoordinates: uvs)
            ],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
        geo.materials = [oceanMat]
        return geo
    }

    // MARK: - Procedural 3D Surface Props (Trees, Bushes, Rocks, Ice Spires)

    static func buildSurfaceProps(
        body: CelestialBody,
        bodyPos: SIMD3<Double>,
        anchorWorld: SIMD3<Double>,
        planetRot: simd_quatd,
        invPlanetRot: simd_quatd,
        clearCenterWorld: SIMD3<Double>?,
        collisionGrid: TerrainCollisionGrid?
    ) -> SCNNode {
        let container = SCNNode()
        let rawUp = anchorWorld - bodyPos
        let upWorld = simd_length_squared(rawUp) > 1e-12 ? simd_normalize(rawUp) : SIMD3<Double>(0, 1, 0)
        let localAnchor = invPlanetRot.act(upWorld) * body.radiusMeters

        let ax = abs(localAnchor.x)
        let ay = abs(localAnchor.y)
        let az = abs(localAnchor.z)
        let dominantAxis = (ay >= ax && ay >= az) ? 1 : ((ax >= ay && ax >= az) ? 0 : 2)

        let u0: Double
        let v0: Double
        let domSign: Double
        switch dominantAxis {
        case 1:
            u0 = localAnchor.x
            v0 = localAnchor.z
            domSign = localAnchor.y >= 0 ? 1.0 : -1.0
        case 0:
            u0 = localAnchor.z
            v0 = localAnchor.y
            domSign = localAnchor.x >= 0 ? 1.0 : -1.0
        default:
            u0 = localAnchor.x
            v0 = localAnchor.y
            domSign = localAnchor.z >= 0 ? 1.0 : -1.0
        }

        // Shared materials & geometries
        let trunkMat = SCNMaterial()
        trunkMat.lightingModel = .physicallyBased
        trunkMat.diffuse.contents = UIColor(red: 0.24, green: 0.16, blue: 0.09, alpha: 1.0)
        trunkMat.roughness.contents = 0.94

        let pineMat = SCNMaterial()
        pineMat.lightingModel = .physicallyBased
        pineMat.diffuse.contents = body.id == "earth"
            ? UIColor(red: 0.07, green: 0.24, blue: 0.08, alpha: 1.0)
            : UIColor(red: 0.14, green: 0.26, blue: 0.16, alpha: 1.0)
        pineMat.roughness.contents = 0.88

        let bushMat = SCNMaterial()
        bushMat.lightingModel = .physicallyBased
        bushMat.diffuse.contents = UIColor(red: 0.11, green: 0.29, blue: 0.10, alpha: 1.0)
        bushMat.roughness.contents = 0.90

        let rockMat = SCNMaterial()
        rockMat.lightingModel = .physicallyBased
        switch body.id {
        case "mars", "trappist1d":
            rockMat.diffuse.contents = UIColor(red: 0.42, green: 0.18, blue: 0.10, alpha: 1.0)
        case "moon", "mercury", "ceres", "phobos":
            rockMat.diffuse.contents = UIColor(red: 0.22, green: 0.23, blue: 0.25, alpha: 1.0)
        case "venus", "trappist1b", "io":
            rockMat.diffuse.contents = UIColor(red: 0.24, green: 0.16, blue: 0.09, alpha: 1.0)
        case "titan":
            rockMat.diffuse.contents = UIColor(red: 0.48, green: 0.30, blue: 0.12, alpha: 1.0)
        default:
            rockMat.diffuse.contents = UIColor(red: 0.32, green: 0.31, blue: 0.29, alpha: 1.0)
        }
        rockMat.roughness.contents = 0.94

        let iceMat = SCNMaterial()
        iceMat.lightingModel = .physicallyBased
        iceMat.diffuse.contents = UIColor(red: 0.64, green: 0.82, blue: 0.94, alpha: 0.92)
        iceMat.roughness.contents = 0.25
        iceMat.metalness.contents = 0.1

        let trunkGeo = SCNCylinder(radius: 0.22, height: 2.2)
        trunkGeo.materials = [trunkMat]
        let coneLowGeo = SCNCone(topRadius: 0.18, bottomRadius: 1.65, height: 2.6)
        coneLowGeo.materials = [pineMat]
        let coneMidGeo = SCNCone(topRadius: 0.12, bottomRadius: 1.28, height: 2.3)
        coneMidGeo.materials = [pineMat]
        let coneTopGeo = SCNCone(topRadius: 0.03, bottomRadius: 0.88, height: 1.9)
        coneTopGeo.materials = [pineMat]

        let bushGeo = SCNSphere(radius: 0.95)
        bushGeo.segmentCount = 12
        bushGeo.materials = [bushMat]

        let boulderGeo = SCNBox(width: 1.4, height: 0.95, length: 1.25, chamferRadius: 0.34)
        boulderGeo.materials = [rockMat]

        let slabGeo = SCNBox(width: 2.0, height: 0.55, length: 1.7, chamferRadius: 0.18)
        slabGeo.materials = [rockMat]

        let spireGeo = SCNPyramid(width: 1.1, height: 3.4, length: 1.1)
        spireGeo.materials = [iceMat]

        let cellSize = 35.0
        let cx0 = Int(floor(u0 / cellSize))
        let cz0 = Int(floor(v0 / cellSize))
        let R = body.radiusMeters
        let R2 = R * R

        for dz in -12...12 {
            for dx in -12...12 {
                let cx = cx0 &+ dx
                let cz = cz0 &+ dz

                let prob = hash31(cx, cz, dominantAxis, seed: 404)
                let spawnThreshold = body.isHabitableWorld ? 0.72 : 0.78
                if prob < spawnThreshold { continue }

                let h1 = hash31(cx, cz, dominantAxis, seed: 509)
                let h2 = hash31(cx, cz, dominantAxis, seed: 613)
                let h3 = hash31(cx, cz, dominantAxis, seed: 719)
                let h4 = hash31(cx, cz, dominantAxis, seed: 823)

                let u = (Double(cx) + 0.15 + 0.70 * h1) * cellSize
                let v = (Double(cz) + 0.15 + 0.70 * h2) * cellSize
                let comp2 = R2 - u * u - v * v
                if comp2 <= 100.0 { continue }
                let w = domSign * sqrt(comp2)

                let localDir: SIMD3<Double>
                switch dominantAxis {
                case 1: localDir = simd_normalize(SIMD3<Double>(u, w, v))
                case 0: localDir = simd_normalize(SIMD3<Double>(w, v, u))
                default: localDir = simd_normalize(SIMD3<Double>(u, v, w))
                }

                let sample = sampleTerrain(localDir: localDir, body: body)
                if sample.isWater { continue }

                let dirWorld = planetRot.act(localDir)
                let roughWorld = bodyPos + dirWorld * (R + sample.heightMeters)
                let propHeight = collisionGrid?.sampleHeight(
                    worldPos: roughWorld,
                    currentPlanetRot: planetRot,
                    currentBodyPos: bodyPos
                ) ?? (body.isHabitableWorld ? max(0.0, sample.heightMeters) : sample.heightMeters)
                let propWorld = bodyPos + dirWorld * (R + propHeight)
                let distAnchor = simd_length(propWorld - anchorWorld)
                if distAnchor < 14.0 || distAnchor > 430.0 { continue }

                if let clearPos = clearCenterWorld, simd_length(propWorld - clearPos) < 14.0 {
                    continue
                }

                let propNode = SCNNode()
                let relPos = propWorld - anchorWorld
                propNode.simdPosition = SIMD3<Float>(Float(relPos.x), Float(relPos.y), Float(relPos.z))

                let upF = SIMD3<Float>(Float(dirWorld.x), Float(dirWorld.y), Float(dirWorld.z))
                let alignQ = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(upF))
                let yawQ = simd_quatf(angle: Float(h3 * 2.0 * .pi), axis: SIMD3<Float>(0, 1, 0))
                propNode.simdOrientation = simd_normalize(alignQ * yawQ)

                if body.isHabitableWorld && sample.heightMeters > 15.0 && sample.heightMeters < 1_800.0 {
                    if h4 < 0.56 {
                        // Многоярусная сосна/ель (4–10 м)
                        let s = Float(0.85 + h3 * 0.85)
                        let tNode = SCNNode(geometry: trunkGeo)
                        tNode.position = SCNVector3(0, 1.0, 0)
                        propNode.addChildNode(tNode)

                        let c1 = SCNNode(geometry: coneLowGeo)
                        c1.position = SCNVector3(0, 2.7, 0)
                        propNode.addChildNode(c1)

                        let c2 = SCNNode(geometry: coneMidGeo)
                        c2.position = SCNVector3(0, 4.1, 0)
                        propNode.addChildNode(c2)

                        let c3 = SCNNode(geometry: coneTopGeo)
                        c3.position = SCNVector3(0, 5.4, 0)
                        propNode.addChildNode(c3)

                        propNode.simdScale = SIMD3<Float>(repeating: s)
                    } else if h4 < 0.80 {
                        // Пышный кустарник
                        let bNode = SCNNode(geometry: bushGeo)
                        bNode.position = SCNVector3(0, 0.52, 0)
                        bNode.scale = SCNVector3(Float(1.1 + h1 * 0.7), Float(0.75 + h2 * 0.4), Float(1.0 + h3 * 0.6))
                        propNode.addChildNode(bNode)
                    } else {
                        // Гранитный валун
                        let rNode = SCNNode(geometry: boulderGeo)
                        rNode.position = SCNVector3(0, 0.36, 0)
                        let s = Float(0.8 + h3 * 1.9)
                        propNode.simdScale = SIMD3<Float>(s, s * 0.82, s * 1.05)
                        propNode.addChildNode(rNode)
                    }
                } else if body.isIcyWorld {
                    if h4 < 0.52 {
                        let spNode = SCNNode(geometry: spireGeo)
                        spNode.position = SCNVector3(0, 1.4, 0)
                        let s = Float(0.75 + h3 * 1.4)
                        propNode.simdScale = SIMD3<Float>(s * 0.9, s * 1.2, s * 0.9)
                        propNode.addChildNode(spNode)
                    } else {
                        let rNode = SCNNode(geometry: boulderGeo)
                        rNode.position = SCNVector3(0, 0.36, 0)
                        let s = Float(0.7 + h3 * 1.6)
                        propNode.simdScale = SIMD3<Float>(s, s * 0.75, s)
                        propNode.addChildNode(rNode)
                    }
                } else {
                    // Луна, Марс, Меркурий, Венера, Ио, Титан: валуны и каменные плиты
                    let geo = (h4 < 0.65) ? boulderGeo : slabGeo
                    let rNode = SCNNode(geometry: geo)
                    rNode.position = SCNVector3(0, geo === boulderGeo ? 0.34 : 0.20, 0)
                    let s = Float(0.65 + h3 * 2.2)
                    propNode.simdScale = SIMD3<Float>(s, s * Float(0.65 + h1 * 0.45), s * Float(0.85 + h2 * 0.35))
                    propNode.addChildNode(rNode)
                }

                container.addChildNode(propNode)
            }
        }

        return container
    }

    private static func appendOutwardTriangle(
        _ i0: Int32,
        _ i1: Int32,
        _ i2: Int32,
        positions: [SIMD3<Float>],
        up: SIMD3<Float>,
        into indices: inout [Int32]
    ) {
        let v0 = positions[Int(i0)]
        let v1 = positions[Int(i1)]
        let v2 = positions[Int(i2)]
        let crossVec = simd_cross(v1 - v0, v2 - v0)
        if simd_dot(crossVec, up) >= 0 {
            indices.append(i0)
            indices.append(i1)
            indices.append(i2)
        } else {
            indices.append(i0)
            indices.append(i2)
            indices.append(i1)
        }
    }

    // MARK: - Per-Pixel Terrain Surface GLSL Shader

    static func terrainShaderModifier(for body: CelestialBody) -> String {
        let mode: Int
        if body.isHabitableWorld {
            mode = 1
        } else if body.id == "mars" || body.id == "trappist1d" {
            mode = 2
        } else if body.id == "venus" || body.id == "trappist1b" || body.id == "titan" || body.id == "io" {
            mode = 3
        } else if body.isIcyWorld || body.id == "trappist1f" || body.id == "trappist1g" {
            mode = 5
        } else {
            mode = 4
        }

        return """
        float hash21(vec2 p) {
            p = fract(p * vec2(123.34, 456.21));
            p += dot(p, p + 45.32);
            return fract(p.x * p.y);
        }

        float noise2D(vec2 p) {
            vec2 i = floor(p);
            vec2 f = fract(p);
            f = f * f * (3.0 - 2.0 * f);
            float a = hash21(i);
            float b = hash21(i + vec2(1.0, 0.0));
            float c = hash21(i + vec2(0.0, 1.0));
            float d = hash21(i + vec2(1.0, 1.0));
            return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
        }

        float fbm2D(vec2 p) {
            float v = 0.0;
            float a = 0.5;
            for (int i = 0; i < 5; i++) {
                v += a * noise2D(p);
                p = p * 2.07 + vec2(13.1, 7.4);
                a *= 0.49;
            }
            return v;
        }

        float ridged2D(vec2 p) {
            float v = 0.0;
            float a = 0.5;
            float norm = 0.0;
            for (int i = 0; i < 4; i++) {
                float r = 1.0 - abs(noise2D(p) * 2.0 - 1.0);
                v += a * (r * r);
                norm += a;
                p = p * 2.13 + vec2(7.7, 17.3);
                a *= 0.5;
            }
            return norm > 0.0 ? (v / norm) : 0.0;
        }

        float crater2D(vec2 p) {
            vec2 ip = floor(p);
            vec2 fp = fract(p);
            float total = 0.0;
            for (int y = -1; y <= 1; y++) {
                for (int x = -1; x <= 1; x++) {
                    vec2 neighbor = vec2(float(x), float(y));
                    vec2 cell = ip + neighbor;
                    float prob = hash21(cell);
                    if (prob > 0.35) {
                        vec2 rnd = vec2(hash21(cell + vec2(17.1, 31.7)), hash21(cell + vec2(59.3, 11.9)));
                        vec2 center = neighbor + 0.2 + 0.6 * rnd;
                        float r = 0.18 + 0.24 * hash21(cell + vec2(83.7, 47.2));
                        float d = length(fp - center) / r;
                        if (d < 1.35) {
                            float bowl = (d < 1.0) ? (d * d - 1.0) * 0.85 : 0.0;
                            float rimT = (d - 1.0) * 5.2;
                            float rim = exp(-(rimT * rimT)) * 0.38;
                            total += (bowl + rim) * (0.45 + 0.55 * prob);
                        }
                    }
                }
            }
            return clamp(total, -1.0, 0.8);
        }

        #pragma body
        vec2 km = _surface.diffuseTexcoord / 36.0;
        float pixKm = max(0.0005, length(vec2(dFdx(km.x), dFdy(km.x))) + length(vec2(dFdx(km.y), dFdy(km.y))));
        float closeFade = 1.0 - smoothstep(0.002, 0.015, pixKm);
        float fineFade = 1.0 - smoothstep(0.008, 0.06, pixKm);
        float medFade = 1.0 - smoothstep(0.06, 0.35, pixKm);

        vec3 baseCol = clamp(_surface.diffuse.rgb * 1.42, 0.0, 1.0);
        vec3 col = baseCol;
        float rough = 0.90;
        float microH = 0.0;
        float bumpStrength = 5.5;

        int tMode = \(mode);
        if (tMode == 1) {
            float macro = fbm2D(km * 0.18);
            float ridge = ridged2D(km * 0.75);
            float micro = fbm2D(km * 6.5) * medFade + 0.5 * (1.0 - medFade);
            float fine = noise2D(km * 48.0) * fineFade + 0.5 * (1.0 - fineFade);
            float grass = noise2D(km * 240.0) * closeFade + 0.5 * (1.0 - closeFade);

            float cliff = smoothstep(0.45, 0.82, ridge);
            col = mix(baseCol * (0.76 + 0.48 * macro), baseCol * 0.62, cliff * 0.42);
            col *= (0.84 + 0.28 * micro + 0.14 * (fine - 0.5) + 0.12 * (grass - 0.5));

            float cloudSh = smoothstep(0.56, 0.76, fbm2D(km * 0.06 + vec2(u_time * 0.01, 0.0)));
            col *= (1.0 - cloudSh * 0.30);

            microH = ridge * 0.40 + micro * 0.25 * medFade + fine * 0.20 * fineFade + grass * 0.15 * closeFade;
            bumpStrength = 5.0;
            rough = mix(0.88, 0.74, cliff);
        } else if (tMode == 2) {
            float cr = crater2D(km * 0.35);
            float ridge = ridged2D(km * 0.65);
            float dunes = (sin(km.x * 16.0 + fbm2D(km * 2.5) * 6.0) * 0.5 + 0.5) * fineFade + 0.5 * (1.0 - fineFade);
            float micro = fbm2D(km * 12.0) * medFade + 0.5 * (1.0 - medFade);
            float grit = noise2D(km * 180.0) * closeFade + 0.5 * (1.0 - closeFade);

            col = baseCol * (0.78 + 0.38 * micro + 0.16 * dunes + 0.14 * (grit - 0.5));
            col = mix(col, vec3(0.22, 0.09, 0.05), clamp(-cr, 0.0, 0.6) * 0.45);
            col = mix(col, vec3(0.62, 0.34, 0.18), smoothstep(0.08, 0.38, cr) * 0.35);

            microH = cr * 0.35 + ridge * 0.30 + dunes * 0.15 * fineFade + grit * 0.20 * closeFade;
            bumpStrength = 5.5;
            rough = 0.92;
        } else if (tMode == 3) {
            float ridge = ridged2D(km * 0.80);
            float frac = ridged2D(km * 3.5) * medFade;
            float micro = fbm2D(km * 14.0) * medFade + 0.5 * (1.0 - medFade);
            float grit = noise2D(km * 190.0) * closeFade + 0.5 * (1.0 - closeFade);

            col = baseCol * (0.80 + 0.36 * micro + 0.14 * (grit - 0.5));
            col = mix(col, vec3(0.14, 0.08, 0.04), smoothstep(0.55, 0.90, frac) * 0.45);

            microH = ridge * 0.42 + frac * 0.28 + micro * 0.18 * medFade + grit * 0.12 * closeFade;
            bumpStrength = 5.0;
            rough = 0.86;
        } else if (tMode == 5) {
            float crev = ridged2D(km * 1.4);
            float micro = fbm2D(km * 10.0) * medFade + 0.5 * (1.0 - medFade);
            float frost = noise2D(km * 150.0) * closeFade + 0.5 * (1.0 - closeFade);

            col = mix(baseCol * (0.86 + 0.28 * micro), vec3(0.24, 0.44, 0.62), smoothstep(0.62, 0.92, crev) * 0.55);
            col += vec3(0.08, 0.10, 0.12) * (frost - 0.5);

            microH = crev * 0.48 + micro * 0.28 * medFade + frost * 0.24 * closeFade;
            bumpStrength = 4.5;
            rough = mix(0.30, 0.58, crev);
        } else {
            float cBig = crater2D(km * 0.12);
            float cMed = crater2D(km * 0.65) * medFade;
            float cSmall = crater2D(km * 3.5) * fineFade;
            float grit = fbm2D(km * 18.0) * fineFade + 0.5 * (1.0 - fineFade);
            float dust = noise2D(km * 220.0) * closeFade + 0.5 * (1.0 - closeFade);

            float cSum = cBig * 0.50 + cMed * 0.35 + cSmall * 0.22;
            col = baseCol * (0.82 + 0.38 * grit + 0.16 * (dust - 0.5));
            col *= (1.0 - clamp(-cSum, 0.0, 0.60) * 0.48);
            col += vec3(0.10, 0.10, 0.11) * smoothstep(0.05, 0.35, cSum);

            microH = cBig * 0.38 + cMed * 0.28 + cSmall * 0.16 + dust * 0.18 * closeFade;
            bumpStrength = 6.0;
            rough = 0.95;
        }

        bumpStrength *= fineFade;
        vec3 dN = vec3(dFdx(microH), dFdy(microH), 0.0);
        _surface.normal = normalize(_surface.normal - dN * bumpStrength);
        _surface.diffuse = vec4(col, 1.0);
        _surface.roughness = rough;
        """
    }

    // MARK: - Interior Atmospheric Sky Dome GLSL Shader (With Volumetric Drifting Clouds)

    static func skyDomeShaderModifier() -> String {
        return """
        uniform vec3 sunDirView;
        uniform vec3 upDirView;
        uniform vec3 eastDirView;
        uniform vec3 zenithCol;
        uniform vec3 horizonCol;
        uniform vec3 sunsetCol;
        uniform float atmoDensity;
        uniform float cloudAmount;

        float hash21(vec2 p) {
            p = fract(p * vec2(127.1, 311.7));
            p += dot(p, p + 34.5);
            return fract(p.x * p.y);
        }

        float noise2D(vec2 p) {
            vec2 i = floor(p);
            vec2 f = fract(p);
            f = f * f * (3.0 - 2.0 * f);
            float a = hash21(i);
            float b = hash21(i + vec2(1.0, 0.0));
            float c = hash21(i + vec2(0.0, 1.0));
            float d = hash21(i + vec2(1.0, 1.0));
            return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
        }

        float cloudFbm(vec2 p) {
            float v = 0.0;
            float a = 0.5;
            for (int i = 0; i < 4; i++) {
                v += a * noise2D(p);
                p = p * 2.06 + vec2(13.7, 9.2);
                a *= 0.49;
            }
            return v;
        }

        #pragma body
        vec3 rayDir = normalize(-_surface.view);
        vec3 upV = normalize(upDirView);
        vec3 sunV = normalize(sunDirView);

        float elev = dot(rayDir, upV);
        float sunElev = dot(sunV, upV);
        float dayFactor = smoothstep(-0.22, 0.18, sunElev);
        float tw = (sunElev + 0.02) * 5.0;
        float twilight = exp(-(tw * tw));
        float horizonFactor = pow(clamp(1.0 - max(0.0, elev), 0.0001, 1.0), 2.6);
        float sunGlow = pow(max(0.0001, dot(rayDir, sunV)), 12.0) * 0.65;

        vec3 sky = mix(zenithCol, horizonCol, horizonFactor);
        sky = mix(sky, sunsetCol, twilight * (0.45 + 0.55 * horizonFactor));
        sky += mix(horizonCol, sunsetCol, twilight) * sunGlow * (0.35 + 0.65 * dayFactor);

        float cloudAlphaBoost = 0.0;
        if (elev > 0.01 && cloudAmount > 0.01) {
            vec3 eastV = normalize(eastDirView);
            vec3 northV = normalize(cross(upV, eastV));
            vec2 cUV = vec2(dot(rayDir, eastV), dot(rayDir, northV)) / (elev + 0.16);
            float c1 = cloudFbm(cUV * 1.1 + vec2(u_time * 0.012, u_time * 0.006));
            float c2 = cloudFbm(cUV * 2.6 - vec2(u_time * 0.018, -u_time * 0.010));
            float cVal = c1 * 0.68 + c2 * 0.32;
            float cMask = smoothstep(0.52 - cloudAmount * 0.16, 0.78, cVal) * smoothstep(0.01, 0.22, elev) * cloudAmount;

            vec3 cloudLit = mix(vec3(0.95, 0.97, 1.0), sunsetCol * 1.15, twilight * 0.70);
            vec3 cloudShadow = mix(horizonCol * 0.62, vec3(0.42, 0.46, 0.56), 0.5);
            vec3 cloudCol = mix(cloudShadow, cloudLit, smoothstep(0.35, 0.78, c1));
            sky = mix(sky, cloudCol, cMask * 0.88);
            cloudAlphaBoost = cMask * 0.45;
        }

        float belowMask = smoothstep(-0.28, -0.02, elev);
        float alpha = clamp((atmoDensity * (0.15 + 0.85 * dayFactor) * (0.45 + 0.55 * horizonFactor) + cloudAlphaBoost * atmoDensity) * belowMask, 0.0, 0.96);

        _output.color = vec4(sky * (0.12 + 0.88 * dayFactor), alpha);
        """
    }
}
