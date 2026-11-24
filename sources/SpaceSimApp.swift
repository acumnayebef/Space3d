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
    let thirdPersonMeshNode = SCNNode()
    let cockpitMeshNode = SCNNode()
    let cameraBoomNode = SCNNode()
    let cameraNode = SCNNode()
    let sunLightNode = SCNNode()
    var exhaustNodes: [SCNNode] = []

    // Реальные 64-битные координаты и вектор скорости (м и м/с)
    var shipPositionMeters = SIMD3<Double>(-UniverseCatalog.au + 10_200_000, 2_800_000, 11_400_000)
    var shipVelocityMetersPerSec = SIMD3<Double>(0, 0, 0)
    var shipOrientation = simd_quatd(angle: 0.68, axis: simd_normalize(SIMD3<Double>(-0.18, 1.0, 0.0)))

    // Углы свободного облёта камеры вокруг корабля (в 3-м лице)
    var orbitYaw: Float = 0.0
    var orbitPitch: Float = -0.14
    var orbitDistance: Float = 12.5

    var simulationTimeSeconds: Double = 0.0

    @Published var speedIndex: Int = 0
    @Published var timeWarpIndex: Int = 0
    @Published var throttle: Double = 0.0
    @Published var flightAssist: Bool = true
    @Published var freeLookMode: Bool = false
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
    private var lastUpdateTime: TimeInterval = 0

    init() {
        setupScene()
    }

    private func setupScene() {
        // Полноценная 6-гранная 3D-кубмапа звёздного неба — при повороте корабля звёзды движутся вместе со Вселенной!
        scene.background.contents = generateStarCubemap()

        let sunLight = SCNLight()
        sunLight.type = .directional
        sunLight.intensity = 1550
        sunLight.color = UIColor(red: 1.0, green: 0.98, blue: 0.95, alpha: 1.0)
        sunLightNode.light = sunLight
        scene.rootNode.addChildNode(sunLightNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 28
        ambient.color = UIColor(red: 0.14, green: 0.20, blue: 0.32, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        buildThirdPersonShip()
        buildFirstPersonCockpit()
        shipNode.addChildNode(thirdPersonMeshNode)
        shipNode.addChildNode(cockpitMeshNode)
        scene.rootNode.addChildNode(shipNode)

        // Узел-кронштейн для облёта камеры вокруг звездолёта
        shipNode.addChildNode(cameraBoomNode)
        let cam = SCNCamera()
        cam.zNear = 0.08
        cam.zFar = 1_500_000
        cam.fieldOfView = 60
        cameraNode.camera = cam
        cameraBoomNode.addChildNode(cameraNode)
        updateCameraMode()

        buildCelestialBodies()
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
                mat.roughness.contents = body.id == "earth" ? 0.42 : 0.88
                mat.metalness.contents = 0.02
                mat.shaderModifiers = [.surface: planetShaderModifier(for: body)]
            }
            sphere.materials = [mat]
            let meshNode = SCNNode(geometry: sphere)
            root.addChildNode(meshNode)
            planetMeshNodes[body.id] = meshNode

            // Мягкое рэлеевское рассеяние атмосферы (плавный переход в космос без резкого кольца)[span_19](start_span)[span_19](end_span)[span_20](start_span)[span_20](end_span)
            if body.hasAtmosphere && !body.isStar {
                let atmoSphere = SCNSphere(radius: 1.045)
                atmoSphere.segmentCount = 96
                let atmoMat = SCNMaterial()
                atmoMat.lightingModel = .constant
                atmoMat.blendMode = .add
                atmoMat.cullMode = .front
                atmoMat.writesToDepthBuffer = false
                let atmoVec = body.id == "mars" ? "vec3(0.92, 0.44, 0.22)" : "vec3(0.24, 0.58, 1.0)"
                atmoMat.shaderModifiers = [.fragment: """
                    float ndotv = clamp(abs(dot(normalize(_surface.normal), normalize(_surface.view))), 0.0, 1.0);
                    float halo = pow(ndotv, 2.6) * smoothstep(0.0, 0.45, 1.0 - ndotv);
                    _output.color = vec4(\(atmoVec) * halo * 1.35, halo);
                """]
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

    // Фотореалистичный шейдер планет: многооктавный рельеф с расчётом нормалей гор, океанские блики, циклоны облаков и ночные огни городов
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
        vec3 pos = normalize(_surface.position);
        vec3 p = pos * 3.4;

        // 6-октавный фрактальный 3D-шум (FBM) для детальной береговой линии и гор
        float n = 0.0;
        float ridge = 0.0;
        float amp = 0.52;
        vec3 q = p;
        for (int i = 0; i < 6; i++) {
            float s = sin(q.x * 2.15 + cos(q.y * 2.35 + sin(q.z * 2.45)));
            float c = cos(q.z * 2.25 + sin(q.x * 2.40 + cos(q.y * 2.05)));
            float v = s * c * 0.5 + 0.5;
            n += v * amp;
            ridge += (1.0 - abs(v * 2.0 - 1.0)) * amp;
            q = q * 2.11 + vec3(1.7, 9.2, 5.4);
            amp *= 0.49;
        }

        vec3 col1 = vec3(\(c1.r), \(c1.g), \(c1.b));
        vec3 col2 = vec3(\(c2.r), \(c2.g), \(c2.b));
        vec3 albedo = col1;
        vec3 emissive = vec3(0.0);
        float rough = 0.86;
        float bumpScale = 0.08;

        int planetMode = \(mode);
        if (planetMode == 1) {
            float lat = abs(pos.y);
            if (lat + n * 0.14 > 0.87) {
                albedo = vec3(0.95, 0.97, 1.0);
                rough = 0.58;
            } else if (n < 0.50) {
                float depth = clamp(n / 0.50, 0.0, 1.0);
                albedo = mix(vec3(0.015, 0.08, 0.28), vec3(0.05, 0.32, 0.65), pow(depth, 1.5));
                rough = 0.14;
                bumpScale = 0.005;
            } else {
                float h = (n - 0.50) / 0.50;
                vec3 forest = vec3(0.11, 0.34, 0.14);
                vec3 steppe = vec3(0.56, 0.50, 0.30);
                vec3 mountain = vec3(0.38, 0.36, 0.34);
                vec3 snow = vec3(0.94, 0.96, 0.98);
                albedo = mix(forest, steppe, smoothstep(0.12, 0.42, h));
                albedo = mix(albedo, mountain, smoothstep(0.45, 0.72, h + ridge * 0.15));
                albedo = mix(albedo, snow, smoothstep(0.78, 0.95, h + ridge * 0.2));
                rough = 0.90;
                bumpScale = 0.18;

                // Ночные огни мегаполисов вдоль побережья
                if (h < 0.18 && lat < 0.68) {
                    float cityNoise = fract(sin(dot(floor(pos * 180.0), vec3(12.9898, 78.233, 37.719))) * 43758.5453);
                    if (cityNoise > 0.86) {
                        emissive = vec3(1.0, 0.72, 0.32) * (cityNoise - 0.86) * 4.5;
                    }
                }
            }

            // Вихревые циклоны облаков
            vec3 swirl = pos * 4.2 + vec3(sin(pos.y * 6.0) * 0.35 + u_time * 0.008, 0.0, cos(pos.x * 6.0) * 0.35);
            float cn = 0.0;
            float camp = 0.54;
            for (int j = 0; j < 5; j++) {
                cn += (sin(swirl.x * 2.5 + cos(swirl.y * 2.2 + swirl.z * 2.4)) * 0.5 + 0.5) * camp;
                swirl = swirl * 2.18 + vec3(3.1, 1.4, 7.2);
                camp *= 0.48;
            }
            float clouds = smoothstep(0.55, 0.80, cn);
            albedo = mix(albedo, vec3(0.98, 0.99, 1.0), clouds * 0.90);
            emissive *= (1.0 - clouds * 0.85);
            rough = mix(rough, 0.92, clouds);
        } else if (planetMode == 2) {
            float lat = abs(pos.y);
            albedo = mix(col2, col1, smoothstep(0.28, 0.72, n));
            albedo = mix(albedo, vec3(0.82, 0.46, 0.28), ridge * 0.22);
            if (lat + n * 0.1 > 0.88) albedo = vec3(0.95, 0.94, 0.92);
            bumpScale = 0.22;
        } else if (planetMode == 3) {
            float turb = sin(pos.x * 9.0 + n * 5.0) * 0.04;
            float yBand = (pos.y + turb) * 16.0 + n * 2.4;
            float stripe = sin(yBand) * 0.5 + 0.5;
            albedo = mix(col2, col1, smoothstep(0.18, 0.82, stripe));
            rough = 0.62;
            bumpScale = 0.02;
        } else {
            albedo = mix(col2, col1, smoothstep(0.25, 0.75, n));
            albedo *= (0.75 + ridge * 0.45);
            bumpScale = 0.26;
        }

        // Возмущение нормали рельефом для объёмных теней гор на терминаторе
        vec3 dPos = vec3(dFdx(n), dFdy(n), 0.0);
        _surface.normal = normalize(_surface.normal - dPos * bumpScale * 18.0);
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

        for (idx, xPos) in [-0.42, 0.0, 0.42].enumerated() {
            let screen = SCNBox(width: 0.32, height: 0.14, length: 0.01, chamferRadius: 0.01)
            let sMat = SCNMaterial()
            sMat.lightingModel = .constant
            sMat.diffuse.contents = idx == 1
                ? UIColor(red: 0.06, green: 0.24, blue: 0.36, alpha: 1.0)
                : UIColor(red: 0.05, green: 0.16, blue: 0.26, alpha: 1.0)
            screen.materials = [sMat]
            let scNode = SCNNode(geometry: screen)
            scNode.position = SCNVector3(Float(xPos), -0.46, -0.66)
            scNode.eulerAngles.x = -0.35
            cockpitMeshNode.addChildNode(scNode)
        }

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
            cameraBoomNode.eulerAngles = SCNVector3(orbitPitch, orbitYaw, 0)
            cameraNode.position = SCNVector3(0, 0, orbitDistance)
            cameraNode.eulerAngles = SCNVector3(0, 0, 0)
        } else {
            cameraBoomNode.eulerAngles = SCNVector3(0, 0, 0)
            cameraNode.position = SCNVector3(0, 0, 0)
            cameraNode.eulerAngles = SCNVector3(0, 0, 0)
        }
    }

    // 6-гранная 3D-кубмапа звёзд — вращается в 3D при любом повороте корабля
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
                ctx.setFillColor(UIColor(red: 0.008, green: 0.012, blue: 0.024, alpha: 1.0).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

                var rng: UInt64 = UInt64(face + 1) &* 0x9E3779B97F4A7C15
                func nextRand() -> Double {
                    rng = rng &* 6364136223846793005 &+ 1442695040888963407
                    return Double(rng >> 33) / Double(1 << 31)
                }

                // Полоса Млечного Пути на боковых гранях кубмапы
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

    func handleDrag(dx: Double, dy: Double) {
        if freeLookMode && isThirdPerson {
            // Свободный облёт камеры вокруг корабля[span_21](start_span)[span_21](end_span)
            orbitYaw -= Float(dx * 0.006)
            orbitPitch = max(-1.3, min(1.3, orbitPitch - Float(dy * 0.006)))
            updateCameraMode()
        } else {
            // Естественный поворот звездолёта вправо/влево и вверх/вниз[span_22](start_span)[span_22](end_span)[span_23](start_span)[span_23](end_span)[span_24](start_span)[span_24](end_span)
            rotateShip(yawDelta: -dx * 0.0035, pitchDelta: -dy * 0.0035)
        }
    }

    func rotateShip(yawDelta: Double, pitchDelta: Double) {
        let qYaw = simd_quatd(angle: yawDelta, axis: SIMD3(0, 1, 0))
        let qPitch = simd_quatd(angle: pitchDelta, axis: SIMD3(1, 0, 0))
        shipOrientation = simd_normalize(shipOrientation * qYaw * qPitch)
        shipNode.simdOrientation = simd_quatf(
            ix: Float(shipOrientation.imag.x),
            iy: Float(shipOrientation.imag.y),
            iz: Float(shipOrientation.imag.z),
            r: Float(shipOrientation.real)
        )
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
        orbitPitch = -0.14
        updateCameraMode()
        rotateShip(yawDelta: 0, pitchDelta: 0)
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

        // Физика движения 1:1 с инерцией и Flight Assist
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

        let flameScale = Float(max(0.05, throttle * (1.0 + Double(speedIndex) * 0.22)))
        for fNode in exhaustNodes {
            fNode.scale = SCNVector3(1.0, flameScale, 1.0)
            fNode.isHidden = throttle <= 0.01
        }

        let sunDir = simd_normalize(shipPositionMeters)
        let fDir = SIMD3<Float>(Float(sunDir.x), Float(sunDir.y), Float(sunDir.z))
        sunLightNode.simdLook(at: fDir, up: SIMD3<Float>(0, 1, 0), localFront: SIMD3<Float>(0, 0, -1))

        // Реальное движение планет по орбитам и вращение вокруг своей оси 1:1
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
            sim.handleDrag(dx: Double(t.x), dy: Double(t.y))
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

                    if sim.isThirdPerson {
                        Button(sim.freeLookMode ? "Обзор" : "Руль") {
                            sim.freeLookMode.toggle()
                        }
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(sim.freeLookMode ? Color.orange.opacity(0.8) : Color.black.opacity(0.70))
                        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                        .clipShape(Capsule())
                    }

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

                HStack(alignment: .bottom, spacing: 10) {
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
                            .frame(width: 175)
                            .tint(.cyan)
                    }
                    .padding(9)
                    .background(Color.black.opacity(0.70))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.2), lineWidth: 1))
                    .cornerRadius(14)

                    // Регулятор времени 1:1
                    HStack(spacing: 6) {
                        Button("−") { sim.timeWarpIndex = max(0, sim.timeWarpIndex - 1) }
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Circle())
                        Text("⏱ \(sim.timeWarpSteps[sim.timeWarpIndex].label)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow)
                        Button("+") { sim.timeWarpIndex = min(sim.timeWarpSteps.count - 1, sim.timeWarpIndex + 1) }
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Circle())
                    }
                    .foregroundColor(.white)
                    .padding(7)
                    .background(Color.black.opacity(0.70))
                    .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    .clipShape(Capsule())

                    Spacer()

                    HStack(spacing: 7) {
                        Button("−") { sim.speedIndex = max(0, sim.speedIndex - 1) }
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Circle())

                        Text(sim.speedSteps[sim.speedIndex].label)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .frame(minWidth: 96)

                        Button("+") { sim.speedIndex = min(sim.speedSteps.count - 1, sim.speedIndex + 1) }
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Circle())

                        Button("СТОП") {
                            sim.throttle = 0
                            sim.shipVelocityMetersPerSec = .zero
                        }
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .background(Color.red.opacity(0.82))
                        .clipShape(Capsule())
                    }
                    .foregroundColor(.white)
                    .padding(7)
                    .background(Color.black.opacity(0.70))
                    .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    .clipShape(Capsule())
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