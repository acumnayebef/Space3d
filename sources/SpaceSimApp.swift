import SwiftUI
import SceneKit
import simd

@main
struct SpaceSimApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea()
                .statusBarHidden(true)
        }
    }
}

struct BodyScreenMarker: Identifiable {
    let id: String
    let name: String
    let x: CGFloat
    let y: CGFloat
    let color: Color
    let isTarget: Bool
    let isStar: Bool
}

final class SpaceSimulationController: ObservableObject {
    let scene = SCNScene()
    let shipNode = SCNNode()
    let shipVisualNode = SCNNode()
    let thirdPersonMeshNode = SCNNode()
    let landingGearNode = SCNNode()
    let parkedShipNode = SCNNode()
    let cockpitMeshNode = SCNNode()
    let cockpitStickPivot = SCNNode()
    let cockpitThrottlePivot = SCNNode()
    let cameraBoomNode = SCNNode()
    let cameraNode = SCNNode()
    let sunLightNode = SCNNode()
    let dustRootNode = SCNNode()
    let orbitLinesNode = SCNNode()
    let terrainRootNode = SCNNode()
    let terrainMeshNode = SCNNode()
    let oceanMeshNode = SCNNode()
    let surfacePropsNode = SCNNode()
    let skyDomeNode = SCNNode()
    let ambientLightNode = SCNNode()

    var exhaustNodes: [SCNNode] = []
    var dustParticles: [(node: SCNNode, offset: SIMD3<Float>)] = []

    var shipPositionMeters = SIMD3<Double>(-UniverseCatalog.au + 10_200_000, 2_800_000, 11_400_000)
    var shipVelocityMetersPerSec = SIMD3<Double>(0, 0, 0)
    var shipOrientation = simd_quatd(angle: 0.68, axis: simd_normalize(SIMD3<Double>(-0.18, 1.0, 0.0)))

    var angularVelYaw: Double = 0
    var angularVelPitch: Double = 0
    var stickInput: CGPoint = .zero

    var orbitYaw: Float = 0.0
    var orbitPitch: Float = -0.16
    var orbitDistance: Float = 13.5
    var cameraLagYaw: Float = 0.0
    var cameraLagPitch: Float = 0.0

    let baseEpochDate = Date()
    var simulationTimeSeconds: Double = 0.0

    @Published var speedIndex: Int = 0
    @Published var timeWarpIndex: Int = 0
    @Published var isTimePaused: Bool = false
    @Published var isTimeReversed: Bool = false
    @Published var showOrbits: Bool = true
    @Published var showMarkers: Bool = true
    @Published var isFreeCamera: Bool = false
    @Published var autoSpeed: Bool = false
    @Published var throttle: Double = 0.0
    @Published var flightAssist: Bool = true
    @Published var targetBody: CelestialBody = UniverseCatalog.bodies[3] {
        didSet { canLandOnTarget = targetBody.isLandable }
    }
    @Published var distanceText: String = "10.2 тыс. км"
    @Published var speedText: String = "0 м/с"
    @Published var autoSpeedLabel: String = "АВТО"
    @Published var etaText: String = "Стоп"
    @Published var simDateText: String = ""
    @Published var screenMarkers: [BodyScreenMarker] = []
    @Published var isThirdPerson: Bool = true
    @Published var isLanded: Bool = false
    @Published var isNearSurface: Bool = false
    @Published var surfaceAltitudeText: String = ""
    @Published var atmosphereZoneText: String = ""
    @Published var reentryHeat: Double = 0.0
    @Published var canLandOnTarget: Bool = true
    @Published var isWalkingOnSurface: Bool = false
    @Published var isOverWater: Bool = false
    @Published var canAutoLand: Bool = false
    @Published var evaSprinting: Bool = false
    @Published var evaJetpackActive: Bool = false
    @Published var evaJetpackFuel: Double = 1.0
    @Published var evaShipDistanceText: String = "7 м"
    @Published var evaTempText: String = "15 °C"
    @Published var evaScannerOpen: Bool = false
    @Published var evaScanReport: SurfaceScanReport? = nil

    let speedSteps: [(label: String, mps: Double)] = [
        ("1.5 км/с", 1_500),
        ("7.9 км/с (Орбита)", 7_900),
        ("11.2 км/с (2-я косм.)", 11_200),
        ("100 км/с", 100_000),
        ("10 000 км/с", 10_000_000),
        ("1 c", 299_792_458),
        ("100 c", 29_979_245_800),
        ("10 000 c", 2_997_924_580_000),
        ("500 000 c", 149_896_229_000_000),
        ("10 млн c", 2_997_924_580_000_000),
        ("1 млрд c", 299_792_458_000_000_000)
    ]

    let timeWarpSteps: [(label: String, mult: Double)] = [
        ("1x", 1),
        ("10x", 10),
        ("100x", 100),
        ("1 000x", 1_000),
        ("10 000x", 10_000),
        ("100 000x", 100_000),
        ("1 млн x", 1_000_000)
    ]

    private var bodyNodes: [String: SCNNode] = [:]
    private var planetMeshNodes: [String: SCNNode] = [:]
    private var planetMaterials: [String: SCNMaterial] = [:]
    private var atmoMaterials: [String: SCNMaterial] = [:]
    private var atmoNodes: [String: SCNNode] = [:]
    private var skyDomeMaterial: SCNMaterial?
    private var lastUpdateTime: TimeInterval = 0
    private var frameCounter: Int = 0

    private var activeSurfaceBodyId: String?
    private var lastTerrainAnchorLocal: SIMD3<Double> = .zero
    private var lastTerrainBuildPlanetRot: simd_quatd = simd_quatd(angle: 0, axis: SIMD3<Double>(0, 1, 0))
    private var lastTerrainAltitude: Double = -1
    private var lastTrackedBodyId: String?
    private var lastTrackedBodyPos: SIMD3<Double> = .zero
    private var lastTrackedSpinAngle: Double = 0
    private var currentGroundHeightMeters: Double = 0
    private var landedState: Bool = false
    private var walkingState: Bool = false
    private var evaPitch: Double = -0.05
    private var evaYaw: Double = 0.0
    private var evaVerticalVel: Double = 0.0
    private var evaHeightAboveGround: Double = 1.85
    private var evaWalkPhase: Double = 0.0
    private var evaRefForwardLocal: SIMD3<Double> = SIMD3<Double>(0, 0, -1)
    private var jetpackFuelState: Double = 1.0
    private var hasPropsForCurrentAnchor: Bool = false
    private var activeTerrainCollision: SurfaceTerrainEngine.TerrainCollisionGrid? = nil
    private var parkedShipBodyId: String?
    private var parkedShipLocalPos: SIMD3<Double> = .zero
    private var parkedShipLocalOrient: simd_quatd = simd_quatd(angle: 0, axis: SIMD3<Double>(0, 1, 0))

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "dd.MM.yyyy HH:mm"
        return df
    }()

    private lazy var whitePixel: UIImage = {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        return r.image { ctx in
            ctx.cgContext.setFillColor(UIColor.white.cgColor)
            ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }()

    private lazy var orbitLineMaterial: SCNMaterial = {
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor(red: 0.25, green: 0.72, blue: 1.0, alpha: 0.42)
        mat.blendMode = .add
        mat.writesToDepthBuffer = false
        return mat
    }()

    init() {
        simDateText = Self.dateFormatter.string(from: baseEpochDate)
        setupScene()
    }

    private func setupScene() {
        scene.background.contents = generateStarCubemap()

        let sunLight = SCNLight()
        sunLight.type = .directional
        sunLight.intensity = 1750
        sunLight.color = UIColor(red: 1.0, green: 0.98, blue: 0.95, alpha: 1.0)
        sunLightNode.light = sunLight
        scene.rootNode.addChildNode(sunLightNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 22
        ambient.color = UIColor(red: 0.12, green: 0.18, blue: 0.30, alpha: 1.0)
        ambientLightNode.light = ambient
        scene.rootNode.addChildNode(ambientLightNode)

        terrainRootNode.addChildNode(terrainMeshNode)
        terrainRootNode.addChildNode(oceanMeshNode)
        terrainRootNode.addChildNode(surfacePropsNode)
        terrainRootNode.isHidden = true
        scene.rootNode.addChildNode(terrainRootNode)

        let skySphere = SCNSphere(radius: 800.0)
        skySphere.segmentCount = 48
        let skyMat = SCNMaterial()
        skyMat.lightingModel = .constant
        skyMat.cullMode = .front
        skyMat.writesToDepthBuffer = false
        skyMat.readsFromDepthBuffer = false
        skyMat.blendMode = .alpha
        skyMat.shaderModifiers = [.fragment: SurfaceTerrainEngine.skyDomeShaderModifier()]
        skyMat.setValue(NSValue(scnVector3: SCNVector3(0, 1, 0)), forKey: "sunDirView")
        skyMat.setValue(NSValue(scnVector3: SCNVector3(0, 1, 0)), forKey: "upDirView")
        skyMat.setValue(NSValue(scnVector3: SCNVector3(1, 0, 0)), forKey: "eastDirView")
        skyMat.setValue(NSValue(scnVector3: SCNVector3(0.08, 0.28, 0.78)), forKey: "zenithCol")
        skyMat.setValue(NSValue(scnVector3: SCNVector3(0.48, 0.76, 1.00)), forKey: "horizonCol")
        skyMat.setValue(NSValue(scnVector3: SCNVector3(1.00, 0.42, 0.14)), forKey: "sunsetCol")
        skyMat.setValue(NSNumber(value: Float(0.0)), forKey: "atmoDensity")
        skyMat.setValue(NSNumber(value: Float(0.0)), forKey: "cloudAmount")
        skySphere.materials = [skyMat]
        skyDomeMaterial = skyMat
        skyDomeNode.geometry = skySphere
        skyDomeNode.renderingOrder = -50
        skyDomeNode.isHidden = true
        scene.rootNode.addChildNode(skyDomeNode)

        buildThirdPersonShip()
        buildFirstPersonCockpit()
        shipVisualNode.addChildNode(thirdPersonMeshNode)
        shipVisualNode.addChildNode(cockpitMeshNode)
        shipNode.addChildNode(shipVisualNode)
        scene.rootNode.addChildNode(shipNode)

        parkedShipNode.isHidden = true
        scene.rootNode.addChildNode(parkedShipNode)

        shipNode.addChildNode(cameraBoomNode)
        let cam = SCNCamera()
        cam.zNear = 0.08
        cam.zFar = 1_500_000
        cam.fieldOfView = 62
        cameraNode.camera = cam
        cameraBoomNode.addChildNode(cameraNode)
        updateCameraMode()

        scene.rootNode.addChildNode(orbitLinesNode)
        buildSpaceDust()
        buildCelestialBodies()
    }

    private func buildSpaceDust() {
        scene.rootNode.addChildNode(dustRootNode)
        let dot = SCNSphere(radius: 0.055)
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor(white: 0.85, alpha: 0.55)
        dot.materials = [mat]

        var rng: UInt64 = 0x55AA33CC11229988
        func rand() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(rng >> 33) / Float(1 << 31)
        }

        for _ in 0..<110 {
            let n = SCNNode(geometry: dot)
            let p = SIMD3<Float>((rand() - 0.5) * 90, (rand() - 0.5) * 90, (rand() - 0.5) * 90)
            n.simdPosition = p
            dustRootNode.addChildNode(n)
            dustParticles.append((n, p))
        }
    }

    private func buildCelestialBodies() {
        for body in UniverseCatalog.bodies {
            let root = SCNNode()
            root.eulerAngles.z = Float(body.axialTiltRad)

            let sphere = SCNSphere(radius: body.isGalaxy ? 0.20 : 1.0)
            sphere.segmentCount = body.isGalaxy ? 32 : ((body.category == .solar || body.id == "moon") ? 120 : 64)

            let mat = SCNMaterial()
            mat.diffuse.contents = whitePixel

            if body.isBlackHole {
                mat.lightingModel = .constant
                mat.diffuse.contents = UIColor.black
                let ringTint = (body.id == "cygnus_x1") ? "vec3(0.55, 0.85, 1.0)" : "vec3(1.0, 0.72, 0.35)"
                mat.shaderModifiers = [.fragment: """
                    float ndotv = clamp(abs(dot(normalize(_surface.normal), normalize(_surface.view))), 0.0, 1.0);
                    float photonRing = pow(max(0.0001, 1.0 - ndotv), 9.0) * 3.0;
                    _output.color = vec4(\(ringTint) * photonRing, 1.0);
                """]
            } else if body.isGalaxy {
                mat.lightingModel = .constant
                let c = rgbComponents(body.colorHex)
                mat.diffuse.contents = UIColor.clear
                mat.emission.contents = UIColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1.0)
                mat.shaderModifiers = [.fragment: """
                    float ndotv = clamp(abs(dot(normalize(_surface.normal), normalize(_surface.view))), 0.0, 1.0);
                    float core = pow(max(0.0001, ndotv), 1.8) * 1.35;
                    _output.color = vec4(vec3(\(c.r), \(c.g), \(c.b)) * core, core);
                """]
                mat.blendMode = .add
                mat.writesToDepthBuffer = false

                let diskSize: CGFloat = (body.id == "ic1101") ? 3.2 : 2.6
                let diskPlane = SCNPlane(width: diskSize, height: diskSize)
                let diskMat = SCNMaterial()
                diskMat.lightingModel = .constant
                diskMat.diffuse.contents = generateGalaxyImage(for: body)
                diskMat.isDoubleSided = true
                diskMat.writesToDepthBuffer = false
                diskMat.blendMode = .add
                diskPlane.materials = [diskMat]
                let diskNode = SCNNode(geometry: diskPlane)
                diskNode.eulerAngles.x = -.pi / 2.0
                root.addChildNode(diskNode)
            } else if body.isStar {
                mat.lightingModel = .constant
                mat.shaderModifiers = [.surface: starShaderModifier(for: body)]

                let corona = SCNSphere(radius: 1.28)
                corona.segmentCount = 48
                let cMat = SCNMaterial()
                cMat.lightingModel = .constant
                cMat.blendMode = .add
                cMat.cullMode = .front
                cMat.writesToDepthBuffer = false
                let c = rgbComponents(body.colorHex)
                cMat.shaderModifiers = [.fragment: """
                    float ndotv = clamp(abs(dot(normalize(_surface.normal), normalize(_surface.view))), 0.0, 1.0);
                    float glow = pow(max(0.0001, ndotv), 3.8) * 0.85;
                    _output.color = vec4(vec3(\(c.r), \(c.g), \(c.b)) * glow, glow);
                """]
                corona.materials = [cMat]
                root.addChildNode(SCNNode(geometry: corona))
            } else {
                mat.lightingModel = .physicallyBased
                mat.roughness.contents = body.isHabitableWorld ? 0.42 : (body.isIcyWorld ? 0.45 : 0.88)
                mat.metalness.contents = 0.02
                mat.shaderModifiers = [.surface: planetShaderModifier(for: body)]
                mat.setValue(NSValue(scnVector3: SCNVector3(1, 0, 0)), forKey: "sunDirLocal")
                planetMaterials[body.id] = mat
            }

            sphere.materials = [mat]
            let meshNode = SCNNode(geometry: sphere)
            root.addChildNode(meshNode)
            planetMeshNodes[body.id] = meshNode

            if body.hasAtmosphere && !body.isStar && !body.isBlackHole && !body.isGalaxy {
                let atmoSphere = SCNSphere(radius: 1.055)
                atmoSphere.segmentCount = 64
                let atmoMat = SCNMaterial()
                atmoMat.lightingModel = .constant
                atmoMat.blendMode = .add
                atmoMat.cullMode = .front
                atmoMat.writesToDepthBuffer = false

                let pal = body.atmospherePalette
                let dayCol = "vec3(\(pal.horizon.x), \(pal.horizon.y), \(pal.horizon.z))"
                let sunsetCol = "vec3(\(pal.sunset.x), \(pal.sunset.y), \(pal.sunset.z))"

                atmoMat.shaderModifiers = [.fragment: """
                    uniform vec3 sunDirView;
                    #pragma body
                    vec3 n = normalize(-_surface.normal);
                    vec3 v = normalize(_surface.view);
                    float ndotv = clamp(dot(n, v), 0.0, 1.0);
                    float halo = pow(max(0.0001, ndotv), 3.2) * smoothstep(0.0, 0.35, 1.0 - ndotv);
                    float sunDot = dot(n, normalize(sunDirView));
                    float dayMask = smoothstep(-0.25, 0.32, sunDot);
                    float tw = (sunDot + 0.04) * 4.5;
                    float sunset = exp(-(tw * tw));
                    vec3 col = mix(\(dayCol), \(sunsetCol), sunset * 0.65);
                    _output.color = vec4(col * halo * dayMask * 2.2, halo * dayMask);
                """]
                atmoMat.setValue(NSValue(scnVector3: SCNVector3(1, 0, 0)), forKey: "sunDirView")
                atmoMaterials[body.id] = atmoMat
                atmoSphere.materials = [atmoMat]
                let atmoNode = SCNNode(geometry: atmoSphere)
                root.addChildNode(atmoNode)
                atmoNodes[body.id] = atmoNode
            }

            if body.hasRings {
                let isBH = body.isBlackHole
                let isUranus = (body.id == "uranus")
                let planeSize: CGFloat = isBH ? 7.6 : (isUranus ? 3.8 : 5.2)
                let ringPlane = SCNPlane(width: planeSize, height: planeSize)
                let ringMat = SCNMaterial()
                ringMat.lightingModel = .constant
                ringMat.diffuse.contents = generateDetailedRingImage(isBlackHole: isBH, isUranus: isUranus)
                ringMat.isDoubleSided = true
                ringMat.writesToDepthBuffer = false
                ringMat.blendMode = isBH ? .add : .alpha

                ringPlane.materials = [ringMat]
                let ringNode = SCNNode(geometry: ringPlane)
                ringNode.eulerAngles = SCNVector3(-Float.pi / 2.0 + (isBH ? 0.22 : 0.0), 0.0, 0.0)
                if isBH {
                    ringNode.runAction(.repeatForever(.rotateBy(x: 0, y: 0, z: .pi * 2, duration: 14.0)))
                }
                root.addChildNode(ringNode)
            }

            scene.rootNode.addChildNode(root)
            bodyNodes[body.id] = root
        }
    }

    private func generateGalaxyImage(for body: CelestialBody) -> UIImage {
        let size = 512
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)

        let cCore = uiColor(from: body.colorHex)
        let cArm = uiColor(from: body.secondaryHex)
        let isElliptical = (body.id == "ic1101")

        return renderer.image { context in
            let ctx = context.cgContext
            ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
            let center = CGPoint(x: size / 2, y: size / 2)

            if let grad = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    cCore.withAlphaComponent(0.95).cgColor,
                    cArm.withAlphaComponent(0.35).cgColor,
                    UIColor.clear.cgColor
                ] as CFArray,
                locations: [0.0, 0.35, 1.0]
            ) {
                ctx.drawRadialGradient(
                    grad,
                    startCenter: center,
                    startRadius: 2,
                    endCenter: center,
                    endRadius: CGFloat(size) * 0.46,
                    options: []
                )
            }

            var rng: UInt64 = UInt64(bitPattern: Int64(body.id.hashValue)) ^ 0x9E3779B97F4A7C15
            func rand() -> Double {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                return Double(rng >> 33) / Double(1 << 31)
            }

            let arms = isElliptical ? 1 : 2
            let starCount = isElliptical ? 1400 : 2200
            for i in 0..<starCount {
                let rNorm = pow(rand(), 0.72)
                let radius = rNorm * Double(size) * 0.45
                let angle: Double
                if isElliptical {
                    angle = rand() * .pi * 2.0
                } else {
                    let armOffset = Double(i % arms) * (.pi * 2.0 / Double(arms))
                    let twist = rNorm * 4.8
                    let spread = (rand() - 0.5) * (0.45 + rNorm * 0.65)
                    angle = armOffset + twist + spread
                }
                let x = Double(center.x) + cos(angle) * radius
                let y = Double(center.y) + sin(angle) * radius * (isElliptical ? 0.78 : 1.0)
                let dotR = CGFloat(1.0 + rand() * 2.6)
                let alpha = CGFloat((1.0 - rNorm * 0.85) * (0.25 + rand() * 0.55))
                let col = (rNorm < 0.25) ? cCore : cArm
                ctx.setFillColor(col.withAlphaComponent(alpha).cgColor)
                ctx.fillEllipse(in: CGRect(x: x - Double(dotR) * 0.5, y: y - Double(dotR) * 0.5, width: Double(dotR), height: Double(dotR)))
            }
        }
    }

    private func compressToScene(_ relMeters: SIMD3<Double>) -> (pos: SIMD3<Float>, scaleFactor: Double) {
        let dist = simd_length(relMeters)
        let maxRenderDist = 420_000.0
        if dist <= maxRenderDist || dist < 1e-6 {
            return (SIMD3<Float>(Float(relMeters.x), Float(relMeters.y), Float(relMeters.z)), 1.0)
        }
        let compressedDist = maxRenderDist * (1.0 + 0.045 * log10(dist / maxRenderDist))
        let scaleFactor = compressedDist / dist
        let rPos = relMeters * scaleFactor
        return (SIMD3<Float>(Float(rPos.x), Float(rPos.y), Float(rPos.z)), scaleFactor)
    }

    private func updateOrbitLines() {
        orbitLinesNode.isHidden = !showOrbits
        guard showOrbits else { return }

        var vertices: [SCNVector3] = []
        var indices: [Int32] = []
        let segments = 72
        let maxSystemDist = 250.0 * UniverseCatalog.au

        for body in UniverseCatalog.bodies where body.semiMajorAxisMeters > 0 && body.orbitalPeriodSeconds > 0 {
            let parentPos: SIMD3<Double>
            if let pid = body.parentId, let parent = UniverseCatalog.bodies.first(where: { $0.id == pid }) {
                parentPos = parent.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
            } else {
                parentPos = .zero
            }

            if simd_length(parentPos - shipPositionMeters) > maxSystemDist {
                continue
            }

            let baseIndex = Int32(vertices.count)
            for s in 0..<segments {
                let angle = (Double(s) / Double(segments)) * 2.0 * .pi
                let ptWorld = body.orbitPoint(angle: angle, parentPos: parentPos)
                let (pos, _) = compressToScene(ptWorld - shipPositionMeters)
                vertices.append(SCNVector3(pos.x, pos.y, pos.z))

                let next = (s + 1) % segments
                indices.append(baseIndex + Int32(s))
                indices.append(baseIndex + Int32(next))
            }
        }

        if vertices.isEmpty {
            orbitLinesNode.geometry = nil
            return
        }

        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [orbitLineMaterial]
        orbitLinesNode.geometry = geometry
    }

    private func planetShaderModifier(for body: CelestialBody) -> String {
        let mode: Int
        if body.isHabitableWorld {
            mode = 1
        } else if body.id == "mars" || body.id == "trappist1d" {
            mode = 2
        } else if body.isGasGiant {
            mode = 3
        } else if body.isIcyWorld || body.id == "trappist1f" || body.id == "trappist1g" {
            mode = 5
        } else {
            mode = 4
        }

        let c1 = rgbComponents(body.colorHex)
        let c2 = rgbComponents(body.secondaryHex)
        let hasCities = (body.id == "earth") ? 1 : 0

        return """
        uniform vec3 sunDirLocal;

        float hash31(vec3 p) {
            p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
            p *= 17.0;
            return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
        }

        float noise3D(vec3 x) {
            vec3 i = floor(x);
            vec3 f = fract(x);
            f = f * f * (3.0 - 2.0 * f);
            float n000 = hash31(i + vec3(0.0, 0.0, 0.0));
            float n100 = hash31(i + vec3(1.0, 0.0, 0.0));
            float n010 = hash31(i + vec3(0.0, 1.0, 0.0));
            float n110 = hash31(i + vec3(1.0, 1.0, 0.0));
            float n001 = hash31(i + vec3(0.0, 0.0, 1.0));
            float n101 = hash31(i + vec3(1.0, 0.0, 1.0));
            float n011 = hash31(i + vec3(0.0, 1.0, 1.0));
            float n111 = hash31(i + vec3(1.0, 1.0, 1.0));
            float nx00 = mix(n000, n100, f.x);
            float nx10 = mix(n010, n110, f.x);
            float nx01 = mix(n001, n101, f.x);
            float nx11 = mix(n011, n111, f.x);
            return mix(mix(nx00, nx10, f.y), mix(nx01, nx11, f.y), f.z);
        }

        float fbm(vec3 p) {
            float v = 0.0;
            float a = 0.5;
            for (int i = 0; i < 6; i++) {
                v += a * noise3D(p);
                p = p * 2.07 + vec3(13.1, 7.4, 19.7);
                a *= 0.49;
            }
            return v;
        }

        #pragma body
        float phi = _surface.diffuseTexcoord.x * 6.2831853;
        float theta = _surface.diffuseTexcoord.y * 3.14159265;
        vec3 pos = vec3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi));

        float n = fbm(pos * 3.6);
        float detail = fbm(pos * 14.0);
        float ridge = 1.0 - abs(detail * 2.0 - 1.0);

        vec3 col1 = vec3(\(c1.r), \(c1.g), \(c1.b));
        vec3 col2 = vec3(\(c2.r), \(c2.g), \(c2.b));
        vec3 albedo = col1;
        vec3 emissive = vec3(0.0, 0.0, 0.0);
        float rough = 0.86;
        float bumpStrength = 0.0;

        float sunDot = dot(pos, normalize(sunDirLocal));
        float nightMask = smoothstep(0.06, -0.18, sunDot);

        int planetMode = \(mode);
        if (planetMode == 1) {
            float lat = abs(pos.y);
            float warp = fbm(pos * 2.2 + vec3(4.1, 1.7, 8.3)) * 0.25;
            float elev = n + warp - 0.12;

            if (lat + detail * 0.14 > 0.87) {
                albedo = vec3(0.95, 0.97, 1.0);
                rough = 0.55;
            } else if (elev < 0.50) {
                float depth = clamp(elev / 0.50, 0.0, 1.0);
                albedo = mix(vec3(0.008, 0.04, 0.18), vec3(0.03, 0.26, 0.56), pow(max(0.0001, depth), 2.2));
                rough = 0.14;
            } else {
                float h = clamp((elev - 0.50) / 0.42, 0.0, 1.0);
                vec3 forest = vec3(0.07, 0.24, 0.09);
                vec3 savanna = vec3(0.32, 0.36, 0.16);
                vec3 desert = vec3(0.64, 0.53, 0.35);
                vec3 rock = vec3(0.35, 0.33, 0.31);
                vec3 snow = vec3(0.94, 0.96, 0.98);

                float arid = smoothstep(0.08, 0.32, abs(lat - 0.27)) * smoothstep(0.2, 0.8, detail);
                vec3 lowCol = mix(desert, mix(savanna, forest, detail), arid);
                albedo = mix(lowCol, rock, smoothstep(0.32, 0.68, h + ridge * 0.18));
                albedo = mix(albedo, snow, smoothstep(0.76, 0.94, h + ridge * 0.22));
                rough = 0.92;
                bumpStrength = 10.0;

                if (\(hasCities) == 1 && h < 0.28 && lat < 0.68 && nightMask > 0.01) {
                    float cityCluster = fbm(pos * 24.0);
                    float lights = hash31(floor(pos * 260.0));
                    if (cityCluster > 0.54 && lights > 0.84) {
                        emissive = vec3(1.0, 0.74, 0.32) * (lights - 0.84) * 14.0 * nightMask;
                    }
                }
            }

            vec3 cWarp = vec3(sin(pos.y * 5.0) * 0.45 + u_time * 0.004, cos(pos.x * 5.0) * 0.25, 0.0);
            float cn = fbm(pos * 4.6 + cWarp + vec3(n * 0.9, -n * 0.5, n * 0.7));
            float cnShadow = fbm((pos + normalize(sunDirLocal) * 0.012) * 4.6 + cWarp + vec3(n * 0.9, -n * 0.5, n * 0.7));
            float clouds = smoothstep(0.51, 0.76, cn);
            float cShadow = smoothstep(0.51, 0.76, cnShadow) * (1.0 - clouds) * 0.45;
            albedo *= (1.0 - cShadow);
            albedo = mix(albedo, vec3(0.97, 0.98, 1.0), clouds * 0.92);
            emissive *= (1.0 - clouds * 0.85);
            rough = mix(rough, 0.94, clouds);
        } else if (planetMode == 2) {
            float lat = abs(pos.y);
            albedo = mix(col2, col1, smoothstep(0.24, 0.74, n));
            albedo = mix(albedo, vec3(0.84, 0.48, 0.28), ridge * 0.25);
            if (lat + detail * 0.12 > 0.88) albedo = vec3(0.95, 0.94, 0.92);
            bumpStrength = 14.0;
        } else if (planetMode == 3) {
            float turb = (n - 0.5) * 0.20 + (detail - 0.5) * 0.07;
            float yBand = (pos.y + turb) * 19.0;
            float stripe = sin(yBand) * 0.5 + 0.5;
            albedo = mix(col2, col1, smoothstep(0.15, 0.85, stripe));
            albedo *= (0.88 + detail * 0.24);
            rough = 0.62;
        } else if (planetMode == 5) {
            float crev = abs(detail * 2.0 - 1.0);
            albedo = mix(col2, col1, smoothstep(0.25, 0.78, n));
            albedo = mix(albedo, vec3(0.32, 0.54, 0.78), smoothstep(0.60, 0.94, 1.0 - crev) * 0.55);
            rough = 0.42;
            bumpStrength = 12.0;
        } else {
            float crater = smoothstep(0.32, 0.68, detail);
            albedo = mix(col2, col1, smoothstep(0.22, 0.78, n));
            albedo *= (0.68 + ridge * 0.35 + crater * 0.22);
            bumpStrength = 18.0;
        }

        if (planetMode == 1 || planetMode == 2) {
            float ndotv = clamp(abs(dot(normalize(_surface.normal), normalize(_surface.view))), 0.0, 1.0);
            float fresnel = pow(max(0.0001, 1.0 - ndotv), 3.2) * smoothstep(-0.15, 0.35, sunDot);
            vec3 hazeCol = (planetMode == 1) ? vec3(0.28, 0.62, 1.0) : vec3(0.92, 0.48, 0.25);
            emissive += hazeCol * fresnel * 0.48;
        }

        if (bumpStrength > 0.1) {
            vec3 dN = vec3(dFdx(detail), dFdy(detail), 0.0);
            _surface.normal = normalize(_surface.normal - dN * bumpStrength);
        }

        _surface.diffuse = vec4(albedo, 1.0);
        _surface.emission.rgb += emissive;
        _surface.roughness = rough;
        """
    }

    private func starShaderModifier(for body: CelestialBody) -> String {
        let c1 = rgbComponents(body.colorHex)
        let c2 = rgbComponents(body.secondaryHex)
        return """
        float hash31(vec3 p) {
            p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
            p *= 17.0;
            return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
        }

        float noise3D(vec3 x) {
            vec3 i = floor(x);
            vec3 f = fract(x);
            f = f * f * (3.0 - 2.0 * f);
            float n000 = hash31(i + vec3(0.0, 0.0, 0.0));
            float n100 = hash31(i + vec3(1.0, 0.0, 0.0));
            float n010 = hash31(i + vec3(0.0, 1.0, 0.0));
            float n110 = hash31(i + vec3(1.0, 1.0, 0.0));
            float n001 = hash31(i + vec3(0.0, 0.0, 1.0));
            float n101 = hash31(i + vec3(1.0, 0.0, 1.0));
            float n011 = hash31(i + vec3(0.0, 1.0, 1.0));
            float n111 = hash31(i + vec3(1.0, 1.0, 1.0));
            return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
                       mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
        }

        #pragma body
        float phi = _surface.diffuseTexcoord.x * 6.2831853;
        float theta = _surface.diffuseTexcoord.y * 3.14159265;
        vec3 pos = vec3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi));

        float g1 = noise3D(pos * 8.0 + vec3(u_time * 0.06, 0.0, 0.0));
        float g2 = noise3D(pos * 18.0 - vec3(0.0, u_time * 0.10, u_time * 0.05));
        float g3 = noise3D(pos * 38.0 + vec3(u_time * 0.14, 0.0, 0.0));
        float plasma = g1 * 0.50 + g2 * 0.32 + g3 * 0.18;

        float spots = smoothstep(0.22, 0.34, g1 * 0.7 + g2 * 0.3);
        float ndotv = clamp(abs(dot(normalize(_surface.normal), normalize(_surface.view))), 0.0, 1.0);
        float limb = 0.35 + 0.65 * pow(max(0.0001, ndotv), 0.55);

        vec3 hotCol = vec3(\(c1.r), \(c1.g), \(c1.b));
        vec3 coolCol = vec3(\(c2.r), \(c2.g), \(c2.b));
        vec3 starCol = mix(coolCol * 0.65, hotCol * 1.15, smoothstep(0.25, 0.85, plasma));
        starCol *= (0.35 + 0.65 * spots) * limb;

        _surface.diffuse = vec4(0.0, 0.0, 0.0, 1.0);
        _surface.emission = vec4(starCol, 1.0);
        """
    }

    private func buildThirdPersonShip() {
        let hullWhite = SCNMaterial()
        hullWhite.lightingModel = .physicallyBased
        hullWhite.diffuse.contents = UIColor(red: 0.84, green: 0.87, blue: 0.91, alpha: 1.0)
        hullWhite.metalness.contents = 0.55
        hullWhite.roughness.contents = 0.28

        let darkArmor = SCNMaterial()
        darkArmor.lightingModel = .physicallyBased
        darkArmor.diffuse.contents = UIColor(red: 0.14, green: 0.17, blue: 0.22, alpha: 1.0)
        darkArmor.metalness.contents = 0.82
        darkArmor.roughness.contents = 0.32

        let orangeTrim = SCNMaterial()
        orangeTrim.lightingModel = .physicallyBased
        orangeTrim.diffuse.contents = UIColor(red: 0.95, green: 0.42, blue: 0.10, alpha: 1.0)
        orangeTrim.metalness.contents = 0.15
        orangeTrim.roughness.contents = 0.35

        let canopyGlass = SCNMaterial()
        canopyGlass.lightingModel = .physicallyBased
        canopyGlass.diffuse.contents = UIColor(red: 0.08, green: 0.45, blue: 0.82, alpha: 0.92)
        canopyGlass.metalness.contents = 0.95
        canopyGlass.roughness.contents = 0.06

        let glowCyan = SCNMaterial()
        glowCyan.lightingModel = .constant
        glowCyan.diffuse.contents = UIColor(red: 0.12, green: 0.90, blue: 1.0, alpha: 1.0)

        let navRed = SCNMaterial()
        navRed.lightingModel = .constant
        navRed.diffuse.contents = UIColor(red: 1.0, green: 0.16, blue: 0.12, alpha: 1.0)

        let navGreen = SCNMaterial()
        navGreen.lightingModel = .constant
        navGreen.diffuse.contents = UIColor(red: 0.14, green: 1.0, blue: 0.36, alpha: 1.0)

        // Многослойный фюзеляж
        let upperHull = SCNBox(width: 2.1, height: 0.48, length: 6.4, chamferRadius: 0.22)
        upperHull.materials = [hullWhite]
        let upperHullNode = SCNNode(geometry: upperHull)
        upperHullNode.position = SCNVector3(0, 0.08, 0.1)
        thirdPersonMeshNode.addChildNode(upperHullNode)

        let underChassis = SCNBox(width: 1.85, height: 0.34, length: 5.8, chamferRadius: 0.12)
        underChassis.materials = [darkArmor]
        let underNode = SCNNode(geometry: underChassis)
        underNode.position = SCNVector3(0, -0.22, 0.25)
        thirdPersonMeshNode.addChildNode(underNode)

        let dorsalSpine = SCNBox(width: 0.56, height: 0.24, length: 4.1, chamferRadius: 0.08)
        dorsalSpine.materials = [darkArmor]
        let spineNode = SCNNode(geometry: dorsalSpine)
        spineNode.position = SCNVector3(0, 0.38, 1.15)
        thirdPersonMeshNode.addChildNode(spineNode)

        let spineAccent = SCNBox(width: 0.22, height: 0.26, length: 2.6, chamferRadius: 0.04)
        spineAccent.materials = [orangeTrim]
        let spineAccentNode = SCNNode(geometry: spineAccent)
        spineAccentNode.position = SCNVector3(0, 0.40, 1.6)
        thirdPersonMeshNode.addChildNode(spineAccentNode)

        // Носовой обтекатель и сенсорная антенна
        let noseMain = SCNPyramid(width: 2.05, height: 2.8, length: 0.52)
        noseMain.materials = [hullWhite]
        let noseNode = SCNNode(geometry: noseMain)
        noseNode.eulerAngles.x = -.pi / 2
        noseNode.position = SCNVector3(0, 0.02, -3.1)
        thirdPersonMeshNode.addChildNode(noseNode)

        let noseUnder = SCNPyramid(width: 1.65, height: 2.4, length: 0.28)
        noseUnder.materials = [darkArmor]
        let noseUnderNode = SCNNode(geometry: noseUnder)
        noseUnderNode.eulerAngles.x = -.pi / 2
        noseUnderNode.position = SCNVector3(0, -0.18, -2.75)
        thirdPersonMeshNode.addChildNode(noseUnderNode)

        let sensorProbe = SCNCylinder(radius: 0.055, height: 0.95)
        sensorProbe.materials = [darkArmor]
        let probeNode = SCNNode(geometry: sensorProbe)
        probeNode.eulerAngles.x = .pi / 2
        probeNode.position = SCNVector3(0, -0.02, -4.65)
        thirdPersonMeshNode.addChildNode(probeNode)

        let sensorTip = SCNSphere(radius: 0.075)
        sensorTip.materials = [glowCyan]
        let tipNode = SCNNode(geometry: sensorTip)
        tipNode.position = SCNVector3(0, -0.02, -5.12)
        thirdPersonMeshNode.addChildNode(tipNode)

        // Фонарь кабины с металлической дугой
        let canopy = SCNSphere(radius: 0.56)
        canopy.materials = [canopyGlass]
        let canopyNode = SCNNode(geometry: canopy)
        canopyNode.scale = SCNVector3(1.02, 0.46, 2.15)
        canopyNode.position = SCNVector3(0, 0.38, -1.25)
        thirdPersonMeshNode.addChildNode(canopyNode)

        let canopyArch = SCNTorus(ringRadius: 0.56, pipeRadius: 0.045)
        canopyArch.materials = [darkArmor]
        let archNode = SCNNode(geometry: canopyArch)
        archNode.scale = SCNVector3(1.03, 0.75, 2.12)
        archNode.position = SCNVector3(0, 0.36, -1.25)
        thirdPersonMeshNode.addChildNode(archNode)

        // Стреловидные дельта-крылья, воздухозаборники, кили и БАНО
        for side in [-1.0, 1.0] {
            let s = Float(side)

            let intake = SCNBox(width: 0.42, height: 0.36, length: 2.8, chamferRadius: 0.08)
            intake.materials = [darkArmor]
            let intakeNode = SCNNode(geometry: intake)
            intakeNode.position = SCNVector3(s * 1.18, 0.0, 0.15)
            thirdPersonMeshNode.addChildNode(intakeNode)

            let intakeLip = SCNBox(width: 0.46, height: 0.40, length: 0.14, chamferRadius: 0.03)
            intakeLip.materials = [orangeTrim]
            let lipNode = SCNNode(geometry: intakeLip)
            lipNode.position = SCNVector3(s * 1.18, 0.0, -1.25)
            thirdPersonMeshNode.addChildNode(lipNode)

            let radFin = SCNBox(width: 0.55, height: 0.06, length: 1.6, chamferRadius: 0.02)
            radFin.materials = [darkArmor]
            let radNode = SCNNode(geometry: radFin)
            radNode.position = SCNVector3(s * 1.25, 0.34, 1.8)
            radNode.eulerAngles.z = s * 0.25
            thirdPersonMeshNode.addChildNode(radNode)

            let wingPanel = SCNBox(width: 3.1, height: 0.12, length: 2.1, chamferRadius: 0.05)
            wingPanel.materials = [hullWhite]
            let wingNode = SCNNode(geometry: wingPanel)
            wingNode.position = SCNVector3(s * 2.25, -0.08, 1.35)
            wingNode.eulerAngles.y = -s * 0.38
            thirdPersonMeshNode.addChildNode(wingNode)

            let wingLeading = SCNBox(width: 3.15, height: 0.14, length: 0.24, chamferRadius: 0.04)
            wingLeading.materials = [darkArmor]
            let leadNode = SCNNode(geometry: wingLeading)
            leadNode.position = SCNVector3(s * 2.25, -0.08, 0.38)
            leadNode.eulerAngles.y = -s * 0.38
            thirdPersonMeshNode.addChildNode(leadNode)

            let wingStripe = SCNBox(width: 2.75, height: 0.135, length: 0.32, chamferRadius: 0.03)
            wingStripe.materials = [orangeTrim]
            let stripeNode = SCNNode(geometry: wingStripe)
            stripeNode.position = SCNVector3(s * 2.25, -0.08, 1.90)
            stripeNode.eulerAngles.y = -s * 0.38
            thirdPersonMeshNode.addChildNode(stripeNode)

            let underPod = SCNCapsule(capRadius: 0.20, height: 1.9)
            underPod.materials = [darkArmor]
            let podNode = SCNNode(geometry: underPod)
            podNode.eulerAngles.x = .pi / 2
            podNode.position = SCNVector3(s * 2.15, -0.26, 1.4)
            thirdPersonMeshNode.addChildNode(podNode)

            let tailFin = SCNBox(width: 0.09, height: 1.05, length: 1.45, chamferRadius: 0.03)
            tailFin.materials = [darkArmor]
            let finNode = SCNNode(geometry: tailFin)
            finNode.position = SCNVector3(s * 1.45, 0.46, 2.35)
            finNode.eulerAngles = SCNVector3(0.24, 0, -s * 0.30)
            thirdPersonMeshNode.addChildNode(finNode)

            let finTip = SCNBox(width: 0.10, height: 0.22, length: 1.15, chamferRadius: 0.02)
            finTip.materials = [orangeTrim]
            let finTipNode = SCNNode(geometry: finTip)
            finTipNode.position = SCNVector3(0, 0.42, 0.05)
            finNode.addChildNode(finTipNode)

            let navLed = SCNSphere(radius: 0.08)
            navLed.materials = [side < 0 ? navRed : navGreen]
            let navNode = SCNNode(geometry: navLed)
            navNode.position = SCNVector3(s * 3.72, -0.06, 2.05)
            thirdPersonMeshNode.addChildNode(navNode)
        }

        // Двойные двигательные гондолы и многослойные плазменные факелы
        exhaustNodes.removeAll()
        for xOffset in [-0.78, 0.78] {
            let x = Float(xOffset)
            let nacelle = SCNCylinder(radius: 0.34, height: 1.9)
            nacelle.materials = [darkArmor]
            let nacNode = SCNNode(geometry: nacelle)
            nacNode.eulerAngles.x = .pi / 2
            nacNode.position = SCNVector3(x, 0.02, 2.55)
            thirdPersonMeshNode.addChildNode(nacNode)

            let cowling = SCNCylinder(radius: 0.36, height: 0.30)
            cowling.materials = [hullWhite]
            let cowlNode = SCNNode(geometry: cowling)
            cowlNode.eulerAngles.x = .pi / 2
            cowlNode.position = SCNVector3(x, 0.02, 3.25)
            thirdPersonMeshNode.addChildNode(cowlNode)

            let coreRing = SCNTorus(ringRadius: 0.26, pipeRadius: 0.04)
            coreRing.materials = [glowCyan]
            let ringNode = SCNNode(geometry: coreRing)
            ringNode.eulerAngles.x = .pi / 2
            ringNode.position = SCNVector3(x, 0.02, 3.52)
            thirdPersonMeshNode.addChildNode(ringNode)

            let coreFlame = SCNCone(topRadius: 0.01, bottomRadius: 0.16, height: 1.6)
            let coreMat = SCNMaterial()
            coreMat.lightingModel = .constant
            coreMat.diffuse.contents = UIColor(red: 0.75, green: 0.96, blue: 1.0, alpha: 0.95)
            coreMat.blendMode = .add
            coreFlame.materials = [coreMat]
            let cfNode = SCNNode(geometry: coreFlame)
            cfNode.eulerAngles.x = .pi / 2
            cfNode.position = SCNVector3(x, 0.02, 4.30)
            thirdPersonMeshNode.addChildNode(cfNode)
            exhaustNodes.append(cfNode)

            let outerFlame = SCNCone(topRadius: 0.02, bottomRadius: 0.28, height: 2.5)
            let outerMat = SCNMaterial()
            outerMat.lightingModel = .constant
            outerMat.diffuse.contents = UIColor(red: 0.18, green: 0.72, blue: 1.0, alpha: 0.55)
            outerMat.blendMode = .add
            outerFlame.materials = [outerMat]
            let ofNode = SCNNode(geometry: outerFlame)
            ofNode.eulerAngles.x = .pi / 2
            ofNode.position = SCNVector3(x, 0.02, 4.75)
            thirdPersonMeshNode.addChildNode(ofNode)
            exhaustNodes.append(ofNode)
        }

        // Посадочные шасси (3 опоры с широкими лапами до y = -1.35)
        landingGearNode.childNodes.forEach { $0.removeFromParentNode() }
        let gearPositions: [SCNVector3] = [
            SCNVector3(0, -0.35, -2.35),
            SCNVector3(-1.45, -0.35, 1.35),
            SCNVector3(1.45, -0.35, 1.35)
        ]
        for gp in gearPositions {
            let gearGroup = SCNNode()
            gearGroup.position = gp

            let strut = SCNCylinder(radius: 0.075, height: 0.92)
            strut.materials = [darkArmor]
            let sNode = SCNNode(geometry: strut)
            sNode.position = SCNVector3(0, -0.46, 0)
            gearGroup.addChildNode(sNode)

            let collar = SCNCylinder(radius: 0.105, height: 0.28)
            collar.materials = [hullWhite]
            let cNode = SCNNode(geometry: collar)
            cNode.position = SCNVector3(0, -0.24, 0)
            gearGroup.addChildNode(cNode)

            let pad = SCNBox(width: 0.56, height: 0.14, length: 0.76, chamferRadius: 0.04)
            pad.materials = [darkArmor]
            let pNode = SCNNode(geometry: pad)
            pNode.position = SCNVector3(0, -0.93, 0)
            gearGroup.addChildNode(pNode)

            landingGearNode.addChildNode(gearGroup)
        }
        landingGearNode.isHidden = true
        thirdPersonMeshNode.addChildNode(landingGearNode)
    }

    private func buildFirstPersonCockpit() {
        let darkMetal = SCNMaterial()
        darkMetal.lightingModel = .physicallyBased
        darkMetal.diffuse.contents = UIColor(red: 0.09, green: 0.11, blue: 0.15, alpha: 1.0)
        darkMetal.metalness.contents = 0.72
        darkMetal.roughness.contents = 0.42

        let lightMetal = SCNMaterial()
        lightMetal.lightingModel = .physicallyBased
        lightMetal.diffuse.contents = UIColor(red: 0.18, green: 0.22, blue: 0.28, alpha: 1.0)
        lightMetal.metalness.contents = 0.80
        lightMetal.roughness.contents = 0.32

        let neonCyan = SCNMaterial()
        neonCyan.lightingModel = .constant
        neonCyan.diffuse.contents = UIColor(red: 0.05, green: 0.86, blue: 1.0, alpha: 1.0)

        let neonOrange = SCNMaterial()
        neonOrange.lightingModel = .constant
        neonOrange.diffuse.contents = UIColor(red: 1.0, green: 0.50, blue: 0.10, alpha: 1.0)

        let neonGreen = SCNMaterial()
        neonGreen.lightingModel = .constant
        neonGreen.diffuse.contents = UIColor(red: 0.20, green: 0.95, blue: 0.45, alpha: 1.0)

        let cabinLight = SCNLight()
        cabinLight.type = .omni
        cabinLight.intensity = 180
        cabinLight.color = UIColor(red: 0.35, green: 0.72, blue: 1.0, alpha: 1.0)
        cabinLight.attenuationStartDistance = 0.2
        cabinLight.attenuationEndDistance = 2.4
        let lightNode = SCNNode()
        lightNode.light = cabinLight
        lightNode.position = SCNVector3(0, 0.15, -0.35)
        cockpitMeshNode.addChildNode(lightNode)

        let mainDash = SCNBox(width: 2.3, height: 0.28, length: 0.65, chamferRadius: 0.03)
        mainDash.materials = [darkMetal]
        let dashNode = SCNNode(geometry: mainDash)
        dashNode.position = SCNVector3(0, -0.56, -0.82)
        dashNode.eulerAngles.x = 0.26
        cockpitMeshNode.addChildNode(dashNode)

        let centerHood = SCNBox(width: 0.68, height: 0.06, length: 0.38, chamferRadius: 0.02)
        centerHood.materials = [lightMetal]
        let hoodNode = SCNNode(geometry: centerHood)
        hoodNode.position = SCNVector3(0, -0.40, -0.84)
        hoodNode.eulerAngles.x = 0.15
        cockpitMeshNode.addChildNode(hoodNode)

        let trimCyan = SCNBox(width: 1.95, height: 0.008, length: 0.015, chamferRadius: 0.003)
        trimCyan.materials = [neonCyan]
        let trimNode = SCNNode(geometry: trimCyan)
        trimNode.position = SCNVector3(0, -0.42, -0.58)
        cockpitMeshNode.addChildNode(trimNode)

        let leftScreen = SCNPlane(width: 0.38, height: 0.19)
        let leftMat = SCNMaterial()
        leftMat.lightingModel = .constant
        leftMat.diffuse.contents = generateMFDTexture(isLeft: true)
        leftScreen.materials = [leftMat]
        let leftMfd = SCNNode(geometry: leftScreen)
        leftMfd.position = SCNVector3(-0.46, -0.42, -0.68)
        leftMfd.eulerAngles = SCNVector3(-0.34, 0.24, 0)
        cockpitMeshNode.addChildNode(leftMfd)

        let rightScreen = SCNPlane(width: 0.38, height: 0.19)
        let rightMat = SCNMaterial()
        rightMat.lightingModel = .constant
        rightMat.diffuse.contents = generateMFDTexture(isLeft: false)
        rightScreen.materials = [rightMat]
        let rightMfd = SCNNode(geometry: rightScreen)
        rightMfd.position = SCNVector3(0.46, -0.42, -0.68)
        rightMfd.eulerAngles = SCNVector3(-0.34, -0.24, 0)
        cockpitMeshNode.addChildNode(rightMfd)

        let radarGroup = SCNNode()
        radarGroup.position = SCNVector3(0, -0.35, -0.68)
        radarGroup.eulerAngles.x = 0.22

        let holoMat = SCNMaterial()
        holoMat.lightingModel = .constant
        holoMat.diffuse.contents = UIColor(red: 1.0, green: 0.56, blue: 0.12, alpha: 0.85)
        holoMat.blendMode = .add
        holoMat.writesToDepthBuffer = false

        let holoCyanMat = SCNMaterial()
        holoCyanMat.lightingModel = .constant
        holoCyanMat.diffuse.contents = UIColor(red: 0.1, green: 0.88, blue: 1.0, alpha: 0.8)
        holoCyanMat.blendMode = .add
        holoCyanMat.writesToDepthBuffer = false

        for (idx, r) in [0.055, 0.095, 0.135].enumerated() {
            let ring = SCNTorus(ringRadius: CGFloat(r), pipeRadius: 0.0022)
            ring.materials = [idx == 1 ? holoCyanMat : holoMat]
            radarGroup.addChildNode(SCNNode(geometry: ring))
        }

        let shipIcon = SCNPyramid(width: 0.022, height: 0.032, length: 0.012)
        shipIcon.materials = [holoCyanMat]
        let iconNode = SCNNode(geometry: shipIcon)
        iconNode.eulerAngles.x = -.pi / 2
        iconNode.position = SCNVector3(0, 0.01, 0)
        radarGroup.addChildNode(iconNode)

        let sweep = SCNBox(width: 0.26, height: 0.002, length: 0.003, chamferRadius: 0)
        sweep.materials = [holoMat]
        let sweepNode = SCNNode(geometry: sweep)
        sweepNode.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 5.5)))
        radarGroup.addChildNode(sweepNode)
        cockpitMeshNode.addChildNode(radarGroup)

        cockpitThrottlePivot.position = SCNVector3(-0.62, -0.48, -0.50)
        let throttleArm = SCNBox(width: 0.035, height: 0.12, length: 0.03, chamferRadius: 0.006)
        throttleArm.materials = [lightMetal]
        let tArmNode = SCNNode(geometry: throttleArm)
        tArmNode.position = SCNVector3(0, 0.06, 0)
        cockpitThrottlePivot.addChildNode(tArmNode)

        let throttleGrip = SCNBox(width: 0.11, height: 0.04, length: 0.055, chamferRadius: 0.012)
        throttleGrip.materials = [darkMetal]
        let tGripNode = SCNNode(geometry: throttleGrip)
        tGripNode.position = SCNVector3(0, 0.12, 0)
        cockpitThrottlePivot.addChildNode(tGripNode)

        let tLed = SCNBox(width: 0.07, height: 0.008, length: 0.01, chamferRadius: 0.002)
        tLed.materials = [neonCyan]
        let tLedNode = SCNNode(geometry: tLed)
        tLedNode.position = SCNVector3(0, 0.142, -0.015)
        cockpitThrottlePivot.addChildNode(tLedNode)
        cockpitMeshNode.addChildNode(cockpitThrottlePivot)

        cockpitStickPivot.position = SCNVector3(0.62, -0.50, -0.50)
        let stickShaft = SCNCylinder(radius: 0.014, height: 0.15)
        stickShaft.materials = [lightMetal]
        let sShaftNode = SCNNode(geometry: stickShaft)
        sShaftNode.position = SCNVector3(0, 0.075, 0)
        cockpitStickPivot.addChildNode(sShaftNode)

        let stickHead = SCNBox(width: 0.042, height: 0.055, length: 0.048, chamferRadius: 0.012)
        stickHead.materials = [darkMetal]
        let sHeadNode = SCNNode(geometry: stickHead)
        sHeadNode.position = SCNVector3(0, 0.15, 0)
        cockpitStickPivot.addChildNode(sHeadNode)

        let triggerLed = SCNSphere(radius: 0.007)
        triggerLed.materials = [neonOrange]
        let trigNode = SCNNode(geometry: triggerLed)
        trigNode.position = SCNVector3(0, 0.175, -0.015)
        cockpitStickPivot.addChildNode(trigNode)
        cockpitMeshNode.addChildNode(cockpitStickPivot)

        for side in [-1.0, 1.0] {
            let mainStrut = SCNBox(width: 0.048, height: 1.25, length: 0.055, chamferRadius: 0.01)
            mainStrut.materials = [darkMetal]
            let sNode = SCNNode(geometry: mainStrut)
            sNode.position = SCNVector3(Float(side * 0.78), 0.06, -0.74)
            sNode.eulerAngles = SCNVector3(0.24, 0, Float(side * 0.25))
            cockpitMeshNode.addChildNode(sNode)

            let innerBevel = SCNBox(width: 0.014, height: 1.15, length: 0.02, chamferRadius: 0.004)
            innerBevel.materials = [lightMetal]
            let bNode = SCNNode(geometry: innerBevel)
            bNode.position = SCNVector3(Float(side * 0.752), 0.06, -0.72)
            bNode.eulerAngles = SCNVector3(0.24, 0, Float(side * 0.25))
            cockpitMeshNode.addChildNode(bNode)

            let ledStrip = SCNBox(width: 0.009, height: 0.22, length: 0.009, chamferRadius: 0.003)
            ledStrip.materials = [neonOrange]
            let lNode = SCNNode(geometry: ledStrip)
            lNode.position = SCNVector3(Float(side * 0.74), 0.04, -0.71)
            lNode.eulerAngles = SCNVector3(0.24, 0, Float(side * 0.25))
            cockpitMeshNode.addChildNode(lNode)
        }

        let topBar = SCNBox(width: 1.44, height: 0.06, length: 0.12, chamferRadius: 0.012)
        topBar.materials = [darkMetal]
        let topNode = SCNNode(geometry: topBar)
        topNode.position = SCNVector3(0, 0.57, -0.64)
        topNode.eulerAngles.x = 0.25
        cockpitMeshNode.addChildNode(topNode)

        for i in -3...3 {
            let led = SCNBox(width: 0.028, height: 0.008, length: 0.008, chamferRadius: 0.002)
            led.materials = [i == 0 ? neonCyan : (abs(i) == 3 ? neonOrange : neonGreen)]
            let ledNode = SCNNode(geometry: led)
            ledNode.position = SCNVector3(Float(i) * 0.065, 0.545, -0.59)
            cockpitMeshNode.addChildNode(ledNode)
        }

        let hudGroup = SCNNode()
        hudGroup.position = SCNVector3(0, 0.02, -0.95)

        let reticle = SCNTorus(ringRadius: 0.036, pipeRadius: 0.0018)
        reticle.materials = [holoCyanMat]
        let rNode = SCNNode(geometry: reticle)
        rNode.eulerAngles.x = .pi / 2
        hudGroup.addChildNode(rNode)

        let centerDot = SCNSphere(radius: 0.003)
        centerDot.materials = [holoMat]
        hudGroup.addChildNode(SCNNode(geometry: centerDot))

        for side in [-1.0, 1.0] {
            let bracket = SCNBox(width: 0.003, height: 0.12, length: 0.002, chamferRadius: 0)
            bracket.materials = [holoCyanMat]
            let brNode = SCNNode(geometry: bracket)
            brNode.position = SCNVector3(Float(side * 0.16), 0, 0)
            hudGroup.addChildNode(brNode)

            for tick in [-0.045, 0.0, 0.045] {
                let tickBar = SCNBox(width: 0.022, height: 0.002, length: 0.002, chamferRadius: 0)
                tickBar.materials = [holoMat]
                let tNode = SCNNode(geometry: tickBar)
                tNode.position = SCNVector3(Float(side * 0.145), Float(tick), 0)
                hudGroup.addChildNode(tNode)
            }
        }
        cockpitMeshNode.addChildNode(hudGroup)
    }

    private func generateMFDTexture(isLeft: Bool) -> UIImage {
        let w = 512, h = 256
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        return renderer.image { context in
            let ctx = context.cgContext
            ctx.setFillColor(UIColor(red: 0.02, green: 0.06, blue: 0.10, alpha: 0.96).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

            let cyan = UIColor(red: 0.05, green: 0.86, blue: 1.0, alpha: 1.0)
            let orange = UIColor(red: 1.0, green: 0.52, blue: 0.12, alpha: 1.0)
            ctx.setStrokeColor(cyan.withAlphaComponent(0.65).cgColor)
            ctx.setLineWidth(4)
            ctx.stroke(CGRect(x: 6, y: 6, width: w - 12, height: h - 12))

            ctx.setStrokeColor(cyan.withAlphaComponent(0.14).cgColor)
            ctx.setLineWidth(1)
            for x in stride(from: 32, to: w, by: 32) {
                ctx.move(to: CGPoint(x: x, y: 8))
                ctx.addLine(to: CGPoint(x: x, y: h - 8))
            }
            for y in stride(from: 32, to: h, by: 32) {
                ctx.move(to: CGPoint(x: 8, y: y))
                ctx.addLine(to: CGPoint(x: w - 8, y: y))
            }
            ctx.strokePath()

            if isLeft {
                let cx: CGFloat = 135, cy: CGFloat = 128
                for r in [76, 62, 48] {
                    ctx.setStrokeColor(cyan.withAlphaComponent(r == 76 ? 0.9 : 0.45).cgColor)
                    ctx.setLineWidth(r == 76 ? 4 : 2)
                    ctx.strokeEllipse(in: CGRect(x: cx - CGFloat(r), y: cy - CGFloat(r), width: CGFloat(r * 2), height: CGFloat(r * 2)))
                }
                ctx.setStrokeColor(orange.cgColor)
                ctx.setLineWidth(3)
                ctx.move(to: CGPoint(x: cx, y: cy - 34))
                ctx.addLine(to: CGPoint(x: cx + 32, y: cy + 24))
                ctx.addLine(to: CGPoint(x: cx, y: cy + 12))
                ctx.addLine(to: CGPoint(x: cx - 32, y: cy + 24))
                ctx.closePath()
                ctx.strokePath()

                let labels = [("SYS", 0.85, cyan), ("ENG", 0.95, orange), ("WEP", 0.65, cyan)]
                for (i, item) in labels.enumerated() {
                    let y = CGFloat(54 + i * 58)
                    ctx.setFillColor(item.2.withAlphaComponent(0.22).cgColor)
                    ctx.fill(CGRect(x: 260, y: y, width: 215, height: 24))
                    ctx.setFillColor(item.2.cgColor)
                    ctx.fill(CGRect(x: 260, y: y, width: CGFloat(215.0 * item.1), height: 24))
                }
            } else {
                let cx: CGFloat = 370, cy: CGFloat = 128
                ctx.setStrokeColor(orange.withAlphaComponent(0.8).cgColor)
                ctx.setLineWidth(2.5)
                ctx.strokeEllipse(in: CGRect(x: cx - 95, y: cy - 65, width: 190, height: 130))
                ctx.setStrokeColor(cyan.withAlphaComponent(0.75).cgColor)
                ctx.strokeEllipse(in: CGRect(x: cx - 55, y: cy - 38, width: 110, height: 76))
                ctx.setFillColor(orange.cgColor)
                ctx.fillEllipse(in: CGRect(x: cx - 12, y: cy - 12, width: 24, height: 24))
                ctx.setFillColor(cyan.cgColor)
                ctx.fillEllipse(in: CGRect(x: cx + 82, y: cy - 16, width: 12, height: 12))

                ctx.setStrokeColor(cyan.cgColor)
                ctx.setLineWidth(3)
                ctx.move(to: CGPoint(x: 24, y: 128))
                for x in stride(from: 24, through: 235, by: 6) {
                    let t = Double(x) * 0.08
                    let y = 128.0 + sin(t) * 48.0 * cos(t * 0.35)
                    ctx.addLine(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
                }
                ctx.strokePath()
            }
        }
    }

    func toggleFreeCamera() {
        if walkingState {
            boardShip()
        }
        isFreeCamera.toggle()
        if isFreeCamera {
            autoSpeed = true
            throttle = 0
            shipVelocityMetersPerSec = .zero
            angularVelYaw = 0
            angularVelPitch = 0
        }
        updateCameraMode()
    }

    func updateCameraMode() {
        if walkingState {
            thirdPersonMeshNode.isHidden = false
            cockpitMeshNode.isHidden = true
            cameraBoomNode.eulerAngles = SCNVector3(0, 0, 0)
            cameraNode.position = SCNVector3(0, 0, 0)
            cameraNode.eulerAngles = SCNVector3(0, 0, 0)
        } else if isFreeCamera {
            thirdPersonMeshNode.isHidden = true
            cockpitMeshNode.isHidden = true
            cameraBoomNode.eulerAngles = SCNVector3(0, 0, 0)
            cameraNode.position = SCNVector3(0, 0, 0)
            cameraNode.eulerAngles = SCNVector3(0, 0, 0)
        } else {
            thirdPersonMeshNode.isHidden = !isThirdPerson
            cockpitMeshNode.isHidden = isThirdPerson
            if isThirdPerson {
                cameraBoomNode.eulerAngles = SCNVector3(orbitPitch + cameraLagPitch, orbitYaw + cameraLagYaw, 0)
                cameraNode.position = SCNVector3(0, 0, orbitDistance)
                cameraNode.eulerAngles = SCNVector3(0, 0, 0)
            } else {
                cameraBoomNode.eulerAngles = SCNVector3(0, 0, 0)
                cameraNode.position = SCNVector3(0, 0, 0)
                cameraNode.eulerAngles = SCNVector3(0, 0, 0)
            }
        }
    }

    private func generateStarCubemap() -> [UIImage] {
        let size = 1024
        var faces: [UIImage] = []
        let starColors: [UIColor] = [
            .white,
            UIColor(red: 0.75, green: 0.88, blue: 1.0, alpha: 1.0),
            UIColor(red: 1.0, green: 0.92, blue: 0.75, alpha: 1.0),
            UIColor(red: 1.0, green: 0.72, blue: 0.55, alpha: 1.0)
        ]

        for face in 0..<6 {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
            let img = renderer.image { context in
                let ctx = context.cgContext
                ctx.setFillColor(UIColor(red: 0.005, green: 0.008, blue: 0.016, alpha: 1.0).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

                var rng: UInt64 = UInt64(face + 1) &* 0x9E3779B97F4A7C15
                func nextRand() -> Double {
                    rng = rng &* 6364136223846793005 &+ 1442695040888963407
                    return Double(rng >> 33) / Double(1 << 31)
                }

                if face == 0 || face == 1 || face == 4 || face == 5 {
                    for _ in 0..<1000 {
                        let x = CGFloat(nextRand() * Double(size))
                        let y = CGFloat(Double(size) * 0.5 + (nextRand() - 0.5) * 240.0)
                        ctx.setFillColor(UIColor(red: 0.58, green: 0.74, blue: 1.0, alpha: 0.045).cgColor)
                        ctx.fillEllipse(in: CGRect(x: x, y: y, width: 4.5, height: 4.5))
                    }
                }

                for i in 0..<1800 {
                    let x = CGFloat(nextRand() * Double(size))
                    let y = CGFloat(nextRand() * Double(size))
                    let r = (i % 20 == 0) ? CGFloat(2.2) : CGFloat(0.9 + nextRand() * 0.8)
                    let alpha = CGFloat(0.25 + nextRand() * 0.75)
                    ctx.setFillColor(starColors[i % starColors.count].withAlphaComponent(alpha).cgColor)
                    ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
                }
            }
            faces.append(img)
        }
        return faces
    }

    private func generateDetailedRingImage(isBlackHole: Bool, isUranus: Bool) -> UIImage {
        let size = 1024
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)

        return renderer.image { context in
            let ctx = context.cgContext
            ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
            let center = CGPoint(x: size / 2, y: size / 2)

            if isBlackHole {
                for r in 135..<495 {
                    let t = CGFloat(r - 135) / 360.0
                    let fade = sin(min(1.0, t * 7.0) * .pi * 0.5) * pow(1.0 - t, 1.55)
                    let red: CGFloat = 1.0
                    let green: CGFloat = max(0.18, 0.92 - t * 0.78)
                    let blue: CGFloat = max(0.02, 0.68 - t * 1.15)
                    let wave = 0.72 + 0.28 * sin(Double(r) * 0.14)
                    ctx.setStrokeColor(UIColor(red: red, green: green, blue: blue, alpha: fade * CGFloat(wave) * 0.85).cgColor)
                    ctx.setLineWidth(1.8)
                    ctx.addArc(center: center, radius: CGFloat(r), startAngle: 0, endAngle: .pi * 2, clockwise: false)
                    ctx.strokePath()
                }
                for s in 0..<24 {
                    let startAngle = CGFloat(s) * (.pi * 2.0 / 24.0)
                    let radius = CGFloat(155 + (s * 47) % 270)
                    let arcLen = CGFloat(0.6 + Double(s % 5) * 0.35)
                    ctx.setStrokeColor(UIColor(red: 1.0, green: 0.78, blue: 0.42, alpha: 0.35).cgColor)
                    ctx.setLineWidth(CGFloat(3 + (s % 6)))
                    ctx.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: startAngle + arcLen, clockwise: false)
                    ctx.strokePath()
                }
            } else if isUranus {
                let ringRadii: [(r: CGFloat, w: CGFloat, a: CGFloat)] = [
                    (310, 2.5, 0.22), (335, 3.0, 0.28), (360, 2.0, 0.18),
                    (395, 4.0, 0.35), (430, 5.5, 0.48), (465, 2.5, 0.25)
                ]
                for ring in ringRadii {
                    ctx.setStrokeColor(UIColor(red: 0.72, green: 0.88, blue: 0.96, alpha: ring.a).cgColor)
                    ctx.setLineWidth(ring.w)
                    ctx.addArc(center: center, radius: ring.r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
                    ctx.strokePath()
                }
            } else {
                for r in 235..<492 {
                    if (r >= 382 && r <= 398) || (r >= 456 && r <= 460) { continue }
                    let t = CGFloat(r - 235) / 257.0
                    let edgeFade = min(1.0, t * 14.0) * min(1.0, (1.0 - t) * 14.0)
                    let bands = 0.55 + 0.28 * sin(Double(r) * 0.38) + 0.17 * cos(Double(r) * 0.95)
                    let cr = 0.74 + 0.14 * CGFloat(bands)
                    let cg = 0.66 + 0.13 * CGFloat(bands)
                    let cb = 0.50 + 0.12 * CGFloat(bands)
                    let alpha = edgeFade * CGFloat(bands) * 0.88
                    ctx.setStrokeColor(UIColor(red: cr, green: cg, blue: cb, alpha: alpha).cgColor)
                    ctx.setLineWidth(1.5)
                    ctx.addArc(center: center, radius: CGFloat(r), startAngle: 0, endAngle: .pi * 2, clockwise: false)
                    ctx.strokePath()
                }
            }
        }
    }

    func handleCameraOrbitDrag(dx: Double, dy: Double) {
        if walkingState {
            evaYaw -= dx * 0.0055
            evaPitch = max(-1.25, min(1.30, evaPitch - dy * 0.0055))
        } else if isFreeCamera {
            // В свободной камере SpaceEngine свайп по экрану плавно поворачивает взгляд
            let qYaw = simd_quatd(angle: -dx * 0.0045, axis: SIMD3(0, 1, 0))
            let qPitch = simd_quatd(angle: -dy * 0.0045, axis: SIMD3(1, 0, 0))
            shipOrientation = simd_normalize(shipOrientation * qYaw * qPitch)
        } else if isThirdPerson {
            orbitYaw -= Float(dx * 0.006)
            orbitPitch = max(-1.35, min(1.35, orbitPitch - Float(dy * 0.006)))
            updateCameraMode()
        }
    }

    private func safeNormalize(_ v: SIMD3<Double>, fallback: SIMD3<Double> = SIMD3<Double>(0, 0, -1)) -> SIMD3<Double> {
        let len2 = simd_length_squared(v)
        return len2 > 1e-12 ? (v / sqrt(len2)) : fallback
    }

    private func orientationFromForwardUp(forward: SIMD3<Double>, up: SIMD3<Double>) -> simd_quatd {
        let f = safeNormalize(forward, fallback: SIMD3<Double>(0, 0, -1))
        var u = safeNormalize(up, fallback: SIMD3<Double>(0, 1, 0))
        var r = simd_cross(f, u)
        if simd_length_squared(r) < 1e-10 {
            let ref = abs(u.y) < 0.9 ? SIMD3<Double>(0, 1, 0) : SIMD3<Double>(1, 0, 0)
            r = safeNormalize(simd_cross(ref, u), fallback: SIMD3<Double>(1, 0, 0))
        } else {
            r = simd_normalize(r)
        }
        u = safeNormalize(simd_cross(r, f), fallback: u)
        let rotMat = simd_double3x3(columns: (r, u, -f))
        return simd_normalize(simd_quatd(rotMat))
    }

    private func planetSpinAndInvRot(for body: CelestialBody) -> (rawSpin: Double, spinFloat: Float, invRot: simd_quatd) {
        let rawSpin = (body.rotationPeriodSeconds != 0)
            ? ((2.0 * .pi / body.rotationPeriodSeconds) * simulationTimeSeconds)
            : 0.0
        let wrapped = rawSpin.truncatingRemainder(dividingBy: 2.0 * .pi)
        let invTilt = simd_quatd(angle: -body.axialTiltRad, axis: SIMD3<Double>(0, 0, 1))
        let invSpin = simd_quatd(angle: -wrapped, axis: SIMD3<Double>(0, 1, 0))
        return (rawSpin, Float(wrapped), invSpin * invTilt)
    }

    private func planetRot(for body: CelestialBody) -> simd_quatd {
        let rawSpin = (body.rotationPeriodSeconds != 0)
            ? ((2.0 * .pi / body.rotationPeriodSeconds) * simulationTimeSeconds)
            : 0.0
        let wrapped = rawSpin.truncatingRemainder(dividingBy: 2.0 * .pi)
        let tiltQuat = simd_quatd(angle: body.axialTiltRad, axis: SIMD3<Double>(0, 0, 1))
        let spinQuat = simd_quatd(angle: wrapped, axis: SIMD3<Double>(0, 1, 0))
        return tiltQuat * spinQuat
    }

    func alignToTarget() {
        let targetPos = targetBody.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
        let dir = safeNormalize(targetPos - shipPositionMeters)
        let forward = SIMD3<Double>(0, 0, -1)
        let dot = simd_dot(forward, dir)
        if dot < -0.9999 {
            shipOrientation = simd_quatd(angle: .pi, axis: SIMD3(0, 1, 0))
        } else if dot < 0.9999 {
            let axis = safeNormalize(simd_cross(forward, dir), fallback: SIMD3(0, 1, 0))
            shipOrientation = simd_quatd(angle: acos(max(-1.0, min(1.0, dot))), axis: axis)
        }
        orbitYaw = 0
        orbitPitch = -0.16
        angularVelYaw = 0
        angularVelPitch = 0
        updateCameraMode()
    }

    func warpToBody(_ body: CelestialBody) {
        if walkingState {
            boardShip()
        }
        targetBody = body
        throttle = 0
        shipVelocityMetersPerSec = .zero
        landedState = false
        isLanded = false
        lastTerrainAltitude = -1
        activeSurfaceBodyId = nil
        activeTerrainCollision = nil
        lastTrackedBodyId = nil
        hasPropsForCurrentAnchor = false
        evaScannerOpen = false
        evaScanReport = nil
        terrainRootNode.isHidden = true
        skyDomeNode.isHidden = true
        surfacePropsNode.isHidden = true
        reentryHeat = 0.0

        let bodyPos = body.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
        let orbitDist: Double
        if body.isBlackHole {
            orbitDist = max(body.radiusMeters * 8.5, 50_000_000.0)
        } else if body.isGalaxy {
            orbitDist = body.radiusMeters * 2.4
        } else if body.radiusMeters < 100_000 {
            orbitDist = max(body.radiusMeters * 4.5, 120_000.0)
        } else {
            orbitDist = body.radiusMeters * 2.9
        }

        let offsetDir: SIMD3<Double>
        if body.isGalaxy || body.isBlackHole {
            offsetDir = safeNormalize(SIMD3<Double>(0.45, 0.62, 0.64))
        } else if body.isStar || simd_length(bodyPos) < 1_000 {
            offsetDir = safeNormalize(SIMD3<Double>(0.6, 0.25, 0.75))
        } else {
            let toSun = safeNormalize(-bodyPos)
            let right = safeNormalize(simd_cross(SIMD3<Double>(0, 1, 0), toSun), fallback: SIMD3<Double>(1, 0, 0))
            offsetDir = safeNormalize(toSun * 0.74 + right * 0.62 + SIMD3<Double>(0, 0.20, 0))
        }

        shipPositionMeters = bodyPos + offsetDir * orbitDist
        alignToTarget()
    }

    func warpToSurfaceApproach(_ body: CelestialBody) {
        guard body.isLandable else { return }
        if walkingState {
            boardShip()
        }
        targetBody = body
        throttle = 0
        shipVelocityMetersPerSec = .zero
        landedState = false
        isLanded = false
        autoSpeed = true
        angularVelYaw = 0
        angularVelPitch = 0
        lastTerrainAltitude = -1
        activeSurfaceBodyId = nil
        activeTerrainCollision = nil
        lastTrackedBodyId = nil
        hasPropsForCurrentAnchor = false
        evaScannerOpen = false
        evaScanReport = nil
        reentryHeat = 0.0

        let bodyPos = body.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
        let (_, _, invRot) = planetSpinAndInvRot(for: body)
        let offsetDir = SurfaceTerrainEngine.findScenicApproachDirection(for: body, bodyPos: bodyPos, invPlanetRot: invRot)
        let sample = SurfaceTerrainEngine.sampleTerrain(localDir: invRot.act(offsetDir), body: body)
        let groundH = body.isHabitableWorld ? max(0.0, sample.heightMeters) : sample.heightMeters

        shipPositionMeters = bodyPos + offsetDir * (body.radiusMeters + groundH + 4_500.0)
        let toSun = simd_length_squared(bodyPos) > 1e6
            ? safeNormalize(-bodyPos)
            : safeNormalize(SIMD3<Double>(0.6, 0.25, 0.75))
        let sunHoriz = safeNormalize(
            toSun - offsetDir * simd_dot(toSun, offsetDir),
            fallback: safeNormalize(simd_cross(offsetDir, SIMD3<Double>(0, 1, 0)), fallback: SIMD3<Double>(1, 0, 0))
        )
        let crossSide = safeNormalize(simd_cross(offsetDir, sunHoriz), fallback: SIMD3<Double>(1, 0, 0))
        let horizFwd = safeNormalize(sunHoriz * 0.55 + crossSide * 0.83)
        let lookFwd = safeNormalize(horizFwd * cos(0.28) - offsetDir * sin(0.28))
        shipOrientation = orientationFromForwardUp(forward: lookFwd, up: offsetDir)
        orbitYaw = 0
        orbitPitch = -0.16
        updateCameraMode()
    }

    private func groundSampleAt(
        worldPos: SIMD3<Double>,
        body: CelestialBody,
        bodyPos: SIMD3<Double>,
        planetRot: simd_quatd,
        invPlanetRot: simd_quatd
    ) -> (height: Double, isWater: Bool) {
        let up = safeNormalize(worldPos - bodyPos, fallback: SIMD3<Double>(0, 1, 0))
        let sample = SurfaceTerrainEngine.sampleTerrain(localDir: invPlanetRot.act(up), body: body)
        if activeSurfaceBodyId == body.id,
           let meshHeight = activeTerrainCollision?.sampleHeight(
               worldPos: worldPos,
               currentPlanetRot: planetRot,
               currentBodyPos: bodyPos
           ) {
            return (meshHeight, sample.isWater)
        }
        let h = body.isHabitableWorld ? max(0.0, sample.heightMeters) : sample.heightMeters
        return (h, sample.isWater)
    }

    func toggleSurfaceScanner() {
        evaScannerOpen.toggle()
        guard evaScannerOpen else {
            evaScanReport = nil
            return
        }
        var nearestBody = targetBody
        var nearestDist = Double.greatestFiniteMagnitude
        var nearestPos = SIMD3<Double>.zero
        for body in UniverseCatalog.bodies where body.isLandable {
            let pos = body.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
            let d = simd_length(shipPositionMeters - pos) - body.radiusMeters
            if d < nearestDist {
                nearestDist = d
                nearestBody = body
                nearestPos = pos
            }
        }
        let (_, _, invRot) = planetSpinAndInvRot(for: nearestBody)
        let curRot = planetRot(for: nearestBody)
        let upWorld = safeNormalize(shipPositionMeters - nearestPos, fallback: SIMD3<Double>(0, 1, 0))
        let ground = groundSampleAt(
            worldPos: shipPositionMeters,
            body: nearestBody,
            bodyPos: nearestPos,
            planetRot: curRot,
            invPlanetRot: invRot
        )
        evaScanReport = SurfaceTerrainEngine.surfaceScanReport(
            body: nearestBody,
            localDir: invRot.act(upWorld),
            elevationMeters: ground.height
        )
    }

    func landAtCurrentSpot() {
        guard !walkingState, !isFreeCamera else { return }
        var nearestBody = targetBody
        var nearestDist = Double.greatestFiniteMagnitude
        var nearestPos = SIMD3<Double>.zero
        for body in UniverseCatalog.bodies where body.isLandable {
            let pos = body.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
            let d = simd_length(shipPositionMeters - pos) - body.radiusMeters
            if d < nearestDist {
                nearestDist = d
                nearestBody = body
                nearestPos = pos
            }
        }
        guard nearestBody.isLandable else { return }
        let upWorld = safeNormalize(shipPositionMeters - nearestPos, fallback: SIMD3<Double>(0, 1, 0))
        let (_, _, invRot) = planetSpinAndInvRot(for: nearestBody)
        let curRot = planetRot(for: nearestBody)
        let ground = groundSampleAt(
            worldPos: shipPositionMeters,
            body: nearestBody,
            bodyPos: nearestPos,
            planetRot: curRot,
            invPlanetRot: invRot
        )
        let radarAlt = max(0.0, nearestDist - ground.height)
        guard !ground.isWater && radarAlt < 1_800.0 else { return }

        shipPositionMeters = nearestPos + upWorld * (nearestBody.radiusMeters + ground.height + 1.35)
        levelToHorizon()
        throttle = 0
        shipVelocityMetersPerSec = .zero
        hasPropsForCurrentAnchor = false
        landedState = true
        isLanded = true
        landingGearNode.isHidden = false
        targetBody = nearestBody
    }

    func enterWalkingMode() {
        guard landedState && !walkingState else { return }
        var nearestBody = targetBody
        var nearestDist = Double.greatestFiniteMagnitude
        var nearestPos = SIMD3<Double>.zero
        for body in UniverseCatalog.bodies where body.isLandable {
            let pos = body.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
            let d = simd_length(shipPositionMeters - pos) - body.radiusMeters
            if d < nearestDist {
                nearestDist = d
                nearestBody = body
                nearestPos = pos
            }
        }

        let (_, _, invRot) = planetSpinAndInvRot(for: nearestBody)
        let curRot = planetRot(for: nearestBody)
        parkedShipBodyId = nearestBody.id
        parkedShipLocalPos = invRot.act(shipPositionMeters - nearestPos)
        parkedShipLocalOrient = simd_normalize(invRot * shipOrientation)

        thirdPersonMeshNode.removeFromParentNode()
        parkedShipNode.addChildNode(thirdPersonMeshNode)
        parkedShipNode.isHidden = false
        thirdPersonMeshNode.isHidden = false
        cockpitMeshNode.isHidden = true
        landingGearNode.isHidden = false

        let upWorld = safeNormalize(shipPositionMeters - nearestPos, fallback: SIMD3<Double>(0, 1, 0))
        let shipRight = shipOrientation.act(SIMD3<Double>(1, 0, 0))
        let shipFwd = shipOrientation.act(SIMD3<Double>(0, 0, -1))
        let tangentRight = safeNormalize(
            shipRight - upWorld * simd_dot(shipRight, upWorld),
            fallback: safeNormalize(simd_cross(upWorld, SIMD3<Double>(0, 1, 0)))
        )

        let playerSpot = shipPositionMeters + tangentRight * 7.0
        let playerUp = safeNormalize(playerSpot - nearestPos, fallback: upWorld)
        let ground = groundSampleAt(
            worldPos: playerSpot,
            body: nearestBody,
            bodyPos: nearestPos,
            planetRot: curRot,
            invPlanetRot: invRot
        )
        shipPositionMeters = nearestPos + playerUp * (nearestBody.radiusMeters + ground.height + 1.85)

        let lookAtShip = safeNormalize(shipFwd * 0.35 - tangentRight * 0.90)
        evaRefForwardLocal = invRot.act(lookAtShip)
        evaYaw = 0.0
        evaPitch = -0.05
        evaVerticalVel = 0.0
        evaHeightAboveGround = 1.85
        evaWalkPhase = 0.0

        let shipRel = (nearestPos + curRot.act(parkedShipLocalPos)) - shipPositionMeters
        parkedShipNode.simdPosition = SIMD3<Float>(Float(shipRel.x), Float(shipRel.y), Float(shipRel.z))
        let shipWorldOrient = simd_normalize(curRot * parkedShipLocalOrient)
        parkedShipNode.simdOrientation = simd_quatf(
            ix: Float(shipWorldOrient.imag.x),
            iy: Float(shipWorldOrient.imag.y),
            iz: Float(shipWorldOrient.imag.z),
            r: Float(shipWorldOrient.real)
        )

        walkingState = true
        isWalkingOnSurface = true
        isFreeCamera = false
        evaSprinting = false
        evaJetpackActive = false
        evaScannerOpen = false
        evaScanReport = nil
        jetpackFuelState = 1.0
        evaJetpackFuel = 1.0
        evaShipDistanceText = "7 м"
        evaTempText = "\(nearestBody.meanTempC) °C"
        hasPropsForCurrentAnchor = false
        throttle = 0
        shipVelocityMetersPerSec = .zero
        angularVelYaw = 0
        angularVelPitch = 0
        targetBody = nearestBody
        updateCameraMode()
    }

    func boardShip() {
        guard walkingState else { return }
        thirdPersonMeshNode.removeFromParentNode()
        shipVisualNode.addChildNode(thirdPersonMeshNode)
        parkedShipNode.isHidden = true

        if let pid = parkedShipBodyId, let body = UniverseCatalog.bodies.first(where: { $0.id == pid }) {
            let bodyPos = body.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
            let curRot = planetRot(for: body)
            shipPositionMeters = bodyPos + curRot.act(parkedShipLocalPos)
            shipOrientation = simd_normalize(curRot * parkedShipLocalOrient)
            targetBody = body
        }

        walkingState = false
        isWalkingOnSurface = false
        evaSprinting = false
        evaJetpackActive = false
        evaScannerOpen = false
        evaScanReport = nil
        jetpackFuelState = 1.0
        evaJetpackFuel = 1.0
        hasPropsForCurrentAnchor = false
        landedState = true
        isLanded = true
        throttle = 0
        shipVelocityMetersPerSec = .zero
        updateCameraMode()
    }

    func evaJump() {
        guard walkingState, evaHeightAboveGround <= 2.05 else { return }
        evaVerticalVel = 5.2
    }

    func takeoffFromSurface() {
        if walkingState {
            boardShip()
        }
        var nearestBody = targetBody
        var nearestDist = Double.greatestFiniteMagnitude
        var nearestPos = SIMD3<Double>.zero
        for body in UniverseCatalog.bodies where body.isLandable {
            let pos = body.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
            let d = simd_length(shipPositionMeters - pos) - body.radiusMeters
            if d < nearestDist {
                nearestDist = d
                nearestBody = body
                nearestPos = pos
            }
        }
        let upWorld = safeNormalize(shipPositionMeters - nearestPos, fallback: SIMD3<Double>(0, 1, 0))
        landedState = false
        isLanded = false
        throttle = 0.45
        autoSpeed = true
        shipVelocityMetersPerSec = upWorld * 65.0
        shipPositionMeters += upWorld * 5.0

        let fwd = shipOrientation.act(SIMD3<Double>(0, 0, -1))
        let horiz = safeNormalize(
            fwd - upWorld * simd_dot(fwd, upWorld),
            fallback: safeNormalize(simd_cross(upWorld, SIMD3<Double>(1, 0, 0)))
        )
        let climbFwd = safeNormalize(horiz * cos(0.26) + upWorld * sin(0.26))
        shipOrientation = orientationFromForwardUp(forward: climbFwd, up: upWorld)
        targetBody = nearestBody
    }

    func levelToHorizon() {
        var nearestPos = SIMD3<Double>.zero
        var nearestDist = Double.greatestFiniteMagnitude
        for body in UniverseCatalog.bodies where !body.isStar {
            let pos = body.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
            let d = simd_length(shipPositionMeters - pos) - body.radiusMeters
            if d < nearestDist {
                nearestDist = d
                nearestPos = pos
            }
        }
        let upWorld = safeNormalize(shipPositionMeters - nearestPos, fallback: SIMD3<Double>(0, 1, 0))
        let fwd = shipOrientation.act(SIMD3<Double>(0, 0, -1))
        let horiz = safeNormalize(
            fwd - upWorld * simd_dot(fwd, upWorld),
            fallback: safeNormalize(simd_cross(upWorld, SIMD3<Double>(1, 0, 0)))
        )
        shipOrientation = orientationFromForwardUp(forward: horiz, up: upWorld)
        angularVelYaw = 0
        angularVelPitch = 0
        orbitYaw = 0
        orbitPitch = -0.16
        updateCameraMode()
    }

    func stepSimulation(currentTime: TimeInterval, renderer: SCNSceneRenderer) {
        if lastUpdateTime == 0 { lastUpdateTime = currentTime }
        let realDt = min(0.05, currentTime - lastUpdateTime)
        lastUpdateTime = currentTime
        frameCounter += 1

        let timeDir: Double = isTimeReversed ? -1.0 : 1.0
        let warp = isTimePaused ? 0.0 : (timeWarpSteps[timeWarpIndex].mult * timeDir)
        let simDt = realDt * warp
        simulationTimeSeconds += simDt

        var cachedPositions: [String: SIMD3<Double>] = [:]
        cachedPositions.reserveCapacity(UniverseCatalog.bodies.count)

        var nearestBody: CelestialBody = UniverseCatalog.bodies[3]
        var nearestBodyPos = SIMD3<Double>.zero
        var nearestDistFromCenter = Double.greatestFiniteMagnitude
        var nearestSurfaceDist = Double.greatestFiniteMagnitude

        for body in UniverseCatalog.bodies {
            let bodyPos = body.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
            cachedPositions[body.id] = bodyPos
            let distCenter = simd_length(bodyPos - shipPositionMeters)
            if body.isGalaxy && distCenter < body.radiusMeters * 1.15 {
                continue
            }
            let surfDist = max(0.0, distCenter - body.radiusMeters)
            if surfDist < nearestSurfaceDist {
                nearestSurfaceDist = surfDist
                nearestDistFromCenter = distCenter
                nearestBody = body
                nearestBodyPos = bodyPos
            }
        }

        let (rawSpinNearest, _, invNearestRot) = planetSpinAndInvRot(for: nearestBody)
        if !nearestBody.isStar && nearestSurfaceDist < 240_000 {
            if lastTrackedBodyId == nearestBody.id {
                let orbitalDelta = nearestBodyPos - lastTrackedBodyPos
                let lockWeight = (landedState || walkingState || nearestSurfaceDist < 120_000.0)
                    ? 1.0
                    : max(0.0, min(1.0, (240_000.0 - nearestSurfaceDist) / 120_000.0))
                shipPositionMeters += orbitalDelta * lockWeight

                let dSpin = (rawSpinNearest - lastTrackedSpinAngle) * lockWeight
                if abs(dSpin) > 1e-12 {
                    let tiltQuat = simd_quatd(angle: nearestBody.axialTiltRad, axis: SIMD3<Double>(0, 0, 1))
                    let spinAxis = tiltQuat.act(SIMD3<Double>(0, 1, 0))
                    let spinDeltaQuat = simd_quatd(angle: dSpin, axis: spinAxis)
                    let rel = shipPositionMeters - nearestBodyPos
                    shipPositionMeters = nearestBodyPos + spinDeltaQuat.act(rel)
                    if !walkingState {
                        shipOrientation = simd_normalize(spinDeltaQuat * shipOrientation)
                    }
                }
            }
            lastTrackedBodyId = nearestBody.id
            lastTrackedBodyPos = nearestBodyPos
            lastTrackedSpinAngle = rawSpinNearest
        } else {
            lastTrackedBodyId = nil
        }

        var lastSampleIsWater = false
        let curNearestRot = planetRot(for: nearestBody)
        var upWorld = safeNormalize(shipPositionMeters - nearestBodyPos, fallback: SIMD3<Double>(0, 1, 0))
        if nearestBody.isLandable && nearestSurfaceDist < 350_000 {
            let ground = groundSampleAt(
                worldPos: shipPositionMeters,
                body: nearestBody,
                bodyPos: nearestBodyPos,
                planetRot: curNearestRot,
                invPlanetRot: invNearestRot
            )
            lastSampleIsWater = ground.isWater
            currentGroundHeightMeters = ground.height
        } else {
            currentGroundHeightMeters = 0.0
        }

        let preRadarAlt = max(0.0, nearestSurfaceDist - currentGroundHeightMeters)
        let autoMaxSpeedMps: Double
        if nearestBody.isLandable && preRadarAlt < 2_000 {
            autoMaxSpeedMps = max(8.0, preRadarAlt * 0.40)
        } else {
            autoMaxSpeedMps = max(50.0, max(10.0, nearestSurfaceDist) * 0.45)
        }
        let effectiveMaxSpeed = autoSpeed ? autoMaxSpeedMps : speedSteps[speedIndex].mps

        var exhaustJetpackFuel = false
        if walkingState {
            let curPlanetRot = planetRot(for: nearestBody)
            let refWorld = curPlanetRot.act(evaRefForwardLocal)
            let refProj = refWorld - upWorld * simd_dot(refWorld, upWorld)
            let curRefFwd = safeNormalize(refProj, fallback: safeNormalize(simd_cross(upWorld, SIMD3<Double>(1, 0, 0))))
            let qYaw = simd_quatd(angle: evaYaw, axis: upWorld)
            let walkFwd = safeNormalize(qYaw.act(curRefFwd))
            let walkRight = safeNormalize(simd_cross(walkFwd, upWorld), fallback: SIMD3<Double>(1, 0, 0))

            let moveFwd = -Double(stickInput.y)
            let moveRight = Double(stickInput.x)
            let moveSpeed = evaSprinting ? 14.0 : 5.8
            let horizVel = (walkFwd * moveFwd + walkRight * moveRight) * moveSpeed
            shipPositionMeters += horizVel * realDt

            let gSurface = max(0.25, nearestBody.surfaceGravityG * 9.80665)
            if evaJetpackActive && jetpackFuelState > 0.01 {
                let thrust = gSurface + 9.5
                evaVerticalVel = min(22.0, evaVerticalVel + thrust * realDt)
                jetpackFuelState = max(0.0, jetpackFuelState - realDt * 0.28)
                if jetpackFuelState <= 0.01 {
                    exhaustJetpackFuel = true
                }
            } else {
                evaVerticalVel -= gSurface * realDt
                if evaHeightAboveGround <= 1.86 {
                    jetpackFuelState = min(1.0, jetpackFuelState + realDt * 0.35)
                }
            }

            evaHeightAboveGround += evaVerticalVel * realDt
            if evaHeightAboveGround <= 1.85 {
                evaHeightAboveGround = 1.85
                evaVerticalVel = 0.0
            } else if evaHeightAboveGround > 450.0 {
                evaHeightAboveGround = 450.0
                evaVerticalVel = min(0.0, evaVerticalVel)
            }

            upWorld = safeNormalize(shipPositionMeters - nearestBodyPos, fallback: SIMD3<Double>(0, 1, 0))
            let ground = groundSampleAt(
                worldPos: shipPositionMeters,
                body: nearestBody,
                bodyPos: nearestBodyPos,
                planetRot: curPlanetRot,
                invPlanetRot: invNearestRot
            )
            lastSampleIsWater = ground.isWater
            let effectiveGround = ground.height
            currentGroundHeightMeters = effectiveGround

            let horizSpeed = simd_length(horizVel)
            if horizSpeed > 0.3 && evaHeightAboveGround <= 1.86 {
                evaWalkPhase += realDt * (evaSprinting ? 14.0 : 9.5)
            } else {
                evaWalkPhase = 0.0
            }
            let bob = (horizSpeed > 0.3 && evaHeightAboveGround <= 1.86) ? (sin(evaWalkPhase) * (evaSprinting ? 0.11 : 0.07)) : 0.0

            shipPositionMeters = nearestBodyPos + upWorld * (nearestBody.radiusMeters + effectiveGround + evaHeightAboveGround + bob)
            shipVelocityMetersPerSec = horizVel + upWorld * evaVerticalVel

            let qPitch = simd_quatd(angle: evaPitch, axis: walkRight)
            let camFwd = safeNormalize(qPitch.act(walkFwd))
            let camUp = safeNormalize(qPitch.act(upWorld))
            shipOrientation = orientationFromForwardUp(forward: camFwd, up: camUp)
            shipVisualNode.eulerAngles = SCNVector3(0, 0, 0)
        } else if landedState {
            let wantsTakeoff = throttle > 0.15 || (isFreeCamera && (abs(stickInput.x) > 0.1 || abs(stickInput.y) > 0.1))
            if wantsTakeoff {
                landedState = false
                shipVelocityMetersPerSec = upWorld * (isFreeCamera ? 25.0 : 55.0)
                shipPositionMeters += upWorld * 4.0
            } else {
                shipVelocityMetersPerSec = .zero
                angularVelYaw = 0
                angularVelPitch = 0
                if !isFreeCamera {
                    let targetYawRate = -Double(stickInput.x) * 0.9
                    if abs(targetYawRate) > 0.01 {
                        let qYaw = simd_quatd(angle: targetYawRate * realDt, axis: upWorld)
                        shipOrientation = simd_normalize(qYaw * shipOrientation)
                    }
                    let curFwd = shipOrientation.act(SIMD3<Double>(0, 0, -1))
                    let horizFwd = safeNormalize(
                        curFwd - upWorld * simd_dot(curFwd, upWorld),
                        fallback: safeNormalize(simd_cross(upWorld, SIMD3<Double>(1, 0, 0)))
                    )
                    let flatOrient = orientationFromForwardUp(forward: horizFwd, up: upWorld)
                    shipOrientation = simd_slerp(shipOrientation, flatOrient, min(1.0, realDt * 6.0))

                    let targetStickX = Float(stickInput.y * 0.32)
                    let targetStickZ = Float(-stickInput.x * 0.32)
                    cockpitStickPivot.eulerAngles.x += (targetStickX - cockpitStickPivot.eulerAngles.x) * Float(min(1.0, realDt * 12.0))
                    cockpitStickPivot.eulerAngles.z += (targetStickZ - cockpitStickPivot.eulerAngles.z) * Float(min(1.0, realDt * 12.0))
                    let targetThrottleAngle = Float(0.35 - throttle * 0.78)
                    cockpitThrottlePivot.eulerAngles.x += (targetThrottleAngle - cockpitThrottlePivot.eulerAngles.x) * Float(min(1.0, realDt * 10.0))

                    cameraLagYaw += (0 - cameraLagYaw) * Float(min(1.0, realDt * 5.0))
                    cameraLagPitch += (0 - cameraLagPitch) * Float(min(1.0, realDt * 5.0))
                    if isThirdPerson {
                        cameraBoomNode.eulerAngles = SCNVector3(orbitPitch + cameraLagPitch, orbitYaw + cameraLagYaw, 0)
                    }
                }
                shipVisualNode.eulerAngles = SCNVector3(0, 0, 0)
            }
        }

        if !walkingState && !landedState {
            let forwardVec = shipOrientation.act(SIMD3<Double>(0, 0, -1))
            let rightVec = shipOrientation.act(SIMD3<Double>(1, 0, 0))

            if isFreeCamera {
                let moveForward = -Double(stickInput.y) + throttle
                let moveStrafe = Double(stickInput.x)
                let desiredVelocity = (forwardVec * moveForward + rightVec * moveStrafe) * effectiveMaxSpeed
                let response = min(1.0, realDt * 6.0)
                shipVelocityMetersPerSec += (desiredVelocity - shipVelocityMetersPerSec) * response

                shipVisualNode.eulerAngles = SCNVector3(0, 0, 0)
            } else {
                let targetYawRate = -Double(stickInput.x) * 1.45
                let targetPitchRate = -Double(stickInput.y) * 1.15
                let damp = min(1.0, realDt * 6.5)
                angularVelYaw += (targetYawRate - angularVelYaw) * damp
                angularVelPitch += (targetPitchRate - angularVelPitch) * damp

                if abs(angularVelYaw) > 0.0001 || abs(angularVelPitch) > 0.0001 {
                    let qYaw = simd_quatd(angle: angularVelYaw * realDt, axis: SIMD3(0, 1, 0))
                    let qPitch = simd_quatd(angle: angularVelPitch * realDt, axis: SIMD3(1, 0, 0))
                    shipOrientation = simd_normalize(shipOrientation * qYaw * qPitch)
                }

                let desiredBank = Float(angularVelYaw * 0.35)
                let desiredPitchVis = Float(angularVelPitch * 0.18)
                shipVisualNode.eulerAngles.z += (desiredBank - shipVisualNode.eulerAngles.z) * Float(min(1.0, realDt * 8.0))
                shipVisualNode.eulerAngles.x += (desiredPitchVis - shipVisualNode.eulerAngles.x) * Float(min(1.0, realDt * 8.0))

                let targetStickX = Float(stickInput.y * 0.32)
                let targetStickZ = Float(-stickInput.x * 0.32)
                cockpitStickPivot.eulerAngles.x += (targetStickX - cockpitStickPivot.eulerAngles.x) * Float(min(1.0, realDt * 12.0))
                cockpitStickPivot.eulerAngles.z += (targetStickZ - cockpitStickPivot.eulerAngles.z) * Float(min(1.0, realDt * 12.0))
                let targetThrottleAngle = Float(0.35 - throttle * 0.78)
                cockpitThrottlePivot.eulerAngles.x += (targetThrottleAngle - cockpitThrottlePivot.eulerAngles.x) * Float(min(1.0, realDt * 10.0))

                cameraLagYaw += (Float(-angularVelYaw * 0.14) - cameraLagYaw) * Float(min(1.0, realDt * 5.0))
                cameraLagPitch += (Float(-angularVelPitch * 0.10) - cameraLagPitch) * Float(min(1.0, realDt * 5.0))
                if isThirdPerson {
                    cameraBoomNode.eulerAngles = SCNVector3(orbitPitch + cameraLagPitch, orbitYaw + cameraLagYaw, 0)
                }

                let desiredVelocity = forwardVec * (effectiveMaxSpeed * throttle)
                if flightAssist {
                    let response = min(1.0, realDt * 3.5)
                    shipVelocityMetersPerSec += (desiredVelocity - shipVelocityMetersPerSec) * response
                } else {
                    if throttle > 0.001 {
                        shipVelocityMetersPerSec += forwardVec * (effectiveMaxSpeed * throttle * 0.25) * realDt
                    }
                    if !nearestBody.isStar && nearestSurfaceDist < 120_000 {
                        let gAccel = (CelestialBody.G * nearestBody.massKg) / max(1.0, nearestDistFromCenter * nearestDistFromCenter)
                        shipVelocityMetersPerSec -= upWorld * gAccel * realDt
                    }
                }
            }
        }

        let atmoH = nearestBody.atmosphereHeightMeters
        let preAtmoDensity: Double
        if atmoH > 0 && nearestSurfaceDist < atmoH {
            let hNorm = max(0.0, nearestSurfaceDist / atmoH)
            preAtmoDensity = exp(-hNorm * 3.8) * (1.0 - hNorm)
        } else {
            preAtmoDensity = 0.0
        }

        let preSpeed = simd_length(shipVelocityMetersPerSec)
        if !walkingState && !landedState && flightAssist && preAtmoDensity > 0.05 && preSpeed > 12_000.0 && !isFreeCamera {
            let drag = min(0.85, preAtmoDensity * realDt * 1.4)
            shipVelocityMetersPerSec *= (1.0 - drag)
        }

        let flightDt = (isTimePaused || isFreeCamera) ? realDt : (realDt * max(1.0, abs(warp)))
        if !walkingState && !landedState {
            shipPositionMeters += shipVelocityMetersPerSec * flightDt
        }

        if !walkingState && nearestBody.isLandable && nearestSurfaceDist < 350_000 {
            upWorld = safeNormalize(shipPositionMeters - nearestBodyPos, fallback: SIMD3<Double>(0, 1, 0))
            let ground = groundSampleAt(
                worldPos: shipPositionMeters,
                body: nearestBody,
                bodyPos: nearestBodyPos,
                planetRot: curNearestRot,
                invPlanetRot: invNearestRot
            )
            lastSampleIsWater = ground.isWater
            let effectiveGround = ground.height
            currentGroundHeightMeters = effectiveGround

            let hoverClearance = isFreeCamera ? 2.0 : 1.35
            let minDistFromCenter = nearestBody.radiusMeters + effectiveGround + hoverClearance
            let currentDist = simd_length(shipPositionMeters - nearestBodyPos)

            if currentDist <= minDistFromCenter {
                shipPositionMeters = nearestBodyPos + upWorld * minDistFromCenter
                let vRadial = simd_dot(shipVelocityMetersPerSec, upWorld)
                if vRadial < 0 {
                    shipVelocityMetersPerSec -= upWorld * vRadial
                }
                if !isFreeCamera && throttle < 0.15 && !ground.isWater {
                    landedState = true
                    shipVelocityMetersPerSec = .zero
                }
            }
        }

        var evaShipDistMeters = 0.0
        if walkingState, let pid = parkedShipBodyId, let pBody = UniverseCatalog.bodies.first(where: { $0.id == pid }) {
            let bPos = cachedPositions[pid] ?? pBody.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
            let bRot = planetRot(for: pBody)
            let shipWorldPos = bPos + bRot.act(parkedShipLocalPos)
            let rel = shipWorldPos - shipPositionMeters
            evaShipDistMeters = simd_length(rel)
            parkedShipNode.simdPosition = SIMD3<Float>(Float(rel.x), Float(rel.y), Float(rel.z))
            let shipWorldOrient = simd_normalize(bRot * parkedShipLocalOrient)
            parkedShipNode.simdOrientation = simd_quatf(
                ix: Float(shipWorldOrient.imag.x),
                iy: Float(shipWorldOrient.imag.y),
                iz: Float(shipWorldOrient.imag.z),
                r: Float(shipWorldOrient.real)
            )
        }

        shipNode.simdOrientation = simd_quatf(
            ix: Float(shipOrientation.imag.x),
            iy: Float(shipOrientation.imag.y),
            iz: Float(shipOrientation.imag.z),
            r: Float(shipOrientation.real)
        )

        let actualSpeed = simd_length(shipVelocityMetersPerSec)
        let updatedSurfaceDist = max(0.0, simd_length(shipPositionMeters - nearestBodyPos) - nearestBody.radiusMeters)
        let radarAlt = max(0.0, updatedSurfaceDist - currentGroundHeightMeters)
        upWorld = safeNormalize(shipPositionMeters - nearestBodyPos, fallback: SIMD3<Double>(0, 1, 0))

        landingGearNode.isHidden = !(nearestBody.isLandable && (radarAlt < 180.0 || landedState || walkingState))

        let atmoDensity: Double
        if atmoH > 0 && updatedSurfaceDist < atmoH {
            let hNorm = max(0.0, updatedSurfaceDist / atmoH)
            atmoDensity = exp(-hNorm * 3.8) * (1.0 - hNorm)
        } else {
            atmoDensity = 0.0
        }
        let heatValue = (!walkingState && atmoDensity > 0.03 && actualSpeed > 2_500.0)
            ? min(1.0, atmoDensity * ((actualSpeed - 2_500.0) / 8_000.0))
            : 0.0

        if actualSpeed > 1.0 && !walkingState {
            let velDir = simd_normalize(shipVelocityMetersPerSec)
            let dustSpeed = Float(min(85.0, log10(actualSpeed + 1.0) * 14.0))
            let move = SIMD3<Float>(Float(-velDir.x), Float(-velDir.y), Float(-velDir.z)) * dustSpeed * Float(realDt)
            for i in 0..<dustParticles.count {
                var p = dustParticles[i].offset + move
                if p.x > 45 { p.x -= 90 } else if p.x < -45 { p.x += 90 }
                if p.y > 45 { p.y -= 90 } else if p.y < -45 { p.y += 90 }
                if p.z > 45 { p.z -= 90 } else if p.z < -45 { p.z += 90 }
                dustParticles[i].offset = p
                dustParticles[i].node.simdPosition = p
            }
        }

        let flameScale = Float(max(0.05, throttle * (1.0 + Double(speedIndex) * 0.22)))
        for fNode in exhaustNodes {
            fNode.scale = SCNVector3(1.0, flameScale, 1.0)
            fNode.isHidden = throttle <= 0.01 || isFreeCamera || landedState || walkingState
        }

        let sunDirWorld = safeNormalize(-shipPositionMeters, fallback: SIMD3<Double>(1, 0, 0))
        let lookTarget = SIMD3<Float>(Float(-sunDirWorld.x), Float(-sunDirWorld.y), Float(-sunDirWorld.z))
        sunLightNode.simdLook(at: lookTarget, up: SIMD3<Float>(0, 1, 0), localFront: SIMD3<Float>(0, 0, -1))

        let camWorldQuat = cameraNode.simdWorldOrientation
        let invCamQuat = simd_inverse(camWorldQuat)

        let terrainVisible = nearestBody.isLandable && updatedSurfaceDist < 240_000
        if terrainVisible {
            let curPlanetRot = planetRot(for: nearestBody)
            let currentAnchorWorld = nearestBodyPos + curPlanetRot.act(lastTerrainAnchorLocal)
            let movedFromAnchor = (lastTerrainAltitude >= 0)
                ? simd_length(shipPositionMeters - currentAnchorWorld)
                : Double.greatestFiniteMagnitude
            let wantProps = updatedSurfaceDist < 2_500.0
            let moveLimit = walkingState ? 70.0 : (wantProps ? 220.0 : max(1_200.0, updatedSurfaceDist * 0.25))
            let needsRebuild = (activeSurfaceBodyId != nearestBody.id)
                || (lastTerrainAltitude < 0)
                || (abs(updatedSurfaceDist - lastTerrainAltitude) > max(400.0, lastTerrainAltitude * 0.25))
                || (movedFromAnchor > moveLimit)
                || (wantProps && !hasPropsForCurrentAnchor)

            if needsRebuild {
                let res = SurfaceTerrainEngine.buildTerrainGeometry(
                    body: nearestBody,
                    bodyPos: nearestBodyPos,
                    anchorWorld: shipPositionMeters,
                    planetRot: curPlanetRot,
                    invPlanetRot: invNearestRot,
                    altitudeMeters: max(50.0, updatedSurfaceDist),
                    whitePixel: whitePixel,
                    compress: { [self] rel in self.compressToScene(rel) }
                )
                terrainMeshNode.geometry = res.terrain
                oceanMeshNode.geometry = res.ocean
                oceanMeshNode.isHidden = (res.ocean == nil)
                activeTerrainCollision = res.collision
                activeSurfaceBodyId = nearestBody.id
                lastTerrainAnchorLocal = invNearestRot.act(shipPositionMeters - nearestBodyPos)
                lastTerrainBuildPlanetRot = curPlanetRot
                lastTerrainAltitude = updatedSurfaceDist

                for child in surfacePropsNode.childNodes {
                    child.removeFromParentNode()
                }
                if wantProps {
                    let clearPos: SIMD3<Double>?
                    if walkingState, let pid = parkedShipBodyId, pid == nearestBody.id {
                        clearPos = nearestBodyPos + curPlanetRot.act(parkedShipLocalPos)
                    } else if landedState {
                        clearPos = shipPositionMeters
                    } else {
                        clearPos = nil
                    }
                    let builtProps = SurfaceTerrainEngine.buildSurfaceProps(
                        body: nearestBody,
                        bodyPos: nearestBodyPos,
                        anchorWorld: shipPositionMeters,
                        planetRot: curPlanetRot,
                        invPlanetRot: invNearestRot,
                        clearCenterWorld: clearPos,
                        collisionGrid: res.collision
                    )
                    for child in builtProps.childNodes {
                        surfacePropsNode.addChildNode(child)
                    }
                    surfacePropsNode.isHidden = false
                    hasPropsForCurrentAnchor = true
                } else {
                    surfacePropsNode.isHidden = true
                    hasPropsForCurrentAnchor = false
                }
            } else {
                surfacePropsNode.isHidden = !wantProps
                if !wantProps {
                    hasPropsForCurrentAnchor = false
                }
            }

            let anchorWorldNow = nearestBodyPos + curPlanetRot.act(lastTerrainAnchorLocal)
            terrainRootNode.isHidden = false
            terrainRootNode.simdPosition = SIMD3<Float>(
                Float(anchorWorldNow.x - shipPositionMeters.x),
                Float(anchorWorldNow.y - shipPositionMeters.y),
                Float(anchorWorldNow.z - shipPositionMeters.z)
            )
            let deltaRot = simd_normalize(curPlanetRot * simd_inverse(lastTerrainBuildPlanetRot))
            terrainRootNode.simdOrientation = simd_quatf(
                ix: Float(deltaRot.imag.x),
                iy: Float(deltaRot.imag.y),
                iz: Float(deltaRot.imag.z),
                r: Float(deltaRot.real)
            )
            terrainRootNode.opacity = CGFloat(max(0.0, min(1.0, (240_000.0 - updatedSurfaceDist) / 100_000.0)))
        } else {
            terrainRootNode.isHidden = true
            surfacePropsNode.isHidden = true
            hasPropsForCurrentAnchor = false
            activeTerrainCollision = nil
            activeSurfaceBodyId = nil
            lastTerrainAltitude = -1
        }

        if atmoH > 0 && atmoDensity > 0.002 {
            skyDomeNode.isHidden = false
            let pal = nearestBody.atmospherePalette
            let toSunBody = safeNormalize(-nearestBodyPos, fallback: SIMD3<Double>(1, 0, 0))
            let sunElev = max(-1.0, min(1.0, simd_dot(toSunBody, upWorld)))
            let dayFactor = max(0.0, min(1.0, (sunElev + 0.22) / 0.40))

            let eastWorld = safeNormalize(
                simd_cross(upWorld, SIMD3<Double>(0, 1, 0)),
                fallback: SIMD3<Double>(1, 0, 0)
            )
            let sunView = invCamQuat.act(SIMD3<Float>(Float(toSunBody.x), Float(toSunBody.y), Float(toSunBody.z)))
            let upView = invCamQuat.act(SIMD3<Float>(Float(upWorld.x), Float(upWorld.y), Float(upWorld.z)))
            let eastView = invCamQuat.act(SIMD3<Float>(Float(eastWorld.x), Float(eastWorld.y), Float(eastWorld.z)))

            skyDomeMaterial?.setValue(NSValue(scnVector3: SCNVector3(sunView.x, sunView.y, sunView.z)), forKey: "sunDirView")
            skyDomeMaterial?.setValue(NSValue(scnVector3: SCNVector3(upView.x, upView.y, upView.z)), forKey: "upDirView")
            skyDomeMaterial?.setValue(NSValue(scnVector3: SCNVector3(eastView.x, eastView.y, eastView.z)), forKey: "eastDirView")
            skyDomeMaterial?.setValue(NSValue(scnVector3: SCNVector3(pal.zenith.x, pal.zenith.y, pal.zenith.z)), forKey: "zenithCol")
            skyDomeMaterial?.setValue(NSValue(scnVector3: SCNVector3(pal.horizon.x, pal.horizon.y, pal.horizon.z)), forKey: "horizonCol")
            skyDomeMaterial?.setValue(NSValue(scnVector3: SCNVector3(pal.sunset.x, pal.sunset.y, pal.sunset.z)), forKey: "sunsetCol")
            skyDomeMaterial?.setValue(NSNumber(value: Float(atmoDensity)), forKey: "atmoDensity")
            skyDomeMaterial?.setValue(NSNumber(value: Float(nearestBody.cloudCoverage)), forKey: "cloudAmount")

            let fogBrightness = CGFloat(0.12 + 0.88 * dayFactor)
            let twilightMix = Float(exp(-pow((sunElev + 0.02) * 5.0, 2.0))) * 0.45
            let fogVec = (pal.fog + (pal.sunset - pal.fog) * twilightMix) * 0.82
            scene.fogColor = UIColor(
                red: CGFloat(fogVec.x) * fogBrightness,
                green: CGFloat(fogVec.y) * fogBrightness,
                blue: CGFloat(fogVec.z) * fogBrightness,
                alpha: 1.0
            )
            let fogDensity = max(0.02, atmoDensity)
            scene.fogStartDistance = CGFloat(max(12_000.0, 26_000.0 / fogDensity))
            scene.fogEndDistance = CGFloat(max(85_000.0, 260_000.0 / fogDensity))

            ambientLightNode.light?.intensity = 38.0 + CGFloat(atmoDensity * dayFactor * 95.0)
        } else {
            skyDomeNode.isHidden = true
            scene.fogEndDistance = 0
            ambientLightNode.light?.intensity = (nearestBody.isLandable && updatedSurfaceDist < 240_000) ? 42.0 : 22.0
        }

        var prioritizedMarkers: [BodyScreenMarker] = []
        var otherMarkers: [(dist: Double, marker: BodyScreenMarker)] = []
        let viewBounds = (renderer as? SCNView)?.bounds ?? CGRect(x: 0, y: 0, width: 844, height: 390)

        for body in UniverseCatalog.bodies {
            guard let node = bodyNodes[body.id] else { continue }
            let bodyPos = cachedPositions[body.id] ?? body.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
            let rel = bodyPos - shipPositionMeters
            let distRel = simd_length(rel)
            if body.isGalaxy && distRel < body.radiusMeters * 1.05 {
                node.isHidden = true
                continue
            }
            node.isHidden = false

            let (renderPos, scaleFactor) = compressToScene(rel)
            let renderRadius = max(0.35, body.radiusMeters * scaleFactor)

            node.simdPosition = renderPos
            node.simdScale = SIMD3<Float>(repeating: Float(renderRadius))

            var spinAngle: Float = 0
            if body.rotationPeriodSeconds != 0, let mesh = planetMeshNodes[body.id] {
                let spin = (2.0 * .pi / body.rotationPeriodSeconds) * simulationTimeSeconds
                spinAngle = Float(spin.truncatingRemainder(dividingBy: 2.0 * .pi))
                mesh.eulerAngles.y = spinAngle
            }

            if terrainVisible && body.id == nearestBody.id {
                let orbitFade = CGFloat(max(0.0, min(1.0, (updatedSurfaceDist - 100_000.0) / 60_000.0)))
                let hideOrbitShell = updatedSurfaceDist <= 100_000.0
                planetMeshNodes[body.id]?.opacity = orbitFade
                planetMeshNodes[body.id]?.isHidden = hideOrbitShell
                atmoNodes[body.id]?.opacity = orbitFade
                atmoNodes[body.id]?.isHidden = hideOrbitShell
            } else {
                planetMeshNodes[body.id]?.opacity = 1.0
                planetMeshNodes[body.id]?.isHidden = false
                atmoNodes[body.id]?.opacity = 1.0
                atmoNodes[body.id]?.isHidden = false
            }

            if !body.isStar && !body.isGalaxy && !body.isBlackHole {
                let toSunWorld = safeNormalize(-bodyPos, fallback: SIMD3<Double>(1, 0, 0))
                let toSunF = SIMD3<Float>(Float(toSunWorld.x), Float(toSunWorld.y), Float(toSunWorld.z))

                let invTilt = simd_quatf(angle: -Float(body.axialTiltRad), axis: SIMD3<Float>(0, 0, 1))
                let invSpin = simd_quatf(angle: -spinAngle, axis: SIMD3<Float>(0, 1, 0))
                let sunLocal = (invSpin * invTilt).act(toSunF)
                planetMaterials[body.id]?.setValue(NSValue(scnVector3: SCNVector3(sunLocal.x, sunLocal.y, sunLocal.z)), forKey: "sunDirLocal")

                let sunView = invCamQuat.act(toSunF)
                atmoMaterials[body.id]?.setValue(NSValue(scnVector3: SCNVector3(sunView.x, sunView.y, sunView.z)), forKey: "sunDirView")
            }

            let hideSurfaceMarker = terrainVisible && body.id == nearestBody.id && updatedSurfaceDist < 100_000.0
            if showMarkers && !hideSurfaceMarker {
                let projected = renderer.projectPoint(node.position)
                if projected.z > 0.0 && projected.z < 1.0 {
                    let px = CGFloat(projected.x)
                    let py = CGFloat(projected.y)
                    if px >= 16 && px <= viewBounds.width - 16 && py >= 46 && py <= viewBounds.height - 64 {
                        let col: Color
                        if body.id == targetBody.id {
                            col = .cyan
                        } else if body.isBlackHole {
                            col = .purple
                        } else if body.isGalaxy {
                            col = .orange
                        } else if body.isStar {
                            col = .yellow
                        } else {
                            col = .white
                        }
                        let marker = BodyScreenMarker(
                            id: body.id,
                            name: body.name,
                            x: px,
                            y: py,
                            color: col,
                            isTarget: body.id == targetBody.id,
                            isStar: body.isStar
                        )
                        if body.id == targetBody.id || body.id == "sun" {
                            prioritizedMarkers.append(marker)
                        } else {
                            otherMarkers.append((dist: distRel, marker: marker))
                        }
                    }
                }
            }
        }
        otherMarkers.sort { $0.dist < $1.dist }
        let remainingMarkers = max(0, 18 - prioritizedMarkers.count)
        let newMarkers = prioritizedMarkers + otherMarkers.prefix(remainingMarkers).map { $0.marker }

        if frameCounter % 2 == 0 {
            updateOrbitLines()
        }

        let targetPos = cachedPositions[targetBody.id] ?? targetBody.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
        let surfaceDist = max(0, simd_length(targetPos - shipPositionMeters) - targetBody.radiusMeters)
        let currentDateStr = Self.dateFormatter.string(from: baseEpochDate.addingTimeInterval(simulationTimeSeconds))
        let autoSpeedStr = Self.formatSpeed(autoMaxSpeedMps)

        let nearSurface = (nearestBody.isLandable && updatedSurfaceDist < 240_000) || (atmoH > 0 && updatedSurfaceDist < atmoH)
        let zoneStr: String
        if walkingState {
            zoneStr = "ПРОГУЛКА"
        } else if landedState {
            zoneStr = "ПОСАДКА"
        } else if atmoH > 0 && updatedSurfaceDist < atmoH {
            zoneStr = "АТМОСФЕРА"
        } else if nearestBody.isLandable && updatedSurfaceDist < 240_000 {
            zoneStr = "СНИЖЕНИЕ"
        } else {
            zoneStr = ""
        }

        let altStr: String
        if walkingState {
            altStr = String(format: "ГРАВ: %.2f g", nearestBody.surfaceGravityG)
        } else if landedState {
            altStr = "НА ПОВЕРХНОСТИ"
        } else if radarAlt < 1_000 {
            altStr = String(format: "ВЫС: %.0f м", radarAlt)
        } else {
            altStr = String(format: "ВЫС: %.1f км", radarAlt / 1_000.0)
        }

        let currentWalking = walkingState
        let currentLanded = landedState
        let currentCanLand = targetBody.isLandable
        let currentOverWater = lastSampleIsWater
        let autoLandReady = !landedState && !walkingState && !isFreeCamera && nearestBody.isLandable && radarAlt < 1_800.0 && !currentOverWater
        let currentFuel = jetpackFuelState
        let evaShipDistStr = Self.formatDistance(evaShipDistMeters)
        let evaTempStr = "\(nearestBody.meanTempC) °C"
        let didExhaustJetpack = exhaustJetpackFuel

        DispatchQueue.main.async {
            self.distanceText = Self.formatDistance(surfaceDist)
            self.speedText = Self.formatSpeed(actualSpeed)
            self.autoSpeedLabel = autoSpeedStr
            self.etaText = actualSpeed > 1.0 ? Self.formatTime(surfaceDist / actualSpeed) : "Стоп"
            self.simDateText = currentDateStr
            self.screenMarkers = self.showMarkers ? newMarkers : []
            self.isLanded = currentLanded
            self.isWalkingOnSurface = currentWalking
            self.isOverWater = currentOverWater
            self.canAutoLand = autoLandReady
            self.isNearSurface = nearSurface
            self.surfaceAltitudeText = altStr
            self.atmosphereZoneText = zoneStr
            self.reentryHeat = heatValue
            self.canLandOnTarget = currentCanLand
            self.evaJetpackFuel = currentFuel
            if didExhaustJetpack {
                self.evaJetpackActive = false
            }
            self.evaShipDistanceText = evaShipDistStr
            self.evaTempText = evaTempStr
        }
    }

    static func formatDistance(_ meters: Double) -> String {
        if meters < 1_000 { return String(format: "%.0f м", meters) }
        let km = meters / 1_000
        if km < 1_000 { return String(format: "%.1f км", km) }
        if km < 1_000_000 { return String(format: "%.1f тыс. км", km / 1_000) }
        let au = meters / UniverseCatalog.au
        if au < 10_000 { return String(format: "%.3f а.е.", au) }
        let ly = meters / UniverseCatalog.ly
        if ly < 1_000 { return String(format: "%.2f св. лет", ly) }
        if ly < 1_000_000 { return String(format: "%.1f тыс. св.л", ly / 1_000) }
        if ly < 1_000_000_000 { return String(format: "%.2f млн св.л", ly / 1_000_000) }
        return String(format: "%.2f млрд св.л", ly / 1_000_000_000)
    }

    static func formatSpeed(_ mps: Double) -> String {
        if mps < 1_000 { return String(format: "%.0f м/с", mps) }
        let kms = mps / 1_000
        if kms < 100_000 { return String(format: "%.1f км/с", kms) }
        let c = mps / 299_792_458.0
        if c < 10_000 { return String(format: "%.2f c", c) }
        let lys = mps / UniverseCatalog.ly
        if lys >= 1_000_000 { return String(format: "%.2f млн св.л/с", lys / 1_000_000) }
        if lys >= 1_000 { return String(format: "%.1f тыс. св.л/с", lys / 1_000) }
        if lys >= 0.01 { return String(format: "%.2f св.л/с", lys) }
        return String(format: "%.0f тыс. c", c / 1_000)
    }

    static func formatTime(_ sec: Double) -> String {
        if sec < 60 { return String(format: "%.0f сек", sec) }
        if sec < 3600 { return String(format: "%.1f мин", sec / 60) }
        if sec < 86400 { return String(format: "%.1f ч", sec / 3600) }
        return String(format: "%.1f дн.", sec / 86400)
    }

    private func uiColor(from hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    private func rgbComponents(_ hex: UInt32) -> (r: Float, g: Float, b: Float) {
        (
            Float((hex >> 16) & 0xFF) / 255.0,
            Float((hex >> 8) & 0xFF) / 255.0,
            Float(hex & 0xFF) / 255.0
        )
    }
}

struct VirtualFlightStick: View {
    var label: String = ""
    var onChange: (CGPoint) -> Void
    @State private var knobOffset: CGSize = .zero
    private let maxRadius: CGFloat = 38

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.45))
                .overlay(Circle().stroke(Color.cyan.opacity(0.45), lineWidth: 1.5))
                .frame(width: 96, height: 96)

            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                    .offset(y: -30)
            }

            Circle()
                .fill(Color.cyan.opacity(0.85))
                .frame(width: 34, height: 34)
                .offset(knobOffset)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    let dist = sqrt(dx * dx + dy * dy)
                    let clamped = min(dist, maxRadius)
                    let angle = atan2(dy, dx)
                    let ox = cos(angle) * clamped
                    let oy = sin(angle) * clamped
                    knobOffset = CGSize(width: ox, height: oy)
                    onChange(CGPoint(x: ox / maxRadius, y: oy / maxRadius))
                }
                .onEnded { _ in
                    knobOffset = .zero
                    onChange(.zero)
                }
        )
    }
}

struct SceneViewContainer: UIViewRepresentable {
    @ObservedObject var sim: SpaceSimulationController

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = sim.scene
        view.delegate = context.coordinator
        view.isPlaying = true
        view.preferredFramesPerSecond = 60
        view.antialiasingMode = .multisampling2X

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        view.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(sim: sim) }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let sim: SpaceSimulationController
        init(sim: SpaceSimulationController) { self.sim = sim }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            sim.stepSimulation(currentTime: time, renderer: renderer)
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let t = gesture.translation(in: gesture.view)
            sim.handleCameraOrbitDrag(dx: Double(t.x), dy: Double(t.y))
            gesture.setTranslation(.zero, in: gesture.view)
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if sim.isThirdPerson && !sim.isFreeCamera && !sim.isWalkingOnSurface {
                sim.orbitDistance = max(6.5, min(45.0, sim.orbitDistance / Float(gesture.scale)))
                sim.updateCameraMode()
                gesture.scale = 1.0
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var sim = SpaceSimulationController()
    @State private var showCatalog = false
    @State private var showInfo = false
    @State private var selectedCategory: BodyCategory = .all

    var body: some View {
        ZStack {
            SceneViewContainer(sim: sim)

            if sim.reentryHeat > 0.04 {
                ZStack {
                    RadialGradient(
                        colors: [
                            .clear,
                            Color.orange.opacity(0.22 * sim.reentryHeat),
                            Color.red.opacity(0.48 * sim.reentryHeat)
                        ],
                        center: .center,
                        startRadius: 120,
                        endRadius: 460
                    )
                    .ignoresSafeArea()

                    VStack {
                        Spacer()
                        Text("ВХОД В АТМОСФЕРУ")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Color.black.opacity(0.72))
                            .overlay(Capsule().stroke(Color.orange.opacity(0.75), lineWidth: 1))
                            .clipShape(Capsule())
                            .padding(.bottom, 108)
                    }
                }
                .allowsHitTesting(false)
            }

            if sim.showMarkers && !sim.isWalkingOnSurface {
                ForEach(sim.screenMarkers) { marker in
                    Button(action: {
                        if let found = UniverseCatalog.bodies.first(where: { $0.id == marker.id }) {
                            sim.targetBody = found
                        }
                    }) {
                        VStack(spacing: 2) {
                            Text(marker.name)
                                .font(.system(size: marker.isTarget ? 11 : 10, weight: marker.isTarget ? .bold : .medium, design: .monospaced))
                                .foregroundColor(marker.color)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.black.opacity(marker.isTarget ? 0.65 : 0.35))
                                .cornerRadius(4)

                            if marker.isTarget {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.cyan, lineWidth: 1.5)
                                    .frame(width: 22, height: 22)
                            } else {
                                Circle()
                                    .stroke(marker.color.opacity(0.65), lineWidth: 1)
                                    .frame(width: 10, height: 10)
                            }
                        }
                    }
                    .position(x: marker.x, y: marker.y)
                }
            }

            VStack {
                if sim.isWalkingOnSurface {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "airplane")
                                .foregroundColor(.cyan)
                            Text("КОРАБЛЬ • \(sim.evaShipDistanceText)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                            Text("ПОСАЖЕН")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.green)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.green.opacity(0.20))
                                .clipShape(Capsule())
                        }
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Color.black.opacity(0.76))
                        .overlay(Capsule().stroke(Color.cyan.opacity(0.45), lineWidth: 1))
                        .clipShape(Capsule())

                        Spacer()

                        Button(action: { sim.toggleSurfaceScanner() }) {
                            HStack(spacing: 5) {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                Text("СКАНЕР")
                            }
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(sim.evaScannerOpen ? Color.cyan.opacity(0.60) : Color.black.opacity(0.76))
                            .overlay(Capsule().stroke(Color.cyan.opacity(0.5), lineWidth: 1))
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)

                    if sim.evaScannerOpen, let report = sim.evaScanReport {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("СКАНЕР ПОВЕРХНОСТИ • \(report.planetName)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.cyan)
                                Spacer()
                                Button(action: { sim.toggleSurfaceScanner() }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                            }
                            Text("Биом: \(report.biomeName)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                                GridRow {
                                    Text("Высота:").foregroundColor(.gray)
                                    Text("\(report.elevationMeters) м").bold()
                                }
                                GridRow {
                                    Text("Гравитация:").foregroundColor(.gray)
                                    Text(String(format: "%.2f g (%.1f м/с²)", report.gravityG, report.gravityMps2)).bold()
                                }
                                GridRow {
                                    Text("Темп. / Атм.:").foregroundColor(.gray)
                                    Text("\(report.tempC) °C • \(report.atmosphereText)").bold()
                                }
                                GridRow {
                                    Text("Состав:").foregroundColor(.gray)
                                    Text(report.compositionText).bold()
                                }
                            }
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white)
                        }
                        .padding(10)
                        .frame(maxWidth: 380)
                        .background(Color.black.opacity(0.84))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cyan.opacity(0.45), lineWidth: 1))
                        .cornerRadius(12)
                        .padding(.top, 4)
                    }

                    Spacer()

                    HStack(alignment: .bottom, spacing: 10) {
                        VirtualFlightStick(label: sim.evaSprinting ? "СПРИНТ" : "ХОДЬБА") { pt in
                            sim.stickInput = pt
                        }

                        Spacer()

                        HStack(spacing: 6) {
                            Button(action: { sim.evaSprinting.toggle() }) {
                                Text("СПРИНТ")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 9).padding(.vertical, 7)
                                    .background(sim.evaSprinting ? Color.cyan.opacity(0.55) : Color.white.opacity(0.16))
                                    .clipShape(Capsule())
                            }

                            Button(action: {
                                if sim.evaJetpackFuel > 0.02 || sim.evaJetpackActive {
                                    sim.evaJetpackActive.toggle()
                                }
                            }) {
                                HStack(spacing: 5) {
                                    Text("РАНЕЦ \(Int(sim.evaJetpackFuel * 100))%")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Color.white.opacity(0.22))
                                            Capsule()
                                                .fill(sim.evaJetpackFuel > 0.25 ? Color.cyan : Color.red)
                                                .frame(width: max(2, geo.size.width * CGFloat(sim.evaJetpackFuel)))
                                        }
                                    }
                                    .frame(width: 28, height: 5)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 7)
                                .background(sim.evaJetpackActive ? Color.orange.opacity(0.78) : Color.white.opacity(0.16))
                                .clipShape(Capsule())
                            }

                            Button("ПРЫЖОК") {
                                sim.evaJump()
                            }
                            .font(.system(size: 10, weight: .bold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.orange.opacity(0.85))
                            .clipShape(Capsule())

                            Button("В КОРАБЛЬ") {
                                sim.boardShip()
                            }
                            .font(.system(size: 10, weight: .bold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.green.opacity(0.85))
                            .clipShape(Capsule())
                        }
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.black.opacity(0.76))
                        .overlay(Capsule().stroke(Color.cyan.opacity(0.35), lineWidth: 1))
                        .clipShape(Capsule())
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                } else {
                    HStack(spacing: 6) {
                        Button(action: { showCatalog.toggle(); showInfo = false }) {
                            HStack(spacing: 5) {
                                Image(systemName: "globe.americas.fill")
                                Text("\(sim.targetBody.name) • \(sim.distanceText)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.black.opacity(0.72))
                            .overlay(Capsule().stroke(Color.cyan.opacity(0.45), lineWidth: 1))
                            .clipShape(Capsule())
                        }

                        Button(action: { showInfo.toggle(); showCatalog = false }) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 14))
                                .padding(6)
                                .background(showInfo ? Color.cyan.opacity(0.45) : Color.black.opacity(0.72))
                                .clipShape(Circle())
                        }

                        Text("\(sim.speedText) • \(sim.etaText)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(Color.black.opacity(0.72))
                            .clipShape(Capsule())

                        Spacer()

                        Button(action: { sim.showOrbits.toggle() }) {
                            Text("Орбиты")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(sim.showOrbits ? Color.cyan.opacity(0.35) : Color.black.opacity(0.72))
                                .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
                                .clipShape(Capsule())
                        }

                        Button(action: { sim.showMarkers.toggle() }) {
                            Text("Метки")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(sim.showMarkers ? Color.cyan.opacity(0.35) : Color.black.opacity(0.72))
                                .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
                                .clipShape(Capsule())
                        }

                        Button("На цель") { sim.alignToTarget() }
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(Color.blue.opacity(0.82))
                            .clipShape(Capsule())

                        // Переключатель SpaceEngine: Свободная камера / Корабль
                        Button(action: { sim.toggleFreeCamera() }) {
                            Text(sim.isFreeCamera ? "Корабль" : "Камера")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(sim.isFreeCamera ? Color.orange.opacity(0.82) : Color.black.opacity(0.72))
                                .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                                .clipShape(Capsule())
                        }

                        if !sim.isFreeCamera {
                            Button(sim.isThirdPerson ? "1-е лицо" : "3-е лицо") {
                                sim.isThirdPerson.toggle()
                                sim.updateCameraMode()
                            }
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(Color.black.opacity(0.72))
                            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                            .clipShape(Capsule())
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)

                    if sim.isNearSurface {
                        HStack(spacing: 8) {
                            Text(sim.atmosphereZoneText)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(sim.isLanded ? .green : .orange)

                            Text(sim.surfaceAltitudeText)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)

                            if sim.isLanded {
                                Button("ВЫЙТИ") {
                                    sim.enterWalkingMode()
                                }
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Color.cyan.opacity(0.55))
                                .clipShape(Capsule())

                                Button("ВЗЛЁТ") {
                                    sim.takeoffFromSurface()
                                }
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Color.green.opacity(0.85))
                                .clipShape(Capsule())
                            } else {
                                if sim.canAutoLand {
                                    Button("ПОСАДИТЬ") {
                                        sim.landAtCurrentSpot()
                                    }
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(Color.green.opacity(0.85))
                                    .clipShape(Capsule())
                                }
                                if !sim.isFreeCamera {
                                    Button("ГОРИЗОНТ") {
                                        sim.levelToHorizon()
                                    }
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(Color.cyan.opacity(0.45))
                                    .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Color.black.opacity(0.72))
                        .overlay(Capsule().stroke(Color.cyan.opacity(0.4), lineWidth: 1))
                        .clipShape(Capsule())
                        .padding(.top, 2)
                    }

                    Spacer()

                    HStack(alignment: .bottom, spacing: 10) {
                        VirtualFlightStick(label: sim.isFreeCamera ? "WASD" : "РУЛЬ") { pt in
                            sim.stickInput = pt
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(sim.isFreeCamera ? "КРУИЗ: \(Int(sim.throttle * 100))%" : "ТЯГА: \(Int(sim.throttle * 100))%")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.cyan)
                                Spacer()
                                if !sim.isFreeCamera {
                                    Button(sim.flightAssist ? "FA: ON" : "ИНЕРЦИЯ") {
                                        sim.flightAssist.toggle()
                                    }
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(sim.flightAssist ? Color.green.opacity(0.35) : Color.orange.opacity(0.5))
                                    .cornerRadius(6)
                                }
                            }
                            Slider(value: $sim.throttle, in: 0...1)
                                .frame(width: 140)
                                .tint(.cyan)
                        }
                        .padding(8)
                        .background(Color.black.opacity(0.72))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.2), lineWidth: 1))
                        .cornerRadius(14)

                        Spacer()

                        VStack(alignment: .trailing, spacing: 5) {
                            HStack(spacing: 5) {
                                Text(sim.simDateText)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.85))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 4)

                                Button(action: { sim.isTimeReversed.toggle() }) {
                                    Image(systemName: sim.isTimeReversed ? "backward.fill" : "forward.fill")
                                        .font(.system(size: 10))
                                        .frame(width: 24, height: 24)
                                        .background(sim.isTimeReversed ? Color.orange.opacity(0.65) : Color.white.opacity(0.18))
                                        .clipShape(Circle())
                                }

                                Button(action: { sim.isTimePaused.toggle() }) {
                                    Image(systemName: sim.isTimePaused ? "play.fill" : "pause.fill")
                                        .font(.system(size: 10))
                                        .frame(width: 24, height: 24)
                                        .background(sim.isTimePaused ? Color.red.opacity(0.65) : Color.white.opacity(0.18))
                                        .clipShape(Circle())
                                }

                                Button(action: { sim.timeWarpIndex = max(0, sim.timeWarpIndex - 1) }) {
                                    Text("−")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 24, height: 24)
                                        .background(Color.white.opacity(0.18))
                                        .clipShape(Circle())
                                }

                                Text(sim.isTimePaused ? "ПАУЗА" : "\(sim.isTimeReversed ? "−" : "")\(sim.timeWarpSteps[sim.timeWarpIndex].label)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.yellow)
                                    .frame(minWidth: 46)

                                Button(action: { sim.timeWarpIndex = min(sim.timeWarpSteps.count - 1, sim.timeWarpIndex + 1) }) {
                                    Text("+")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 24, height: 24)
                                        .background(Color.white.opacity(0.18))
                                        .clipShape(Circle())
                                }
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 7).padding(.vertical, 5)
                            .background(Color.black.opacity(0.72))
                            .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                            .clipShape(Capsule())

                            HStack(spacing: 6) {
                                // Кнопка логарифмической авто-скорости SpaceEngine
                                Button(action: { sim.autoSpeed.toggle() }) {
                                    Text("АВТО")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .padding(.horizontal, 8).padding(.vertical, 6)
                                        .background(sim.autoSpeed ? Color.cyan.opacity(0.45) : Color.white.opacity(0.14))
                                        .clipShape(Capsule())
                                }

                                if !sim.autoSpeed {
                                    Button(action: { sim.speedIndex = max(0, sim.speedIndex - 1) }) {
                                        Text("−")
                                            .font(.system(size: 15, weight: .bold))
                                            .frame(width: 28, height: 28)
                                            .background(Color.white.opacity(0.18))
                                            .clipShape(Circle())
                                    }
                                }

                                Text(sim.autoSpeed ? sim.autoSpeedLabel : sim.speedSteps[sim.speedIndex].label)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(sim.autoSpeed ? .cyan : .white)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .frame(minWidth: 84)

                                if !sim.autoSpeed {
                                    Button(action: { sim.speedIndex = min(sim.speedSteps.count - 1, sim.speedIndex + 1) }) {
                                        Text("+")
                                            .font(.system(size: 15, weight: .bold))
                                            .frame(width: 28, height: 28)
                                            .background(Color.white.opacity(0.18))
                                            .clipShape(Circle())
                                    }
                                }

                                Button("СТОП") {
                                    sim.throttle = 0
                                    sim.shipVelocityMetersPerSec = .zero
                                }
                                .font(.system(size: 10, weight: .bold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.red.opacity(0.82))
                                .clipShape(Capsule())
                            }
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Color.black.opacity(0.72))
                            .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }

            if showInfo && !sim.isWalkingOnSurface {
                let b = sim.targetBody
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.name).font(.headline)
                            Text(b.type).font(.caption).foregroundColor(.cyan)
                        }
                        Spacer()
                        Button("Закрыть") { showInfo = false }
                            .font(.caption.bold())
                    }
                    Divider().background(Color.white.opacity(0.2))
                    Text(b.summary).font(.caption2).foregroundColor(.white.opacity(0.85))

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text("Радиус:").foregroundColor(.gray)
                            Text(b.radiusMeters >= 0.01 * UniverseCatalog.ly
                                 ? SpaceSimulationController.formatDistance(b.radiusMeters)
                                 : String(format: "%.0f км", b.radiusMeters / 1_000)).bold()
                        }
                        GridRow {
                            Text("Гравитация:").foregroundColor(.gray)
                            Text(String(format: "%.2f g", b.surfaceGravityG)).bold()
                        }
                        GridRow {
                            Text("1-я / 2-я косм.:").foregroundColor(.gray)
                            Text(String(format: "%.1f / %.1f км/с", b.firstCosmicVelocityMps / 1_000, b.escapeVelocityMps / 1_000)).bold()
                        }
                        GridRow {
                            Text("Температура:").foregroundColor(.gray)
                            Text(b.meanTempK > 0 ? "\(b.meanTempC) °C (\(b.meanTempK) K)" : "Горизонт событий").bold()
                        }
                        GridRow {
                            Text("Наклон оси:").foregroundColor(.gray)
                            Text(String(format: "%.1f°", b.axialTiltRad * 180.0 / .pi)).bold()
                        }
                        if b.orbitalPeriodSeconds > 0 {
                            let days = b.orbitalPeriodSeconds / 86_400
                            GridRow {
                                Text("Год на орбите:").foregroundColor(.gray)
                                Text(days > 3_650
                                     ? String(format: "%.1f земн. лет", days / 365.25)
                                     : String(format: "%.1f земн. дн.", days)).bold()
                            }
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))

                    HStack(spacing: 8) {
                        Button("Навести курс") {
                            sim.alignToTarget()
                            showInfo = false
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(8)

                        Button("Перелёт на орбиту") {
                            sim.warpToBody(b)
                            showInfo = false
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.blue)
                        .cornerRadius(8)

                        if b.isLandable {
                            Button("Посадка") {
                                sim.warpToSurfaceApproach(b)
                                showInfo = false
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Color.green.opacity(0.85))
                            .cornerRadius(8)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .font(.caption.bold())
                    .padding(.top, 4)
                }
                .foregroundColor(.white)
                .padding(14)
                .frame(maxWidth: 380)
                .background(Color.black.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.cyan.opacity(0.5), lineWidth: 1))
                .cornerRadius(16)
            }

            if showCatalog && !sim.isWalkingOnSurface {
                let filteredBodies = UniverseCatalog.bodies.filter {
                    selectedCategory == .all || $0.category == selectedCategory
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Астрономический каталог 1:1 (\(filteredBodies.count))")
                            .font(.headline)
                        Spacer()
                        Button("Закрыть") { showCatalog = false }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(BodyCategory.allCases) { cat in
                                Button(cat.rawValue) {
                                    selectedCategory = cat
                                }
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(selectedCategory == cat ? Color.cyan.opacity(0.55) : Color.white.opacity(0.12))
                                .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
                                .clipShape(Capsule())
                            }
                        }
                    }

                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(filteredBodies) { body in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(body.name).bold()
                                        Text(body.type).font(.caption).foregroundColor(.gray)
                                    }
                                    Spacer()
                                    Button("Курс") {
                                        sim.targetBody = body
                                        sim.alignToTarget()
                                        showCatalog = false
                                    }
                                    .font(.caption.bold())
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Color.white.opacity(0.15))
                                    .cornerRadius(8)

                                    Button("Перелёт") {
                                        sim.warpToBody(body)
                                        showCatalog = false
                                    }
                                    .font(.caption.bold())
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Color.blue)
                                    .cornerRadius(8)

                                    if body.isLandable {
                                        Button("Посадка") {
                                            sim.warpToSurfaceApproach(body)
                                            showCatalog = false
                                        }
                                        .font(.caption.bold())
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Color.green.opacity(0.85))
                                        .cornerRadius(8)
                                    }
                                }
                                .padding(8)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(10)
                            }
                        }
                    }
                }
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: 460, maxHeight: 300)
                .background(Color.black.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.cyan.opacity(0.4), lineWidth: 1))
                .cornerRadius(16)
            }
        }
    }
}