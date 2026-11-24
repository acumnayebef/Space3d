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

final class SpaceSimulationController: ObservableObject {
    let scene = SCNScene()
    let shipNode = SCNNode()
    let shipVisualNode = SCNNode()
    let thirdPersonMeshNode = SCNNode()
    let cockpitMeshNode = SCNNode()
    let cameraBoomNode = SCNNode()
    let cameraNode = SCNNode()
    let sunLightNode = SCNNode()
    let dustRootNode = SCNNode()

    var exhaustNodes: [SCNNode] = []
    var dustParticles: [(node: SCNNode, offset: SIMD3<Float>)] = []

    // 64-битные координаты и физика 1:1
    var shipPositionMeters = SIMD3<Double>(-UniverseCatalog.au + 10_200_000, 2_800_000, 11_400_000)
    var shipVelocityMetersPerSec = SIMD3<Double>(0, 0, 0)
    var shipOrientation = simd_quatd(angle: 0.68, axis: simd_normalize(SIMD3<Double>(-0.18, 1.0, 0.0)))

    // Угловая скорость для плавного управления джойстиком
    var angularVelYaw: Double = 0
    var angularVelPitch: Double = 0
    var stickInput: CGPoint = .zero // x: -1...1 (yaw), y: -1...1 (pitch)

    // Свободный облёт камеры (свайп по экрану) + пружинное отставание
    var orbitYaw: Float = 0.0
    var orbitPitch: Float = -0.16
    var orbitDistance: Float = 13.5
    var cameraLagYaw: Float = 0.0
    var cameraLagPitch: Float = 0.0

    var simulationTimeSeconds: Double = 0.0

    @Published var speedIndex: Int = 0
    @Published var timeWarpIndex: Int = 0
    @Published var throttle: Double = 0.0
    @Published var flightAssist: Bool = true
    @Published var targetBody: CelestialBody = UniverseCatalog.bodies[3]
    @Published var distanceText: String = "10.2 тыс. км"
    @Published var speedText: String = "0 м/с"
    @Published var etaText: String = "Стоп"
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
        ("100 000x", 100_000)
    ]

    private var bodyNodes: [String: SCNNode] = [:]
    private var planetMeshNodes: [String: SCNNode] = [:]
    private var planetMaterials: [String: SCNMaterial] = [:]
    private var atmoMaterials: [String: SCNMaterial] = [:]
    private var lastUpdateTime: TimeInterval = 0

    init() {
        setupScene()
    }

    private func setupScene() {
        scene.background.contents = generateStarCubemap()

        let sunLight = SCNLight()
        sunLight.type = .directional
        sunLight.intensity = 1700
        sunLight.color = UIColor(red: 1.0, green: 0.98, blue: 0.95, alpha: 1.0)
        sunLightNode.light = sunLight
        scene.rootNode.addChildNode(sunLightNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 18
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
            if body.isStar {
                mat.lightingModel = .constant
                mat.emission.contents = uiColor(from: body.colorHex)
                mat.shaderModifiers = [.surface: starShaderModifier()]
            } else {
                mat.lightingModel = .physicallyBased
                mat.roughness.contents = body.id == "earth" ? 0.40 : 0.88
                mat.metalness.contents = 0.02
                mat.shaderModifiers = [.surface: planetShaderModifier(for: body)]
                mat.setValue(NSValue(scnVector3: SCNVector3(1, 0, 0)), forKey: "sunDir")
                planetMaterials[body.id] = mat
            }
            sphere.materials = [mat]
            let meshNode = SCNNode(geometry: sphere)
            root.addChildNode(meshNode)
            planetMeshNodes[body.id] = meshNode

            // Физически корректная атмосфера: яркая на дневной стороне, закатный оттенок на терминаторе, чёрная ночью
            if body.hasAtmosphere && !body.isStar {
                let atmoSphere = SCNSphere(radius: 1.042)
                atmoSphere.segmentCount = 96
                let atmoMat = SCNMaterial()
                atmoMat.lightingModel = .constant
                atmoMat.blendMode = .add
                atmoMat.cullMode = .front
                atmoMat.writesToDepthBuffer = false
                let dayCol = body.id == "mars" ? "vec3(0.95, 0.48, 0.25)" : "vec3(0.24, 0.58, 1.0)"
                let sunsetCol = body.id == "mars" ? "vec3(0.85, 0.28, 0.12)" : "vec3(1.0, 0.45, 0.16)"
                atmoMat.shaderModifiers = [.fragment: """
                    #pragma arguments
                    vec3 sunDir;
                    #pragma body
                    vec3 n = normalize(_surface.normal);
                    vec3 v = normalize(_surface.view);
                    float ndotv = clamp(abs(dot(n, v)), 0.0, 1.0);
                    float rim = pow(ndotv, 2.8) * smoothstep(0.0, 0.42, 1.0 - ndotv);
                    float sunDot = dot(n, normalize(sunDir));
                    float dayMask = smoothstep(-0.22, 0.35, sunDot);
                    float sunsetMask = exp(-pow((sunDot + 0.02) * 4.5, 2.0));
                    vec3 col = mix(\(dayCol), \(sunsetCol), sunsetMask * 0.65);
                    _output.color = vec4(col * rim * dayMask * 1.65, rim * dayMask);
                """]
                atmoMat.setValue(NSValue(scnVector3: SCNVector3(1, 0, 0)), forKey: "sunDir")
                atmoMaterials[body.id] = atmoMat
                atmoSphere.materials = [atmoMat]
                root.addChildNode(SCNNode(geometry: atmoSphere))
            }

            if body.hasRings {
                let ring = SCNTube(innerRadius: 1.32, outerRadius: 2.38, height: 0.002)
                let ringMat = SCNMaterial()
                ringMat.diffuse.contents = generateRingTexture(isBlackHole: body.id == "sgr_a")
                if body.id == "sgr_a" {
                    ringMat.emission.contents = ringMat.diffuse.contents
                }
                ringMat.isDoubleSided = true
                ring.materials = [ringMat]
                let ringNode = SCNNode(geometry: ring)
                ringNode.eulerAngles = SCNVector3(0.12, 0.0, 0.08)
                root.addChildNode(ringNode)
            }

            scene.rootNode.addChildNode(root)
            bodyNodes[body.id] = root
        }
    }

    // Реалистичный 3D-шейдер планет с настоящим градиентным FBM-шумом, искривлением облаков и ночными огнями только на тёмной стороне
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
        #pragma arguments
        vec3 sunDir;
        #pragma body
        vec3 pos = normalize(_surface.position);

        // Настоящий 3D Value Noise + 6-октавный FBM
        vec3 p = pos * 3.8;
        float n = 0.0;
        float ridge = 0.0;
        float amp = 0.5;
        vec3 q = p;
        for (int i = 0; i < 6; i++) {
            vec3 fl = floor(q);
            vec3 fr = fract(q);
            fr = fr * fr * (3.0 - 2.0 * fr);
            float n000 = fract(sin(dot(fl + vec3(0,0,0), vec3(127.1, 311.7, 74.7))) * 43758.5453);
            float n100 = fract(sin(dot(fl + vec3(1,0,0), vec3(127.1, 311.7, 74.7))) * 43758.5453);
            float n010 = fract(sin(dot(fl + vec3(0,1,0), vec3(127.1, 311.7, 74.7))) * 43758.5453);
            float n110 = fract(sin(dot(fl + vec3(1,1,0), vec3(127.1, 311.7, 74.7))) * 43758.5453);
            float n001 = fract(sin(dot(fl + vec3(0,0,1), vec3(127.1, 311.7, 74.7))) * 43758.5453);
            float n101 = fract(sin(dot(fl + vec3(1,0,1), vec3(127.1, 311.7, 74.7))) * 43758.5453);
            float n011 = fract(sin(dot(fl + vec3(0,1,1), vec3(127.1, 311.7, 74.7))) * 43758.5453);
            float n111 = fract(sin(dot(fl + vec3(1,1,1), vec3(127.1, 311.7, 74.7))) * 43758.5453);
            float nx00 = mix(n000, n100, fr.x);
            float nx10 = mix(n010, n110, fr.x);
            float nx01 = mix(n001, n101, fr.x);
            float nx11 = mix(n011, n111, fr.x);
            float v = mix(mix(nx00, nx10, fr.y), mix(nx01, nx11, fr.y), fr.z);
            n += v * amp;
            ridge += (1.0 - abs(v * 2.0 - 1.0)) * amp;
            q = q * 2.08 + vec3(13.4, 7.1, 19.3);
            amp *= 0.48;
        }

        vec3 col1 = vec3(\(c1.r), \(c1.g), \(c1.b));
        vec3 col2 = vec3(\(c2.r), \(c2.g), \(c2.b));
        vec3 albedo = col1;
        vec3 emissive = vec3(0.0);
        float rough = 0.86;
        float sunDot = dot(pos, normalize(sunDir));
        float nightMask = smoothstep(0.08, -0.18, sunDot);

        int planetMode = \(mode);
        if (planetMode == 1) {
            float lat = abs(pos.y);
            if (lat + n * 0.16 > 0.86) {
                albedo = vec3(0.95, 0.97, 1.0);
                rough = 0.55;
            } else if (n < 0.495) {
                float depth = clamp(n / 0.495, 0.0, 1.0);
                albedo = mix(vec3(0.01, 0.05, 0.22), vec3(0.04, 0.28, 0.58), pow(depth, 1.8));
                rough = 0.12;
            } else {
                float h = (n - 0.495) / 0.505;
                vec3 forest = vec3(0.09, 0.28, 0.11);
                vec3 desert = vec3(0.62, 0.53, 0.34);
                vec3 rock = vec3(0.36, 0.34, 0.32);
                vec3 snow = vec3(0.94, 0.96, 0.98);
                float aridity = smoothstep(0.05, 0.38, abs(lat - 0.28));
                vec3 lowLand = mix(desert, forest, aridity);
                albedo = mix(lowLand, rock, smoothstep(0.35, 0.70, h + ridge * 0.12));
                albedo = mix(albedo, snow, smoothstep(0.75, 0.92, h + ridge * 0.18));
                rough = 0.92;

                // Ночные огни городов ТОЛЬКО на ночной стороне Земли
                if (h < 0.22 && lat < 0.65 && nightMask > 0.01) {
                    float cHash = fract(sin(dot(floor(pos * 220.0), vec3(12.9898, 78.233, 37.719))) * 43758.5453);
                    if (cHash > 0.88) {
                        emissive = vec3(1.0, 0.72, 0.30) * (cHash - 0.88) * 9.0 * nightMask;
                    }
                }
            }

            // Вихревые облака (domain-warped FBM)
            vec3 cp = pos * 4.8 + vec3(n * 0.85 + u_time * 0.005, n * 0.45, -n * 0.65);
            float cn = 0.0;
            float camp = 0.52;
            for (int j = 0; j < 4; j++) {
                vec3 fl = floor(cp);
                vec3 fr = fract(cp);
                fr = fr * fr * (3.0 - 2.0 * fr);
                float a = fract(sin(dot(fl, vec3(127.1, 311.7, 74.7))) * 43758.5453);
                float b = fract(sin(dot(fl + vec3(1,1,1), vec3(127.1, 311.7, 74.7))) * 43758.5453);
                cn += mix(a, b, (fr.x + fr.y + fr.z) * 0.333) * camp;
                cp = cp * 2.15 + vec3(5.2, 1.3, 8.7);
                camp *= 0.48;
            }
            float clouds = smoothstep(0.50, 0.76, cn);
            albedo = mix(albedo, vec3(0.98, 0.99, 1.0), clouds * 0.88);
            emissive *= (1.0 - clouds * 0.85);
            rough = mix(rough, 0.94, clouds);
        } else if (planetMode == 2) {
            float lat = abs(pos.y);
            albedo = mix(col2, col1, smoothstep(0.25, 0.75, n));
            albedo = mix(albedo, vec3(0.84, 0.48, 0.28), ridge * 0.25);
            if (lat + n * 0.1 > 0.88) albedo = vec3(0.95, 0.94, 0.92);
        } else if (planetMode == 3) {
            float turb = (n - 0.5) * 0.22;
            float yBand = (pos.y + turb) * 18.0;
            float stripe = sin(yBand) * 0.5 + 0.5;
            albedo = mix(col2, col1, smoothstep(0.15, 0.85, stripe));
            rough = 0.62;
        } else {
            albedo = mix(col2, col1, smoothstep(0.22, 0.78, n));
            albedo *= (0.72 + ridge * 0.48);
        }

        _surface.diffuse = vec4(albedo, 1.0);
        _surface.emission.rgb += emissive;
        _surface.roughness = rough;
        """
    }

    private func starShaderModifier() -> String {
        return """
        vec3 p = normalize(_surface.position) * 9.0 + vec3(u_time * 0.12);
        float gran = sin(p.x * 3.1 + cos(p.y * 3.3 + p.z * 3.5)) * 0.5 + 0.5;
        float ndotv = abs(dot(normalize(_surface.normal), normalize(_surface.view)));
        float limb = 0.52 + 0.48 * pow(ndotv, 0.55);
        _surface.emission.rgb *= (0.80 + gran * 0.38) * limb;
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
        let frameMat = SCNMaterial()
        frameMat.lightingModel = .constant
        frameMat.diffuse.contents = UIColor(red: 0.11, green: 0.14, blue: 0.20, alpha: 1.0)

        let neonCyan = SCNMaterial()
        neonCyan.lightingModel = .constant
        neonCyan.diffuse.contents = UIColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 1.0)

        let neonOrange = SCNMaterial()
        neonOrange.lightingModel = .constant
        neonOrange.diffuse.contents = UIColor(red: 1.0, green: 0.52, blue: 0.12, alpha: 1.0)

        let dash = SCNBox(width: 2.2, height: 0.36, length: 0.7, chamferRadius: 0.04)
        dash.materials = [frameMat]
        let dashNode = SCNNode(geometry: dash)
        dashNode.position = SCNVector3(0, -0.58, -0.85)
        dashNode.eulerAngles.x = 0.32
        cockpitMeshNode.addChildNode(dashNode)

        let trim = SCNBox(width: 1.9, height: 0.012, length: 0.02, chamferRadius: 0.004)
        trim.materials = [neonCyan]
        let trimNode = SCNNode(geometry: trim)
        trimNode.position = SCNVector3(0, -0.40, -0.60)
        cockpitMeshNode.addChildNode(trimNode)

        for side in [-1.0, 1.0] {
            let strut = SCNBox(width: 0.04, height: 1.15, length: 0.04, chamferRadius: 0.01)
            strut.materials = [frameMat]
            let sNode = SCNNode(geometry: strut)
            sNode.position = SCNVector3(Float(side * 0.74), 0.05, -0.75)
            sNode.eulerAngles = SCNVector3(0.22, 0, Float(side * 0.26))
            cockpitMeshNode.addChildNode(sNode)

            let led = SCNBox(width: 0.012, height: 0.25, length: 0.012, chamferRadius: 0.004)
            led.materials = [neonOrange]
            let lNode = SCNNode(geometry: led)
            lNode.position = SCNVector3(Float(side * 0.71), 0.05, -0.73)
            lNode.eulerAngles = SCNVector3(0.22, 0, Float(side * 0.26))
            cockpitMeshNode.addChildNode(lNode)
        }

        let topBar = SCNBox(width: 1.38, height: 0.035, length: 0.035, chamferRadius: 0.01)
        topBar.materials = [frameMat]
        let topNode = SCNNode(geometry: topBar)
        topNode.position = SCNVector3(0, 0.56, -0.64)
        cockpitMeshNode.addChildNode(topNode)

        let crosshair = SCNTorus(ringRadius: 0.042, pipeRadius: 0.0022)
        crosshair.materials = [neonCyan]
        let chNode = SCNNode(geometry: crosshair)
        chNode.eulerAngles.x = .pi / 2
        chNode.position = SCNVector3(0, 0.02, -0.95)
        cockpitMeshNode.addChildNode(chNode)
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
                ctx.setFillColor(UIColor(red: 0.006, green: 0.009, blue: 0.018, alpha: 1.0).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

                var rng: UInt64 = UInt64(face + 1) &* 0x9E3779B97F4A7C15
                func nextRand() -> Double {
                    rng = rng &* 6364136223846793005 &+ 1442695040888963407
                    return Double(rng >> 33) / Double(1 << 31)
                }

                if face == 0 || face == 1 || face == 4 || face == 5 {
                    for _ in 0..<900 {
                        let x = CGFloat(nextRand() * Double(size))
                        let y = CGFloat(Double(size) * 0.5 + (nextRand() - 0.5) * 240.0)
                        ctx.setFillColor(UIColor(red: 0.58, green: 0.74, blue: 1.0, alpha: 0.05).cgColor)
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

    private func generateRingTexture(isBlackHole: Bool) -> UIImage {
        let size = 256
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            let ctx = context.cgContext
            let center = CGPoint(x: size / 2, y: size / 2)
            for r in 65..<126 {
                if !isBlackHole && (r == 98 || r == 99 || r == 114) { continue }
                let alpha = isBlackHole ? CGFloat(126 - r) / 65.0 : CGFloat((r % 7) + 3) / 14.0
                let col = isBlackHole
                    ? UIColor(red: 1.0, green: 0.62, blue: 0.18, alpha: alpha)
                    : UIColor(red: 0.88, green: 0.79, blue: 0.60, alpha: alpha)
                ctx.setStrokeColor(col.cgColor)
                ctx.setLineWidth(1.2)
                ctx.addArc(center: center, radius: CGFloat(r), startAngle: 0, endAngle: .pi * 2, clockwise: false)
                ctx.strokePath()
            }
        }
    }

    /// Свайп по экрану — свободный облёт камеры вокруг корабля (не дёргает руль!)
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
        let orbitDist = body.radiusMeters * 2.8
        shipPositionMeters = bodyPos + SIMD3<Double>(orbitDist * 0.6, orbitDist * 0.25, orbitDist * 0.75)
        alignToTarget()
    }

    func stepSimulation(currentTime: TimeInterval) {
        if lastUpdateTime == 0 { lastUpdateTime = currentTime }
        let realDt = min(0.05, currentTime - lastUpdateTime)
        lastUpdateTime = currentTime

        let warp = timeWarpSteps[timeWarpIndex].mult
        let simDt = realDt * warp
        simulationTimeSeconds += simDt

        // Плавное управление рулём через виртуальный джойстик + инерция и крен корпуса
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

        // Визуальный крен корабля и пружинное отставание камеры — создаёт живое ощущение полёта корабля в космосе!
        let desiredBank = Float(angularVelYaw * 0.35)
        let desiredPitchVis = Float(angularVelPitch * 0.18)
        shipVisualNode.eulerAngles.z += (desiredBank - shipVisualNode.eulerAngles.z) * Float(min(1.0, realDt * 8.0))
        shipVisualNode.eulerAngles.x += (desiredPitchVis - shipVisualNode.eulerAngles.x) * Float(min(1.0, realDt * 8.0))

        cameraLagYaw += (Float(-angularVelYaw * 0.14) - cameraLagYaw) * Float(min(1.0, realDt * 5.0))
        cameraLagPitch += (Float(-angularVelPitch * 0.10) - cameraLagPitch) * Float(min(1.0, realDt * 5.0))
        if isThirdPerson {
            cameraBoomNode.eulerAngles = SCNVector3(orbitPitch + cameraLagPitch, orbitYaw + cameraLagYaw, 0)
        }

        // Физика движения 1:1
        let targetSpeed = speedSteps[speedIndex].mps * throttle
        let forwardVec = shipOrientation.act(SIMD3<Double>(0, 0, -1))
        let desiredVelocity = forwardVec * targetSpeed

        if flightAssist {
            let response = min(1.0, realDt * 3.5)
            shipVelocityMetersPerSec += (desiredVelocity - shipVelocityMetersPerSec) * response
        } else if throttle > 0.001 {
            shipVelocityMetersPerSec += forwardVec * (speedSteps[speedIndex].mps * throttle * 0.25) * realDt
        }

        shipPositionMeters += shipVelocityMetersPerSec * simDt
        let actualSpeed = simd_length(shipVelocityMetersPerSec)

        // Движение 3D-пыли мимо корабля (тактильное ощущение полёта)
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
        let fSunDir = SCNVector3(Float(sunDirWorld.x), Float(sunDirWorld.y), Float(sunDirWorld.z))
        let lookTarget = SIMD3<Float>(Float(-sunDirWorld.x), Float(-sunDirWorld.y), Float(-sunDirWorld.z))
        sunLightNode.simdLook(at: lookTarget, up: SIMD3<Float>(0, 1, 0), localFront: SIMD3<Float>(0, 0, -1))

        for body in UniverseCatalog.bodies {
            guard let node = bodyNodes[body.id] else { continue }
            let bodyPos = body.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
            let rel = bodyPos - shipPositionMeters
            let dist = simd_length(rel)

            let maxRenderDist = 450_000.0
            let scaleFactor = dist > maxRenderDist ? (maxRenderDist / dist) : 1.0
            let renderPos = rel * scaleFactor
            let renderRadius = max(0.35, body.radiusMeters * scaleFactor)

            node.simdPosition = SIMD3<Float>(Float(renderPos.x), Float(renderPos.y), Float(renderPos.z))
            node.simdScale = SIMD3<Float>(repeating: Float(renderRadius))

            if body.rotationPeriodSeconds != 0, let mesh = planetMeshNodes[body.id] {
                let spin = (2.0 * .pi / body.rotationPeriodSeconds) * simulationTimeSeconds
                mesh.eulerAngles.y = Float(spin.truncatingRemainder(dividingBy: 2.0 * .pi))
            }

            if !body.isStar {
                let toSun = simd_normalize(-bodyPos)
                let sunVec = NSValue(scnVector3: SCNVector3(Float(toSun.x), Float(toSun.y), Float(toSun.z)))
                planetMaterials[body.id]?.setValue(sunVec, forKey: "sunDir")
                atmoMaterials[body.id]?.setValue(sunVec, forKey: "sunDir")
            }
        }

        let targetPos = targetBody.currentPosition(simulationTime: simulationTimeSeconds, allBodies: UniverseCatalog.bodies)
        let surfaceDist = max(0, simd_length(targetPos - shipPositionMeters) - targetBody.radiusMeters)

        DispatchQueue.main.async {
            self.distanceText = Self.formatDistance(surfaceDist)
            self.speedText = Self.formatSpeed(actualSpeed)
            self.etaText = actualSpeed > 1.0 ? Self.formatTime(surfaceDist / actualSpeed) : "Стоп"
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
            sim.stepSimulation(currentTime: time)
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

    var body: some View {
        ZStack {
            SceneViewContainer(sim: sim)

            VStack {
                HStack(spacing: 8) {
                    Button(action: { showCatalog.toggle() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "globe.americas.fill")
                            Text("\(sim.targetBody.name) • \(sim.distanceText)")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        }
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(Color.black.opacity(0.70))
                        .overlay(Capsule().stroke(Color.cyan.opacity(0.45), lineWidth: 1))
                        .clipShape(Capsule())
                    }

                    Text("\(sim.speedText) • ETA \(sim.etaText)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color.black.opacity(0.70))
                        .clipShape(Capsule())

                    Spacer()

                    Button("На цель") { sim.alignToTarget() }
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color.blue.opacity(0.82))
                        .clipShape(Capsule())

                    Button(sim.isThirdPerson ? "1-е лицо" : "3-е лицо") {
                        sim.isThirdPerson.toggle()
                        sim.updateCameraMode()
                    }
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.black.opacity(0.70))
                    .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                    .clipShape(Capsule())
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.top, 10)

                Spacer()

                HStack(alignment: .bottom, spacing: 12) {
                    // Виртуальный джойстик пилотирования слева снизу
                    VirtualFlightStick { pt in
                        sim.stickInput = pt
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("ТЯГА: \(Int(sim.throttle * 100))%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyan)
                            Spacer()
                            Button(sim.flightAssist ? "FA: ON" : "ИНЕРЦИЯ") {
                                sim.flightAssist.toggle()
                            }
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(sim.flightAssist ? Color.green.opacity(0.35) : Color.orange.opacity(0.5))
                            .cornerRadius(6)
                        }
                        Slider(value: $sim.throttle, in: 0...1)
                            .frame(width: 150)
                            .tint(.cyan)
                    }
                    .padding(9)
                    .background(Color.black.opacity(0.70))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.2), lineWidth: 1))
                    .cornerRadius(14)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 6) {
                            Button("−") { sim.timeWarpIndex = max(0, sim.timeWarpIndex - 1) }
                                .frame(width: 26, height: 26)
                                .background(Color.white.opacity(0.14))
                                .clipShape(Circle())
                            Text("⏱ \(sim.timeWarpSteps[sim.timeWarpIndex].label)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.yellow)
                            Button("+") { sim.timeWarpIndex = min(sim.timeWarpSteps.count - 1, sim.timeWarpIndex + 1) }
                                .frame(width: 26, height: 26)
                                .background(Color.white.opacity(0.14))
                                .clipShape(Circle())
                        }
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.black.opacity(0.70))
                        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                        .clipShape(Capsule())

                        HStack(spacing: 7) {
                            Button("−") { sim.speedIndex = max(0, sim.speedIndex - 1) }
                                .frame(width: 30, height: 30)
                                .background(Color.white.opacity(0.14))
                                .clipShape(Circle())

                            Text(sim.speedSteps[sim.speedIndex].label)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .frame(minWidth: 92)

                            Button("+") { sim.speedIndex = min(sim.speedSteps.count - 1, sim.speedIndex + 1) }
                                .frame(width: 30, height: 30)
                                .background(Color.white.opacity(0.14))
                                .clipShape(Circle())

                            Button("СТОП") {
                                sim.throttle = 0
                                sim.shipVelocityMetersPerSec = .zero
                            }
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.red.opacity(0.82))
                            .clipShape(Capsule())
                        }
                        .foregroundColor(.white)
                        .padding(7)
                        .background(Color.black.opacity(0.70))
                        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
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