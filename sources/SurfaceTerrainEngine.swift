import Foundation
import SceneKit
import UIKit
import simd

struct TerrainSample {
    let heightMeters: Double
    let color: SIMD3<Float>
    let isWater: Bool
}

final class SurfaceTerrainEngine {

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

    // MARK: - Unified Planetary Terrain Sampler

    static func sampleTerrain(localDir: SIMD3<Double>, body: CelestialBody) -> TerrainSample {
        let dir = simd_length_squared(localDir) > 1e-12 ? simd_normalize(localDir) : SIMD3<Double>(0, 1, 0)
        let lat = abs(dir.y)

        switch body.id {
        case "earth":
            let n = fbm3D(dir * 3.6, octaves: 4)
            let warp = fbm3D(dir * 2.2 + SIMD3<Double>(4.1, 1.7, 8.3), octaves: 3) * 0.25
            let elev = n + warp - 0.12
            let detail = fbm3D(dir * 18.0, octaves: 3)

            if lat + detail * 0.10 > 0.84 {
                let iceHeight = 60.0 + detail * 480.0
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
            let height = landFrac * 1_200.0 + ridges * mountainMask * 4_400.0 + hills * 480.0

            let sand = SIMD3<Float>(0.48, 0.42, 0.28)
            let forest = SIMD3<Float>(0.04, 0.16, 0.05)
            let meadow = SIMD3<Float>(0.17, 0.24, 0.09)
            let aridHighland = SIMD3<Float>(0.38, 0.30, 0.19)
            let rock = SIMD3<Float>(0.22, 0.21, 0.20)
            let snow = SIMD3<Float>(0.76, 0.80, 0.85)

            let arid = smoothstep(0.06, 0.30, abs(lat - 0.26)) * smoothstep(0.18, 0.78, detail)
            var col = mix(aridHighland, mix(meadow, forest, detail), arid)
            col = mix(sand, col, smoothstep(8.0, 60.0, height))
            col = mix(col, rock, smoothstep(1_150.0, 2_200.0, height))
            col = mix(col, snow, smoothstep(2_800.0, 3_900.0, height + lat * 680.0))

            return TerrainSample(heightMeters: height, color: col, isWater: false)

        case "mars":
            let base = fbm3D(dir * 3.8, octaves: 4)
            let ridges = ridgedFbm3D(dir * 19.0, octaves: 4)
            let micro = fbm3D(dir * 110.0, octaves: 3)
            let craters = craterField3D(dir * 34.0)
            let height = (base - 0.48) * 3_800.0 + ridges * 3_200.0 + craters * 950.0 + (micro - 0.45) * 420.0

            let darkBasalt = SIMD3<Float>(0.18, 0.07, 0.04)
            let terracotta = SIMD3<Float>(0.44, 0.18, 0.09)
            let ochre = SIMD3<Float>(0.58, 0.31, 0.16)
            var col = mix(darkBasalt, terracotta, smoothstep(-700.0, 1_500.0, height))
            col = mix(col, ochre, smoothstep(1_200.0, 4_200.0, height + ridges * 700.0))
            if lat + micro * 0.09 > 0.86 {
                col = SIMD3<Float>(0.78, 0.76, 0.74)
            }
            return TerrainSample(heightMeters: height, color: col, isWater: false)

        case "moon", "mercury":
            let maria = fbm3D(dir * 3.2, octaves: 4)
            let rough = fbm3D(dir * 26.0, octaves: 3)
            let largeCraters = craterField3D(dir * 16.0)
            let smallCraters = craterField3D(dir * 52.0)
            let height = (maria - 0.48) * 2_400.0 + (rough - 0.45) * 850.0 + largeCraters * 2_200.0 + smallCraters * 650.0

            let isMercury = (body.id == "mercury")
            let darkFloor = isMercury ? SIMD3<Float>(0.12, 0.11, 0.10) : SIMD3<Float>(0.11, 0.115, 0.125)
            let midRegolith = isMercury ? SIMD3<Float>(0.26, 0.24, 0.22) : SIMD3<Float>(0.24, 0.245, 0.255)
            let brightEjecta = isMercury ? SIMD3<Float>(0.42, 0.39, 0.36) : SIMD3<Float>(0.44, 0.445, 0.46)

            var col = mix(darkFloor, midRegolith, smoothstep(-1_200.0, 1_400.0, height))
            let rimHighlight = max(0.0, largeCraters + smallCraters * 0.5)
            col = mix(col, brightEjecta, smoothstep(0.05, 0.42, rimHighlight + (rough - 0.45) * 0.35))
            return TerrainSample(heightMeters: height, color: col, isWater: false)

        case "venus":
            let plains = fbm3D(dir * 4.2, octaves: 4)
            let volcanic = ridgedFbm3D(dir * 22.0, octaves: 4)
            let detail = fbm3D(dir * 95.0, octaves: 3)
            let height = (plains - 0.48) * 2_800.0 + volcanic * 2_800.0 + (detail - 0.45) * 380.0

            let basalt = SIMD3<Float>(0.16, 0.10, 0.06)
            let sulfur = SIMD3<Float>(0.42, 0.30, 0.14)
            let peak = SIMD3<Float>(0.56, 0.42, 0.22)
            var col = mix(basalt, sulfur, smoothstep(-400.0, 1_600.0, height))
            col = mix(col, peak, smoothstep(1_800.0, 3_900.0, height))
            return TerrainSample(heightMeters: height, color: col, isWater: false)

        default:
            let base = fbm3D(dir * 5.0, octaves: 4)
            let height = (base - 0.48) * 2_500.0
            let col = SIMD3<Float>(
                Float((body.colorHex >> 16) & 0xFF) / 255.0 * 0.55,
                Float((body.colorHex >> 8) & 0xFF) / 255.0 * 0.55,
                Float(body.colorHex & 0xFF) / 255.0 * 0.55
            )
            return TerrainSample(heightMeters: height, color: col, isWater: false)
        }
    }

    // MARK: - Scenic Approach Direction (Low-Angle Sunlight + Mountainous Land on Earth)

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

        guard body.id == "earth" else {
            return defaultDir
        }

        var fallbackLandDir: SIMD3<Double>?
        var fallbackMaxHeight = -Double.greatestFiniteMagnitude

        for i in 0..<24 {
            let az = Double(i) * (.pi / 12.0)
            let candidate = simd_normalize(toSun * 0.46 + (right * cos(az) + up * sin(az)) * 0.88)
            let sample = sampleTerrain(localDir: invPlanetRot.act(candidate), body: body)
            if !sample.isWater {
                if sample.heightMeters > 250.0 && sample.heightMeters < 2_200.0 {
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
        invPlanetRot: simd_quatd,
        altitudeMeters: Double,
        whitePixel: UIImage,
        compress: (SIMD3<Double>) -> (pos: SIMD3<Float>, scaleFactor: Double)
    ) -> (terrain: SCNGeometry, ocean: SCNGeometry?) {
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

        let gridN = 73
        let vertexCount = gridN * gridN
        let horizonDist = sqrt(max(1.0, 2.0 * body.radiusMeters * max(50.0, altitudeMeters)))
        let patchHalfExtent = min(body.radiusMeters * 0.36, max(22_000.0, horizonDist * 1.05))

        var positionsSIMD = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        var colorFloats = [Float](repeating: 0.5, count: vertexCount * 3)
        var uvs = [CGPoint](repeating: .zero, count: vertexCount)

        for iz in 0..<gridN {
            let tz = (Double(iz) / Double(gridN - 1)) * 2.0 - 1.0
            let v = (tz >= 0 ? 1.0 : -1.0) * (0.12 * abs(tz) + 0.88 * tz * tz)

            for ix in 0..<gridN {
                let tx = (Double(ix) / Double(gridN - 1)) * 2.0 - 1.0
                let u = (tx >= 0 ? 1.0 : -1.0) * (0.12 * abs(tx) + 0.88 * tx * tx)

                let offset = east * (u * patchHalfExtent) + north * (v * patchHalfExtent)
                let dirWorld = simd_normalize(upWorld * body.radiusMeters + offset)
                let localDir = invPlanetRot.act(dirWorld)
                let sample = sampleTerrain(localDir: localDir, body: body)

                let rawHeight = sample.isWater ? (sample.heightMeters - 28.0) : sample.heightMeters
                let vertexHeight = (body.id == "earth") ? max(-120.0, rawHeight) : sample.heightMeters
                let ptWorld = bodyPos + dirWorld * (body.radiusMeters + vertexHeight)
                let (scenePos, _) = compress(ptWorld - anchorWorld)

                let idx = iz * gridN + ix
                positionsSIMD[idx] = scenePos
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

        let terrainMat = SCNMaterial()
        terrainMat.lightingModel = .physicallyBased
        terrainMat.diffuse.contents = whitePixel
        terrainMat.roughness.contents = 0.92
        terrainMat.metalness.contents = 0.02
        terrainMat.shaderModifiers = [.surface: terrainShaderModifier(for: body)]

        let terrainGeo = SCNGeometry(sources: [posSource, normSource, texcoordSource, colorSource], elements: [element])
        terrainGeo.materials = [terrainMat]

        var oceanGeo: SCNGeometry? = nil
        if body.id == "earth" {
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

        return (terrainGeo, oceanGeo)
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
        let oceanN = 29
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
        oceanMat.roughness.contents = 0.14
        oceanMat.metalness.contents = 0.22
        oceanMat.writesToDepthBuffer = true
        oceanMat.shaderModifiers = [.surface: """
        #pragma body
        vec2 uv = _surface.diffuseTexcoord;
        float w1 = sin(uv.x * 48.0 + u_time * 1.4) * cos(uv.y * 42.0 - u_time * 1.1);
        float w2 = sin((uv.x + uv.y) * 95.0 - u_time * 2.1);
        float wave = w1 * 0.6 + w2 * 0.4;
        vec3 dN = vec3(dFdx(wave), dFdy(wave), 0.0);
        _surface.normal = normalize(_surface.normal - dN * 1.8);
        _surface.diffuse = vec4(0.015, 0.11, 0.28, 0.96);
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
        switch body.id {
        case "earth": mode = 1
        case "mars": mode = 2
        case "venus": mode = 3
        default: mode = 4
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
        vec2 km = _surface.diffuseTexcoord;
        vec3 baseCol = _surface.diffuse.rgb;
        vec3 col = baseCol;
        float rough = 0.90;
        float microH = 0.0;
        float bumpStrength = 20.0;

        int tMode = \(mode);
        if (tMode == 1) {
            float macro = fbm2D(km * 0.18);
            float ridge = ridged2D(km * 0.75);
            float micro = fbm2D(km * 6.5);
            float fine = noise2D(km * 35.0);

            float cliff = smoothstep(0.45, 0.82, ridge);
            col = mix(baseCol * (0.72 + 0.55 * macro), vec3(0.24, 0.22, 0.20), cliff * 0.45);
            col *= (0.82 + 0.34 * micro + 0.12 * (fine - 0.5));

            float cloudSh = smoothstep(0.56, 0.76, fbm2D(km * 0.06 + vec2(u_time * 0.01, 0.0)));
            col *= (1.0 - cloudSh * 0.32);

            microH = ridge * 0.55 + micro * 0.30 + fine * 0.15;
            bumpStrength = 20.0;
            rough = mix(0.88, 0.74, cliff);
        } else if (tMode == 2) {
            float cr = crater2D(km * 0.35);
            float ridge = ridged2D(km * 0.65);
            float dunes = sin(km.x * 12.0 + fbm2D(km * 2.0) * 6.0) * 0.5 + 0.5;
            float micro = fbm2D(km * 9.0);

            col = baseCol * (0.74 + 0.42 * micro + 0.18 * dunes);
            col = mix(col, vec3(0.22, 0.09, 0.05), clamp(-cr, 0.0, 0.6) * 0.55);
            col = mix(col, vec3(0.62, 0.34, 0.18), smoothstep(0.08, 0.38, cr) * 0.45);

            microH = cr * 0.40 + ridge * 0.35 + dunes * 0.10 + micro * 0.15;
            bumpStrength = 24.0;
            rough = 0.92;
        } else if (tMode == 3) {
            float ridge = ridged2D(km * 0.80);
            float frac = ridged2D(km * 3.2);
            float micro = fbm2D(km * 11.0);

            col = baseCol * (0.76 + 0.40 * micro);
            col = mix(col, vec3(0.14, 0.08, 0.04), smoothstep(0.55, 0.90, frac) * 0.5);

            microH = ridge * 0.50 + frac * 0.30 + micro * 0.20;
            bumpStrength = 22.0;
            rough = 0.86;
        } else {
            float cBig = crater2D(km * 0.12);
            float cMed = crater2D(km * 0.55);
            float cSmall = crater2D(km * 2.8);
            float grit = fbm2D(km * 14.0);

            float cSum = cBig * 0.55 + cMed * 0.35 + cSmall * 0.20;
            col = baseCol * (0.78 + 0.45 * grit);
            col *= (1.0 - clamp(-cSum, 0.0, 0.65) * 0.55);
            col += vec3(0.12, 0.12, 0.13) * smoothstep(0.05, 0.35, cSum);

            microH = cBig * 0.50 + cMed * 0.30 + cSmall * 0.14 + grit * 0.08;
            bumpStrength = 28.0;
            rough = 0.95;
        }

        vec3 dN = vec3(dFdx(microH), dFdy(microH), 0.0);
        _surface.normal = normalize(_surface.normal - dN * bumpStrength);
        _surface.diffuse = vec4(col, 1.0);
        _surface.roughness = rough;
        """
    }

    // MARK: - Interior Atmospheric Sky Dome GLSL Shader

    static func skyDomeShaderModifier() -> String {
        return """
        uniform vec3 sunDirView;
        uniform vec3 upDirView;
        uniform vec3 zenithCol;
        uniform vec3 horizonCol;
        uniform vec3 sunsetCol;
        uniform float atmoDensity;

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

        float belowMask = smoothstep(-0.28, -0.02, elev);
        float alpha = clamp(atmoDensity * (0.15 + 0.85 * dayFactor) * (0.45 + 0.55 * horizonFactor) * belowMask, 0.0, 0.96);

        _output.color = vec4(sky * (0.12 + 0.88 * dayFactor), alpha);
        """
    }
}
