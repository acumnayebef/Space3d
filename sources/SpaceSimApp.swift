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
    let cockpitMeshNode = SCNNode()
    let cockpitStickPivot = SCNNode()
    let cockpitThrottlePivot = SCNNode()
    let cameraBoomNode = SCNNode()
    let cameraNode = SCNNode()
    let sunLightNode = SCNNode()
    let dustRootNode = SCNNode()
    let orbitLinesNode = SCNNode()

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
    @Published var throttle: Double = 0.0
    @Published var flightAssist: Bool = true
    @Published var targetBody: CelestialBody = UniverseCatalog.bodies[3]
    @Published var distanceText: String = "10.2 тыс. км"
    @Published var speedText: String = "0 м/с"
    @Published var etaText: String = "Стоп"
    @Published var simDateText: String = ""
    @Published var screenMarkers: [BodyScreenMarker] = []
    @Published var isThirdPerson: Bool = true

    let speedSteps: [(label: String, mps: Double)] = [
        ("1.5 км/с", 1_500),
        ("7.9 км/с (Орбита)", 7_900),
        ("11.2 км/с (2-я косм.)", 11_200),
        ("100 км/с", 100_000),
        ("10 000 км/с", 10_000_000),
        ("1 c", 299_792_458),
        ("100 c", 29_979_245_800),
        ("10 000 c", 2_997_924_580_000),
        ("500 000 c", 149_896_229_000_000)
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
    private var lastUpdateTime: TimeInterval = 0
    private var frameCounter: Int = 0

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
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        buildThirdPersonShip()
        buildFirstPersonCockpit()
        shipVisualNode.addChildNode(thirdPersonMeshNode)
        shipVisualNode.addChildNode(cockpitMeshNode)
        shipNode.addChildNode(shipVisualNode)
        scene.rootNode.addChildNode(shipNode)

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

            let sphere = SCNSphere(radius: 1.0)
            sphere.segmentCount = 144

            let mat = SCNMaterial()
            mat.diffuse.contents = whitePixel

            if body.id == "sgr_a" {
                mat.lightingModel = .constant
                mat.diffuse.contents = UIColor.black
                mat.shaderModifiers = [.fragment: """
                    float ndotv = clamp(abs(dot(normalize(_surface.normal), normalize(_surface.view))), 0.0, 1.0);
                    float photonRing = pow(1.0 - ndotv, 9.0) * 3.0;
                    _output.color = vec4(vec3(1.0, 0.72, 0.35) * photonRing, 1.0);
                """]
            } else if body.isStar {
                mat.lightingModel = .constant
                mat.shaderModifiers = [.surface: starShaderModifier(for: body)]

                let corona = SCNSphere(radius: 1.28)
                corona.segmentCount = 64
                let cMat = SCNMaterial()
                cMat.lightingModel = .constant
                cMat.blendMode = .add
                cMat.cullMode = .front
                cMat.writesToDepthBuffer = false
                let c = rgbComponents(body.colorHex)
                cMat.shaderModifiers = [.fragment: """
                    float ndotv = clamp(abs(dot(normalize(_surface.normal), normalize(_surface.view))), 0.0, 1.0);
                    float glow = pow(ndotv, 3.8) * 0.85;
                    _output.color = vec4(vec3(\(c.r), \(c.g), \(c.b)) * glow, glow);
                """]
                corona.materials = [cMat]
                root.addChildNode(SCNNode(geometry: corona))
            } else {
                mat.lightingModel = .physicallyBased
                mat.roughness.contents = body.id == "earth" ? 0.42 : 0.88
                mat.metalness.contents = 0.02
                mat.shaderModifiers = [.surface: planetShaderModifier(for: body)]
                mat.setValue(NSValue(scnVector3: SCNVector3(1, 0, 0)), forKey: "sunDirLocal")
                planetMaterials[body.id] = mat
            }

            sphere.materials = [mat]
            let meshNode = SCNNode(geometry: sphere)
            root.addChildNode(meshNode)
            planetMeshNodes[body.id] = meshNode

            if body.hasAtmosphere && !body.isStar {
                let atmoSphere = SCNSphere(radius: 1.055)
                atmoSphere.segmentCount = 96
                let atmoMat = SCNMaterial()
                atmoMat.lightingModel = .constant
                atmoMat.blendMode = .add
                atmoMat.cullMode = .front
                atmoMat.writesToDepthBuffer = false

                let dayCol: String
                let sunsetCol: String
                switch body.id {
                case "mars":
                    dayCol = "vec3(0.92, 0.48, 0.26)"
                    sunsetCol = "vec3(0.80, 0.25, 0.10)"
                case "venus":
                    dayCol = "vec3(0.95, 0.78, 0.48)"
                    sunsetCol = "vec3(0.90, 0.45, 0.18)"
                case "neptune", "uranus":
                    dayCol = "vec3(0.28, 0.72, 1.0)"
                    sunsetCol = "vec3(0.18, 0.45, 0.95)"
                default:
                    dayCol = "vec3(0.22, 0.58, 1.0)"
                    sunsetCol = "vec3(1.0, 0.44, 0.14)"
                }

                atmoMat.shaderModifiers = [.fragment: """
                    uniform vec3 sunDirView;
                    #pragma body
                    vec3 n = normalize(-_surface.normal);
                    vec3 v = normalize(_surface.view);
                    float ndotv = clamp(dot(n, v), 0.0, 1.0);
                    float halo = pow(ndotv, 3.2) * smoothstep(0.0, 0.35, 1.0 - ndotv);
                    float sunDot = dot(n, normalize(sunDirView));
                    float dayMask = smoothstep(-0.25, 0.32, sunDot);
                    float sunset = exp(-pow((sunDot + 0.04) * 4.5, 2.0));
                    vec3 col = mix(\(dayCol), \(sunsetCol), sunset * 0.65);
                    _output.color = vec4(col * halo * dayMask * 2.2, halo * dayMask);
                """]
                atmoMat.setValue(NSValue(scnVector3: SCNVector3(1, 0, 0)), forKey: "sunDirView")
                atmoMaterials[body.id] = atmoMat
                atmoSphere.materials = [atmoMat]
                root.addChildNode(SCNNode(geometry: atmoSphere))
            }

            if body.hasRings {
                let isBH = (body.id == "sgr_a")
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

    /// Преобразование 64-битных мировых координат в 3D-позицию сцены без Z-fighting
    private func compressToScene(_ relMeters: SIMD3<Double>) -> (pos: SIMD3<Float>, scaleFactor: Double) {
        let dist = simd_length(relMeters)
        let maxRenderDist = 420_000.0
        if dist <= maxRenderDist || dist < 1e-6 {
            return (SIMD3<Float>(Float(relMeters.x), Float(relMeters.y), Float(relMeters.z)), 1.0)
        }
        // Плавное логарифмическое смещение глубины, чтобы далёкие звёзды всегда были позади ближних планет
        let compressedDist = maxRenderDist * (1.0 + 0.045 * log10(dist / maxRenderDist))
        let scaleFactor = compressedDist / dist
        let rPos = relMeters * scaleFactor
        return (SIMD3<Float>(Float(rPos.x), Float(rPos.y), Float(rPos.z)), scaleFactor)
    }

    /// Обновление 3D-линий орбит всех планет и Луны в одном батче
    private func updateOrbitLines() {
        orbitLinesNode.isHidden = !showOrbits
        guard showOrbits else { return }

        var vertices: [SCNVector3] = []
        var indices: [Int32] = []
        let segments = 72
        vertices.reserveCapacity(10 * segments)
        indices.reserveCapacity(10 * segments * 2)

        for body in UniverseCatalog.bodies where body.semiMajorAxisMeters > 0 && body.orbitalPeriodSeconds > 0 {
            let parentPos: SIMD3<Double>
            if let pid = body.parentId, let parent = UniverseCatalog.bodies.first(where: { $0.id == pid }) {
                parentPos = parent.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
            } else {
                parentPos = .zero
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

        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [orbitLineMaterial]
        orbitLinesNode.geometry = geometry
    }

    private func planetShaderModifier(for body: CelestialBody) -> String {
        let mode: Int
        switch body.id {
        case "earth": mode = 1
        case "mars": mode = 2
        case "jupiter", "saturn", "uranus", "neptune": mode = 3
        default: mode = 4
        }

        let c1 = rgbComponents(body.colorHex)
        let c2 = rgbComponents(body.secondaryHex)

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
                albedo = mix(vec3(0.008, 0.04, 0.18), vec3(0.03, 0.26, 0.56), pow(depth, 2.2));
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

                if (h < 0.28 && lat < 0.68 && nightMask > 0.01) {
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
        } else {
            float crater = smoothstep(0.32, 0.68, detail);
            albedo = mix(col2, col1, smoothstep(0.22, 0.78, n));
            albedo *= (0.68 + ridge * 0.35 + crater * 0.22);
            bumpStrength = 18.0;
        }

        if (planetMode == 1 || planetMode == 2) {
            float ndotv = clamp(abs(dot(normalize(_surface.normal), normalize(_surface.view))), 0.0, 1.0);
            float fresnel = pow(1.0 - ndotv, 3.2) * smoothstep(-0.15, 0.35, sunDot);
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
        float limb = 0.35 + 0.65 * pow(ndotv, 0.55);

        vec3 hotCol = vec3(\(c1.r), \(c1.g), \(c1.b));
        vec3 coolCol = vec3(\(c2.r), \(c2.g), \(c2.b));
        vec3 starCol = mix(coolCol * 0.65, hotCol * 1.15, smoothstep(0.25, 0.85, plasma));
        starCol *= (0.35 + 0.65 * spots) * limb;

        _surface.diffuse = vec4(0.0, 0.0, 0.0, 1.0);
        _surface.emission = vec4(starCol, 1.0);
        """
    }

    private func buildThirdPersonShip() {
        let hullMat = SCNMaterial()
        hullMat.lightingModel = .physicallyBased
        hullMat.diffuse.contents = UIColor(red: 0.22, green: 0.27, blue: 0.35, alpha: 1.0)
        hullMat.metalness.contents = 0.78
        hullMat.roughness.contents = 0.30

        let accentMat = SCNMaterial()
        accentMat.lightingModel = .physicallyBased
        accentMat.diffuse.contents = UIColor(red: 0.92, green: 0.38, blue: 0.12, alpha: 1.0)

        let hull = SCNBox(width: 2.4, height: 0.65, length: 6.8, chamferRadius: 0.22)
        hull.materials = [hullMat]
        thirdPersonMeshNode.addChildNode(SCNNode(geometry: hull))

        let nose = SCNPyramid(width: 2.3, height: 2.6, length: 0.62)
        nose.materials = [hullMat]
        let noseNode = SCNNode(geometry: nose)
        noseNode.eulerAngles.x = -.pi / 2
        noseNode.position = SCNVector3(0, 0, -3.4)
        thirdPersonMeshNode.addChildNode(noseNode)

        let wings = SCNBox(width: 7.6, height: 0.14, length: 3.1, chamferRadius: 0.06)
        wings.materials = [hullMat]
        let wingsNode = SCNNode(geometry: wings)
        wingsNode.position = SCNVector3(0, -0.08, 1.2)
        thirdPersonMeshNode.addChildNode(wingsNode)

        let stripe = SCNBox(width: 7.7, height: 0.16, length: 0.45, chamferRadius: 0.04)
        stripe.materials = [accentMat]
        let stripeNode = SCNNode(geometry: stripe)
        stripeNode.position = SCNVector3(0, -0.08, 2.1)
        thirdPersonMeshNode.addChildNode(stripeNode)

        let canopy = SCNSphere(radius: 0.6)
        let glassMat = SCNMaterial()
        glassMat.lightingModel = .physicallyBased
        glassMat.diffuse.contents = UIColor(red: 0.06, green: 0.55, blue: 0.95, alpha: 0.9)
        glassMat.metalness.contents = 0.9
        glassMat.roughness.contents = 0.1
        canopy.materials = [glassMat]
        let canopyNode = SCNNode(geometry: canopy)
        canopyNode.scale = SCNVector3(1.05, 0.5, 2.0)
        canopyNode.position = SCNVector3(0, 0.36, -1.1)
        thirdPersonMeshNode.addChildNode(canopyNode)

        exhaustNodes.removeAll()
        for xOffset in [-0.85, 0.85] {
            let nozzle = SCNCylinder(radius: 0.28, height: 0.5)
            nozzle.materials = [hullMat]
            let nNode = SCNNode(geometry: nozzle)
            nNode.eulerAngles.x = .pi / 2
            nNode.position = SCNVector3(Float(xOffset), 0, 3.45)
            thirdPersonMeshNode.addChildNode(nNode)

            let flame = SCNCone(topRadius: 0.02, bottomRadius: 0.24, height: 2.2)
            let flameMat = SCNMaterial()
            flameMat.emission.contents = UIColor(red: 0.25, green: 0.82, blue: 1.0, alpha: 0.95)
            flameMat.blendMode = .add
            flame.materials = [flameMat]
            let fNode = SCNNode(geometry: flame)
            fNode.eulerAngles.x = .pi / 2
            fNode.position = SCNVector3(Float(xOffset), 0, 4.6)
            thirdPersonMeshNode.addChildNode(fNode)
            exhaustNodes.append(fNode)
        }
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

    func updateCameraMode() {
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
        if isThirdPerson {
            orbitYaw -= Float(dx * 0.006)
            orbitPitch = max(-1.35, min(1.35, orbitPitch - Float(dy * 0.006)))
            updateCameraMode()
        }
    }

    func alignToTarget() {
        let targetPos = targetBody.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
        let dir = simd_normalize(targetPos - shipPositionMeters)
        let forward = SIMD3<Double>(0, 0, -1)
        let dot = simd_dot(forward, dir)
        if dot < -0.9999 {
            shipOrientation = simd_quatd(angle: .pi, axis: SIMD3(0, 1, 0))
        } else {
            let axis = simd_normalize(simd_cross(forward, dir))
            shipOrientation = simd_quatd(angle: acos(max(-1.0, min(1.0, dot))), axis: axis)
        }
        orbitYaw = 0
        orbitPitch = -0.16
        angularVelYaw = 0
        angularVelPitch = 0
        updateCameraMode()
    }

    func warpToBody(_ body: CelestialBody) {
        targetBody = body
        throttle = 0
        shipVelocityMetersPerSec = .zero
        let bodyPos = body.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
        let orbitDist = body.radiusMeters * (body.id == "sgr_a" ? 5.8 : 2.9)

        let offsetDir: SIMD3<Double>
        if body.isStar || simd_length(bodyPos) < 1_000 {
            offsetDir = simd_normalize(SIMD3<Double>(0.6, 0.25, 0.75))
        } else {
            let toSun = simd_normalize(-bodyPos)
            let right = simd_normalize(simd_cross(SIMD3<Double>(0, 1, 0), toSun))
            offsetDir = simd_normalize(toSun * 0.74 + right * 0.62 + SIMD3<Double>(0, 0.20, 0))
        }

        shipPositionMeters = bodyPos + offsetDir * orbitDist
        alignToTarget()
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

        shipNode.simdOrientation = simd_quatf(
            ix: Float(shipOrientation.imag.x),
            iy: Float(shipOrientation.imag.y),
            iz: Float(shipOrientation.imag.z),
            r: Float(shipOrientation.real)
        )

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

        let targetSpeed = speedSteps[speedIndex].mps * throttle
        let forwardVec = shipOrientation.act(SIMD3<Double>(0, 0, -1))
        let desiredVelocity = forwardVec * targetSpeed

        if flightAssist {
            let response = min(1.0, realDt * 3.5)
            shipVelocityMetersPerSec += (desiredVelocity - shipVelocityMetersPerSec) * response
        } else if throttle > 0.001 {
            shipVelocityMetersPerSec += forwardVec * (speedSteps[speedIndex].mps * throttle * 0.25) * realDt
        }

        // Корабль может летать даже на паузе времени Вселенной (как свободный полёт в SpaceEngine)
        let flightDt = isTimePaused ? realDt : (realDt * max(1.0, abs(warp)))
        shipPositionMeters += shipVelocityMetersPerSec * flightDt
        let actualSpeed = simd_length(shipVelocityMetersPerSec)

        if actualSpeed > 1.0 {
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
            fNode.isHidden = throttle <= 0.01
        }

        let sunDirWorld = simd_normalize(-shipPositionMeters)
        let lookTarget = SIMD3<Float>(Float(-sunDirWorld.x), Float(-sunDirWorld.y), Float(-sunDirWorld.z))
        sunLightNode.simdLook(at: lookTarget, up: SIMD3<Float>(0, 1, 0), localFront: SIMD3<Float>(0, 0, -1))

        let camWorldQuat = cameraNode.simdWorldOrientation
        let invCamQuat = simd_inverse(camWorldQuat)

        var newMarkers: [BodyScreenMarker] = []
        let viewBounds = (renderer as? SCNView)?.bounds ?? CGRect(x: 0, y: 0, width: 844, height: 390)

        for body in UniverseCatalog.bodies {
            guard let node = bodyNodes[body.id] else { continue }
            let bodyPos = body.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
            let rel = bodyPos - shipPositionMeters
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

            if !body.isStar {
                let toSunWorld = simd_normalize(-bodyPos)
                let toSunF = SIMD3<Float>(Float(toSunWorld.x), Float(toSunWorld.y), Float(toSunWorld.z))

                let invTilt = simd_quatf(angle: -Float(body.axialTiltRad), axis: SIMD3<Float>(0, 0, 1))
                let invSpin = simd_quatf(angle: -spinAngle, axis: SIMD3<Float>(0, 1, 0))
                let sunLocal = (invSpin * invTilt).act(toSunF)
                planetMaterials[body.id]?.setValue(NSValue(scnVector3: SCNVector3(sunLocal.x, sunLocal.y, sunLocal.z)), forKey: "sunDirLocal")

                let sunView = invCamQuat.act(toSunF)
                atmoMaterials[body.id]?.setValue(NSValue(scnVector3: SCNVector3(sunView.x, sunView.y, sunView.z)), forKey: "sunDirView")
            }

            // Проецируем 3D-позицию тела на экран для интерактивной метки SpaceEngine
            if showMarkers {
                let projected = renderer.projectPoint(node.position)
                if projected.z > 0.0 && projected.z < 1.0 {
                    let px = CGFloat(projected.x)
                    let py = CGFloat(projected.y)
                    if px >= 16 && px <= viewBounds.width - 16 && py >= 46 && py <= viewBounds.height - 64 {
                        let col = body.isStar ? Color.yellow : (body.id == targetBody.id ? Color.cyan : Color.white)
                        newMarkers.append(BodyScreenMarker(
                            id: body.id,
                            name: body.name,
                            x: px,
                            y: py,
                            color: col,
                            isTarget: body.id == targetBody.id,
                            isStar: body.isStar
                        ))
                    }
                }
            }
        }

        // Обновляем 3D-линии орбит каждые 2 кадра (30 Гц — плавно и без нагрузки на батарею)
        if frameCounter % 2 == 0 {
            updateOrbitLines()
        }

        let targetPos = targetBody.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
        let surfaceDist = max(0, simd_length(targetPos - shipPositionMeters) - targetBody.radiusMeters)
        let currentDateStr = Self.dateFormatter.string(from: baseEpochDate.addingTimeInterval(simulationTimeSeconds))

        DispatchQueue.main.async {
            self.distanceText = Self.formatDistance(surfaceDist)
            self.speedText = Self.formatSpeed(actualSpeed)
            self.etaText = actualSpeed > 1.0 ? Self.formatTime(surfaceDist / actualSpeed) : "Стоп"
            self.simDateText = currentDateStr
            self.screenMarkers = self.showMarkers ? newMarkers : []
        }
    }

    static func formatDistance(_ meters: Double) -> String {
        if meters < 1_000 { return String(format: "%.0f м", meters) }
        let km = meters / 1_000
        if km < 1_000_000 { return String(format: "%.1f тыс. км", km / 1_000) }
        let au = meters / UniverseCatalog.au
        if au < 10_000 { return String(format: "%.3f а.е.", au) }
        return String(format: "%.2f св. лет", meters / UniverseCatalog.ly)
    }

    static func formatSpeed(_ mps: Double) -> String {
        if mps < 1_000 { return String(format: "%.0f м/с", mps) }
        let kms = mps / 1_000
        if kms < 100_000 { return String(format: "%.1f км/с", kms) }
        return String(format: "%.2f c", mps / 299_792_458.0)
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
    var onChange: (CGPoint) -> Void
    @State private var knobOffset: CGSize = .zero
    private let maxRadius: CGFloat = 38

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.45))
                .overlay(Circle().stroke(Color.cyan.opacity(0.45), lineWidth: 1.5))
                .frame(width: 96, height: 96)

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
            if sim.isThirdPerson {
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

    var body: some View {
        ZStack {
            SceneViewContainer(sim: sim)

            // Слой интерактивных 3D-меток SpaceEngine (тап по метке выбирает объект целью)
            if sim.showMarkers {
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
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.top, 10)

                Spacer()

                HStack(alignment: .bottom, spacing: 10) {
                    VirtualFlightStick { pt in
                        sim.stickInput = pt
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("ТЯГА: \(Int(sim.throttle * 100))%")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyan)
                            Spacer()
                            Button(sim.flightAssist ? "FA: ON" : "ИНЕРЦИЯ") {
                                sim.flightAssist.toggle()
                            }
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(sim.flightAssist ? Color.green.opacity(0.35) : Color.orange.opacity(0.5))
                            .cornerRadius(6)
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
                        // Часы Вселенной: дата, реверс, пауза и масштаб времени
                        HStack(spacing: 5) {
                            Text(sim.simDateText)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.85))
                                .padding(.horizontal, 4)

                            Button(action: { sim.isTimeReversed.toggle() }) {
                                Image(systemName: sim.isTimeReversed ? "backward.fill" : "forward.fill")
                                    .font(.system(size: 10))
                                    .frame(width: 24, height: 24)
                                    .background(sim.isTimeReversed ? Color.orange.opacity(0.65) : Color.white.opacity(0.14))
                                    .clipShape(Circle())
                            }

                            Button(action: { sim.isTimePaused.toggle() }) {
                                Image(systemName: sim.isTimePaused ? "play.fill" : "pause.fill")
                                    .font(.system(size: 10))
                                    .frame(width: 24, height: 24)
                                    .background(sim.isTimePaused ? Color.red.opacity(0.65) : Color.white.opacity(0.14))
                                    .clipShape(Circle())
                            }

                            Button("−") { sim.timeWarpIndex = max(0, sim.timeWarpIndex - 1) }
                                .frame(width: 24, height: 24)
                                .background(Color.white.opacity(0.14))
                                .clipShape(Circle())

                            Text(sim.isTimePaused ? "ПАУЗА" : "\(sim.isTimeReversed ? "−" : "")\(sim.timeWarpSteps[sim.timeWarpIndex].label)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.yellow)
                                .frame(minWidth: 46)

                            Button("+") { sim.timeWarpIndex = min(sim.timeWarpSteps.count - 1, sim.timeWarpIndex + 1) }
                                .frame(width: 24, height: 24)
                                .background(Color.white.opacity(0.14))
                                .clipShape(Circle())
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .background(Color.black.opacity(0.72))
                        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                        .clipShape(Capsule())

                        HStack(spacing: 7) {
                            Button("−") { sim.speedIndex = max(0, sim.speedIndex - 1) }
                                .frame(width: 28, height: 28)
                                .background(Color.white.opacity(0.14))
                                .clipShape(Circle())

                            Text(sim.speedSteps[sim.speedIndex].label)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .frame(minWidth: 88)

                            Button("+") { sim.speedIndex = min(sim.speedSteps.count - 1, sim.speedIndex + 1) }
                                .frame(width: 28, height: 28)
                                .background(Color.white.opacity(0.14))
                                .clipShape(Circle())

                            Button("СТОП") {
                                sim.throttle = 0
                                sim.shipVelocityMetersPerSec = .zero
                            }
                            .font(.system(size: 10, weight: .bold))
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

            // Научная инфо-карточка объекта (SpaceEngine Wiki / Telemetry)
            if showInfo {
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
                            Text(String(format: "%.0f км", b.radiusMeters / 1_000)).bold()
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
                            GridRow {
                                Text("Год на орбите:").foregroundColor(.gray)
                                Text(String(format: "%.1f земн. дн.", b.orbitalPeriodSeconds / 86_400)).bold()
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
                    }
                    .font(.caption.bold())
                    .padding(.top, 4)
                }
                .foregroundColor(.white)
                .padding(14)
                .frame(maxWidth: 340)
                .background(Color.black.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.cyan.opacity(0.5), lineWidth: 1))
                .cornerRadius(16)
            }

            if showCatalog {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Астрономический каталог 1:1")
                            .font(.headline)
                        Spacer()
                        Button("Закрыть") { showCatalog = false }
                    }
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(UniverseCatalog.bodies) { body in
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
                .frame(maxWidth: 390, maxHeight: 290)
                .background(Color.black.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.cyan.opacity(0.4), lineWidth: 1))
                .cornerRadius(16)
            }
        }
    }
}