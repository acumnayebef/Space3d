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
    let cameraNode = SCNNode()
    let sunLightNode = SCNNode()
    var exhaustNodes: [SCNNode] = []

    var shipPositionMeters = SIMD3<Double>(-UniverseCatalog.au + 11_500_000, 3_500_000, 12_500_000)
    var shipOrientation = simd_quatd(angle: 0.65, axis: simd_normalize(SIMD3<Double>(-0.2, 1.0, 0.0)))

    @Published var speedIndex: Int = 0
    @Published var throttle: Double = 0.0
    @Published var targetBody: CelestialBody = UniverseCatalog.bodies[3]
    @Published var distanceText: String = "11.0 тыс. км"
    @Published var etaText: String = "Стоп"
    @Published var isThirdPerson: Bool = true

    let speedSteps: [(label: String, mps: Double)] = [
        ("1.5 км/с", 1_500),
        ("11.2 км/с", 11_200),
        ("100 км/с", 100_000),
        ("10 000 км/с", 10_000_000),
        ("1 c", 299_792_458),
        ("100 c", 29_979_245_800),
        ("10 000 c", 2_997_924_580_000),
        ("500 000 c", 149_896_229_000_000)
    ]

    private var bodyNodes: [String: SCNNode] = [:]
    private var lastUpdateTime: TimeInterval = 0

    init() {
        setupScene()
    }

    private func setupScene() {
        // Звёздное небо в фоне сцены — никакого белого экрана и обрезанных сфер[span_14](start_span)[span_14](end_span)[span_15](start_span)[span_15](end_span)
        scene.background.contents = generateStarSkybox()

        let sunLight = SCNLight()
        sunLight.type = .directional
        sunLight.intensity = 1400
        sunLight.color = UIColor(red: 1.0, green: 0.98, blue: 0.95, alpha: 1.0)
        sunLightNode.light = sunLight
        scene.rootNode.addChildNode(sunLightNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 65
        ambient.color = UIColor(red: 0.16, green: 0.22, blue: 0.34, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        buildThirdPersonShip()
        buildFirstPersonCockpit()
        shipNode.addChildNode(thirdPersonMeshNode)
        shipNode.addChildNode(cockpitMeshNode)
        scene.rootNode.addChildNode(shipNode)

        let cam = SCNCamera()
        cam.zNear = 0.08
        cam.zFar = 1_500_000
        cam.fieldOfView = 62
        cameraNode.camera = cam
        shipNode.addChildNode(cameraNode)
        updateCameraMode()

        buildCelestialBodies()
    }

    private func buildCelestialBodies() {
        for body in UniverseCatalog.bodies {
            let root = SCNNode()
            let sphere = SCNSphere(radius: 1.0)
            sphere.segmentCount = 128

            let mat = SCNMaterial()
            if body.isStar {
                mat.lightingModel = .constant
                mat.emission.contents = uiColor(from: body.colorHex)
                mat.shaderModifiers = [.surface: starShaderModifier()]
            } else {
                mat.lightingModel = .physicallyBased
                mat.roughness.contents = body.id == "earth" ? 0.45 : 0.85
                mat.metalness.contents = 0.02
                mat.shaderModifiers = [.surface: planetShaderModifier(for: body)]
            }
            sphere.materials = [mat]
            root.addChildNode(SCNNode(geometry: sphere))

            // Объёмное свечение атмосферы (Fresnel-ореол без резких границ)
            if body.hasAtmosphere && !body.isStar {
                let atmoSphere = SCNSphere(radius: 1.038)
                atmoSphere.segmentCount = 72
                let atmoMat = SCNMaterial()
                atmoMat.lightingModel = .constant
                atmoMat.blendMode = .add
                atmoMat.cullMode = .front
                atmoMat.writesToDepthBuffer = false
                let atmoVec = body.id == "mars" ? "float3(0.95, 0.45, 0.22)" : "float3(0.25, 0.62, 1.0)"
                atmoMat.shaderModifiers = [.fragment: """
                    float ndotv = abs(dot(normalize(_surface.normal), normalize(_surface.view)));
                    float rim = pow(1.0 - ndotv, 3.2);
                    _output.color = float4(\(atmoVec) * rim * 0.85, rim);
                """]
                atmoSphere.materials = [atmoMat]
                root.addChildNode(SCNNode(geometry: atmoSphere))
            }

            // Кольца Сатурна / аккреционный диск ЧД
            if body.hasRings {
                let ring = SCNTube(innerRadius: 1.35, outerRadius: 2.35, height: 0.003)
                let ringMat = SCNMaterial()
                ringMat.diffuse.contents = generateRingTexture(isBlackHole: body.id == "sgr_a")
                if body.id == "sgr_a" {
                    ringMat.emission.contents = ringMat.diffuse.contents
                }
                ringMat.isDoubleSided = true
                ring.materials = [ringMat]
                let ringNode = SCNNode(geometry: ring)
                ringNode.eulerAngles = SCNVector3(0.42, 0.1, 0.25)
                root.addChildNode(ringNode)
            }

            scene.rootNode.addChildNode(root)
            bodyNodes[body.id] = root
        }
    }

    // Попиксельный процедурный Metal-шейдер для планет (фрактальные континенты, облака, пояса, кратеры)
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
        float3 p = normalize(_surface.position) * 3.2;
        // 5-октавный фрактальный 3D-шум (FBM)
        float n = 0.0;
        float amp = 0.5;
        float3 q = p;
        for (int i = 0; i < 5; i++) {
            float s = sin(q.x * 2.1 + cos(q.y * 2.3 + sin(q.z * 2.5)));
            float c = cos(q.z * 2.2 + sin(q.x * 2.4 + cos(q.y * 2.0)));
            n += (s * c * 0.5 + 0.5) * amp;
            q = q * 2.07 + float3(1.7, 9.2, 5.4);
            amp *= 0.5;
        }

        float3 col1 = float3(\(c1.r), \(c1.g), \(c1.b));
        float3 col2 = float3(\(c2.r), \(c2.g), \(c2.b));
        float3 albedo = col1;
        float rough = 0.85;

        int planetMode = \(mode);
        if (planetMode == 1) {
            // Земля: глубокий океан, шельф, зелёные равнины, горы, полярные шапки и вихревые облака
            float lat = abs(normalize(_surface.position).y);
            if (lat + n * 0.15 > 0.86) {
                albedo = float3(0.95, 0.97, 1.0);
                rough = 0.6;
            } else if (n < 0.49) {
                float depth = clamp(n / 0.49, 0.0, 1.0);
                albedo = mix(float3(0.02, 0.10, 0.32), float3(0.06, 0.34, 0.68), pow(depth, 1.4));
                rough = 0.18;
            } else {
                float h = (n - 0.49) / 0.51;
                float3 grass = float3(0.14, 0.42, 0.18);
                float3 desert = float3(0.68, 0.58, 0.36);
                float3 rock = float3(0.42, 0.40, 0.38);
                albedo = mix(grass, desert, smoothstep(0.15, 0.45, h));
                albedo = mix(albedo, rock, smoothstep(0.55, 0.85, h));
                rough = 0.88;
            }
            // Слой облаков с тенью
            float3 cp = normalize(_surface.position) * 4.5 + float3(u_time * 0.015, 0.0, 0.0);
            float cn = 0.0;
            float camp = 0.55;
            for (int j = 0; j < 4; j++) {
                cn += (sin(cp.x * 2.4 + cos(cp.y * 2.1 + cp.z * 2.3)) * 0.5 + 0.5) * camp;
                cp = cp * 2.15 + float3(3.1, 1.4, 7.2);
                camp *= 0.5;
            }
            float clouds = smoothstep(0.56, 0.82, cn);
            albedo = mix(albedo, float3(0.98, 0.99, 1.0), clouds * 0.88);
            rough = mix(rough, 0.9, clouds);
        } else if (planetMode == 2) {
            // Марс: пустыни, каньоны и полярные шапки
            float lat = abs(normalize(_surface.position).y);
            albedo = mix(col2, col1, smoothstep(0.32, 0.68, n));
            if (lat + n * 0.1 > 0.88) albedo = float3(0.95, 0.94, 0.92);
        } else if (planetMode == 3) {
            // Газовые гиганты: турбулентные широтные полосы
            float yBand = normalize(_surface.position).y * 14.0 + n * 2.2;
            float stripe = sin(yBand) * 0.5 + 0.5;
            albedo = mix(col2, col1, smoothstep(0.2, 0.8, stripe));
            rough = 0.65;
        } else {
            // Каменистые планеты и луны с микрорельефом
            albedo = mix(col2, col1, smoothstep(0.3, 0.72, n));
        }

        _surface.diffuse = float4(albedo, 1.0);
        _surface.roughness = rough;
        """
    }

    private func starShaderModifier() -> String {
        return """
        float3 p = normalize(_surface.position) * 8.0 + float3(u_time * 0.15);
        float gran = sin(p.x * 3.1 + cos(p.y * 3.3 + p.z * 3.5)) * 0.5 + 0.5;
        float ndotv = abs(dot(normalize(_surface.normal), normalize(_surface.view)));
        float limb = 0.55 + 0.45 * pow(ndotv, 0.55);
        _surface.emission.rgb *= (0.82 + gran * 0.35) * limb;
        """
    }

    private func buildThirdPersonShip() {
        let hullMat = SCNMaterial()
        hullMat.lightingModel = .physicallyBased
        hullMat.diffuse.contents = UIColor(red: 0.22, green: 0.27, blue: 0.35, alpha: 1.0)
        hullMat.metalness.contents = 0.75
        hullMat.roughness.contents = 0.32

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
        frameMat.diffuse.contents = UIColor(red: 0.12, green: 0.15, blue: 0.21, alpha: 1.0)

        let neonCyan = SCNMaterial()
        neonCyan.lightingModel = .constant
        neonCyan.diffuse.contents = UIColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 1.0)

        let neonOrange = SCNMaterial()
        neonOrange.lightingModel = .constant
        neonOrange.diffuse.contents = UIColor(red: 1.0, green: 0.52, blue: 0.12, alpha: 1.0)

        // Наклонная приборная панель с подсветкой МФД-экранов[span_16](start_span)[span_16](end_span)
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

        // 3 светящихся МФД-экрана на панели
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

        // Боковые стойки фонаря с габаритными огнями
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
            cameraNode.position = SCNVector3(0, 2.6, 12.5)
            cameraNode.eulerAngles = SCNVector3(-0.12, 0, 0)
        } else {
            cameraNode.position = SCNVector3(0, 0, 0)
            cameraNode.eulerAngles = SCNVector3(0, 0, 0)
        }
    }

    private func generateStarSkybox() -> UIImage {
        let w = 2048, h = 1024
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        return renderer.image { context in
            let ctx = context.cgContext
            ctx.setFillColor(UIColor(red: 0.01, green: 0.015, blue: 0.03, alpha: 1.0).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

            // Млечный Путь
            for i in 0..<3000 {
                let x = CGFloat((i * 48271) % w)
                let spread = sin(Double(x) / Double(w) * .pi * 2.0) * 140.0
                let offset = Double((i * 16807) % 240) - 120.0
                let y = CGFloat(Double(h) * 0.5 + spread + offset * 0.65)
                ctx.setFillColor(UIColor(red: 0.60, green: 0.76, blue: 1.0, alpha: 0.07).cgColor)
                ctx.fillEllipse(in: CGRect(x: x, y: y, width: 3.5, height: 3.5))
            }

            let starColors: [UIColor] = [
                .white,
                UIColor(red: 0.75, green: 0.88, blue: 1.0, alpha: 1.0),
                UIColor(red: 1.0, green: 0.92, blue: 0.75, alpha: 1.0),
                UIColor(red: 1.0, green: 0.72, blue: 0.55, alpha: 1.0)
            ]
            for i in 0..<7000 {
                let x = CGFloat((i * 73856093) % w)
                let y = CGFloat((i * 19349663) % h)
                let r = (i % 15 == 0) ? CGFloat(2.2) : CGFloat(1.1)
                let alpha = CGFloat((i % 75) + 25) / 100.0
                ctx.setFillColor(starColors[i % starColors.count].withAlphaComponent(alpha).cgColor)
                ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
            }
        }
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

    func rotateShip(yawDelta: Double, pitchDelta: Double) {
        let qYaw = simd_quatd(angle: -yawDelta, axis: SIMD3(0, 1, 0))
        let qPitch = simd_quatd(angle: -pitchDelta, axis: SIMD3(1, 0, 0))
        shipOrientation = simd_normalize(shipOrientation * qYaw * qPitch)
        shipNode.simdOrientation = simd_quatf(
            ix: Float(shipOrientation.imag.x),
            iy: Float(shipOrientation.imag.y),
            iz: Float(shipOrientation.imag.z),
            r: Float(shipOrientation.real)
        )
    }

    func alignToTarget() {
        let dir = simd_normalize(targetBody.positionMeters - shipPositionMeters)
        let forward = SIMD3<Double>(0, 0, -1)
        let dot = simd_dot(forward, dir)
        if dot < -0.9999 {
            shipOrientation = simd_quatd(angle: .pi, axis: SIMD3(0, 1, 0))
        } else {
            let axis = simd_normalize(simd_cross(forward, dir))
            shipOrientation = simd_quatd(angle: acos(max(-1.0, min(1.0, dot))), axis: axis)
        }
        rotateShip(yawDelta: 0, pitchDelta: 0)
    }

    func stepSimulation(currentTime: TimeInterval) {
        if lastUpdateTime == 0 { lastUpdateTime = currentTime }
        let dt = min(0.05, currentTime - lastUpdateTime)
        lastUpdateTime = currentTime

        let currentSpeed = speedSteps[speedIndex].mps * throttle
        let forwardVec = shipOrientation.act(SIMD3<Double>(0, 0, -1))
        shipPositionMeters += forwardVec * currentSpeed * dt

        let flameScale = Float(max(0.05, throttle * (1.0 + Double(speedIndex) * 0.25)))
        for fNode in exhaustNodes {
            fNode.scale = SCNVector3(1.0, flameScale, 1.0)
            fNode.isHidden = throttle <= 0.01
        }

        let sunDir = simd_normalize(shipPositionMeters)
        let fDir = SIMD3<Float>(Float(sunDir.x), Float(sunDir.y), Float(sunDir.z))
        sunLightNode.simdLook(at: fDir, up: SIMD3<Float>(0, 1, 0), localFront: SIMD3<Float>(0, 0, -1))

        for body in UniverseCatalog.bodies {
            guard let node = bodyNodes[body.id] else { continue }
            let rel = body.positionMeters - shipPositionMeters
            let dist = simd_length(rel)

            let maxRenderDist = 450_000.0
            let scaleFactor = dist > maxRenderDist ? (maxRenderDist / dist) : 1.0
            let renderPos = rel * scaleFactor
            let renderRadius = max(0.35, body.radiusMeters * scaleFactor)

            node.simdPosition = SIMD3<Float>(Float(renderPos.x), Float(renderPos.y), Float(renderPos.z))
            node.simdScale = SIMD3<Float>(repeating: Float(renderRadius))
        }

        let targetRel = targetBody.positionMeters - shipPositionMeters
        let surfaceDist = max(0, simd_length(targetRel) - targetBody.radiusMeters)
        DispatchQueue.main.async {
            self.distanceText = Self.formatDistance(surfaceDist)
            self.etaText = currentSpeed > 1.0 ? Self.formatTime(surfaceDist / currentSpeed) : "Стоп"
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
            sim.rotateShip(yawDelta: Double(t.x) * 0.004, pitchDelta: Double(t.y) * 0.004)
            gesture.setTranslation(.zero, in: gesture.view)
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
                HStack(spacing: 10) {
                    Button(action: { showCatalog.toggle() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "globe.americas.fill")
                            Text("\(sim.targetBody.name) • \(sim.distanceText)")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.black.opacity(0.68))
                        .overlay(Capsule().stroke(Color.cyan.opacity(0.45), lineWidth: 1))
                        .clipShape(Capsule())
                    }

                    Text("ETA: \(sim.etaText)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.black.opacity(0.68))
                        .clipShape(Capsule())

                    Spacer()

                    Button("На цель") { sim.alignToTarget() }
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.blue.opacity(0.8))
                        .clipShape(Capsule())

                    Button(sim.isThirdPerson ? "1-е лицо" : "3-е лицо") {
                        sim.isThirdPerson.toggle()
                        sim.updateCameraMode()
                    }
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.black.opacity(0.68))
                    .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                    .clipShape(Capsule())
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer()

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ТЯГА: \(Int(sim.throttle * 100))%")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan)
                        Slider(value: $sim.throttle, in: 0...1)
                            .frame(width: 170)
                            .tint(.cyan)
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.68))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.2), lineWidth: 1))
                    .cornerRadius(14)

                    Spacer()

                    HStack(spacing: 8) {
                        Button("−") { sim.speedIndex = max(0, sim.speedIndex - 1) }
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Circle())

                        Text(sim.speedSteps[sim.speedIndex].label)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .frame(minWidth: 92)

                        Button("+") { sim.speedIndex = min(sim.speedSteps.count - 1, sim.speedIndex + 1) }
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Circle())

                        Button("СТОП") { sim.throttle = 0 }
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color.red.opacity(0.8))
                            .clipShape(Capsule())
                    }
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.68))
                    .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    .clipShape(Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
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
                                Button(action: {
                                    sim.targetBody = body
                                    showCatalog = false
                                }) {
                                    HStack {
                                        Text(body.name).bold()
                                        Spacer()
                                        Text(body.type).font(.caption).foregroundColor(.gray)
                                    }
                                    .padding(10)
                                    .background(Color.white.opacity(0.08))
                                    .cornerRadius(8)
                                }
                            }
                        }
                    }
                }
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: 360, maxHeight: 280)
                .background(Color.black.opacity(0.88))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.cyan.opacity(0.4), lineWidth: 1))
                .cornerRadius(16)
            }
        }
    }
}