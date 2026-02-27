// BrainView3D.swift
// 3D brain visualization with real MRI-derived cortex mesh.
// Uses FreeSurfer pial surface meshes (Brainder.org, CC BY-SA 3.0) loaded via ModelIO.
// Transparent outer cortex with segmented inner brain regions that light up per electrode.

import SwiftUI
import SceneKit
import SceneKit.ModelIO
import ModelIO
import Combine

struct BrainView3D: View {
    let edfData: EDFData

    // Scene state
    @State private var scene = SCNScene()
    @State private var regionMaterials: [String: SCNMaterial] = [:]
    @State private var leftHemiNode: SCNNode?
    @State private var rightHemiNode: SCNNode?

    // Data state
    @State private var isProcessing = true
    @State private var bandPowerData: [String: [[Float]]] = [:]
    @State private var epochTimes: [Float] = []
    @State private var lastEpochIdx: Int = -1

    // Control state
    @State private var currentTime: Float = 0
    @State private var selectedBand: BandSelection = .alpha
    @State private var isPlaying = false
    @State private var speed: Float = 1.0
    @State private var timer: AnyCancellable?

    enum BandSelection: String, CaseIterable {
        case all = "All"
        case delta = "Delta"
        case theta = "Theta"
        case alpha = "Alpha"
        case beta = "Beta"
    }

    // MARK: - Fresnel Rim Glow Shader (outer shell)

    private static let fresnelShader = """
    #pragma transparent
    #pragma body
    float NdotV = dot(_surface.normal, normalize(_surface.view));
    NdotV = clamp(NdotV, 0.0, 1.0);
    float fresnel = pow(1.0 - NdotV, 3.0);
    vec3 rimColor = vec3(0.30, 0.45, 0.85);
    _output.color.rgb += rimColor * fresnel * 0.7;
    _output.color.a = mix(0.005, 0.15, fresnel);
    """

    // MARK: - Connectivity map

    private static let connections: [(String, String)] = [
        ("Fp1", "Fp2"), ("F3", "F4"), ("C3", "C4"), ("P3", "P4"), ("O1", "O2"),
        ("F7", "F8"), ("T7", "T8"), ("P7", "P8"),
        ("Fp1", "F3"), ("F3", "C3"), ("C3", "P3"), ("P3", "O1"),
        ("Fp1", "F7"), ("F7", "T7"), ("T7", "P7"), ("P7", "O1"),
        ("Fp2", "F4"), ("F4", "C4"), ("C4", "P4"), ("P4", "O2"),
        ("Fp2", "F8"), ("F8", "T8"), ("T8", "P8"), ("P8", "O2"),
        ("Fz", "Cz"), ("Cz", "Pz"),
        ("F3", "Fz"), ("Fz", "F4"), ("C3", "Cz"), ("Cz", "C4"),
        ("P3", "Pz"), ("Pz", "P4"),
    ]

    // MARK: - Brain mesh constants

    private static let brainScale: Float = 0.004
    private static let brainCenterFS = simd_float3(-0.4, -14.9, 0.7)

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if isProcessing {
                ProgressView("Building 3D brain model...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 0.03, green: 0.03, blue: 0.06))
                    .foregroundColor(.white)
            } else {
                SceneView(
                    scene: scene,
                    options: [.allowsCameraControl]
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                controlsBar
            }
        }
        .background(Color(red: 0.03, green: 0.03, blue: 0.06))
        .task { await processAndBuild() }
        .onDisappear { timer?.cancel() }
        .onChange(of: selectedBand) { _ in
            lastEpochIdx = -1
            updateColors()
        }
        .onChange(of: currentTime) { _ in updateColors() }
    }

    // MARK: - Controls

    private var controlsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .foregroundColor(.white)
                        .frame(width: 32)
                }

                VStack(spacing: 2) {
                    Text("Speed: \(speed, specifier: "%.1f")x")
                        .font(.caption2).foregroundColor(.gray)
                    Slider(value: $speed, in: 0.5...4.0, step: 0.5)
                        .frame(width: 80)
                        .tint(.blue)
                }

                VStack(spacing: 2) {
                    let curMin = Int(currentTime) / 60
                    let curSec = Int(currentTime) % 60
                    let totMin = Int(edfData.duration) / 60
                    let totSec = Int(edfData.duration) % 60
                    Text(String(format: "%02d:%02d / %02d:%02d", curMin, curSec, totMin, totSec))
                        .font(.caption2.monospacedDigit()).foregroundColor(.gray)
                    Slider(value: $currentTime, in: 0...max(0.01, edfData.duration - 2.0))
                        .frame(minWidth: 200)
                        .tint(.blue)
                }

                Picker("Band", selection: $selectedBand) {
                    ForEach(BandSelection.allCases, id: \.self) { band in
                        Text(band.rawValue).tag(band)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                HStack(spacing: 4) {
                    Text("-3").font(.caption2).foregroundColor(.gray)
                    LinearGradient(
                        colors: [.cyan, .blue, .black,
                                 Color(red: 0.8, green: 0, blue: 0.8), .red, .yellow],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 100, height: 12)
                    .cornerRadius(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.gray.opacity(0.5), lineWidth: 0.5)
                    )
                    Text("+3").font(.caption2).foregroundColor(.gray)
                    Text("Z-score").font(.caption2).foregroundColor(.gray.opacity(0.6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.10))
    }

    // MARK: - Data Processing

    private func processAndBuild() async {
        isProcessing = true

        let eegData = edfData.eegData
        let sfreq = edfData.sfreq

        let (powerData, times) = await Task.detached(priority: .userInitiated) {
            let referenced = SignalProcessor.averageReference(eegData)
            let filtered = referenced.map { SignalProcessor.highpassFilter($0, sfreq: sfreq, cutoff: 1.0) }

            let decimFactor = max(1, Int(sfreq / 50.0))
            let decimSfreq = sfreq / Float(decimFactor)
            let decimated = filtered.map { SignalProcessor.decimate($0, factor: decimFactor, sfreq: sfreq) }

            let nSamples = decimated[0].count
            let epochLen = Int(2.0 * decimSfreq)
            let epochStep = Int(0.5 * decimSfreq)
            let nEpochs = max(1, (nSamples - epochLen) / epochStep + 1)

            var times = [Float]()
            for e in 0..<nEpochs {
                times.append(Float(e * epochStep) / decimSfreq)
            }

            var allBandPower: [String: [[Float]]] = [:]
            let bands: [(name: String, low: Float, high: Float)] = [
                ("Delta", 1.0, 4.0), ("Theta", 4.0, 8.0),
                ("Alpha", 8.0, 13.0), ("Beta", 13.0, 25.0)
            ]

            for band in bands {
                var channelEpochs = [[Float]]()
                for chIdx in 0..<decimated.count {
                    let bandFiltered = SignalProcessor.bandpassFilter(
                        decimated[chIdx], sfreq: decimSfreq,
                        lowCut: band.low, highCut: band.high)
                    var epochs = [Float]()
                    for e in 0..<nEpochs {
                        let start = e * epochStep
                        let end = min(start + epochLen, nSamples)
                        var sumSq: Float = 0
                        for i in start..<end { sumSq += bandFiltered[i] * bandFiltered[i] }
                        epochs.append(sqrtf(sumSq / Float(end - start)) * 1e6)
                    }
                    channelEpochs.append(epochs)
                }
                allBandPower[band.name] = channelEpochs
            }

            var allPower = [[Float]]()
            for chIdx in 0..<decimated.count {
                var epochs = [Float]()
                for e in 0..<nEpochs {
                    var total: Float = 0
                    for band in bands {
                        if let bp = allBandPower[band.name] {
                            let v = bp[chIdx][e]; total += v * v
                        }
                    }
                    epochs.append(sqrtf(total))
                }
                allPower.append(epochs)
            }
            allBandPower["All"] = allPower

            return (allBandPower, times)
        }.value

        self.bandPowerData = powerData
        self.epochTimes = times

        buildScene()
        isProcessing = false
        updateColors()
    }

    // MARK: - 3D Brain Scene

    private func buildScene() {
        scene = SCNScene()
        scene.background.contents = UIColor(red: 0.03, green: 0.03, blue: 0.06, alpha: 1.0)

        let brainParent = SCNNode()

        // 1. Outer transparent cortex shell
        if let leftMesh = loadCortexMesh(name: "lh.pial") {
            brainParent.addChildNode(leftMesh)
            self.leftHemiNode = leftMesh
        } else {
            let fallback = createFallbackHemisphere(isLeft: true)
            brainParent.addChildNode(fallback)
            self.leftHemiNode = fallback
        }

        if let rightMesh = loadCortexMesh(name: "rh.pial") {
            brainParent.addChildNode(rightMesh)
            self.rightHemiNode = rightMesh
        } else {
            let fallback = createFallbackHemisphere(isLeft: false)
            brainParent.addChildNode(fallback)
            self.rightHemiNode = fallback
        }

        // 2. Inner segmented brain — regions light up per electrode
        if let (regionNode, materials) = buildRegionMesh() {
            brainParent.addChildNode(regionNode)
            self.regionMaterials = materials
        }

        // Brain stem
        let stemGeom = SCNCapsule(capRadius: 0.05, height: 0.12)
        let stemMat = SCNMaterial()
        stemMat.lightingModel = .physicallyBased
        stemMat.diffuse.contents = UIColor(red: 0.12, green: 0.10, blue: 0.16, alpha: 0.4)
        stemMat.roughness.contents = NSNumber(value: 0.6)
        stemMat.transparency = 0.35
        stemMat.isDoubleSided = true
        stemGeom.materials = [stemMat]
        let stemNode = SCNNode(geometry: stemGeom)
        stemNode.position = SCNVector3(0, -0.32, -0.08)
        brainParent.addChildNode(stemNode)

        addConnectivityLines(to: brainParent)
        addSurfaceMarkers(to: brainParent)
        addParticleSystem(to: brainParent)

        scene.rootNode.addChildNode(brainParent)

        // Camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 38
        cameraNode.camera?.wantsHDR = true
        cameraNode.camera?.bloomIntensity = 1.0
        cameraNode.camera?.bloomThreshold = 0.4
        cameraNode.position = SCNVector3(0, 0.25, 1.4)
        cameraNode.look(at: SCNVector3(0, 0.05, 0))
        scene.rootNode.addChildNode(cameraNode)

        // Lights
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 120
        ambientLight.light?.color = UIColor(red: 0.5, green: 0.6, blue: 1.0, alpha: 1.0)
        scene.rootNode.addChildNode(ambientLight)

        let dirLight = SCNNode()
        dirLight.light = SCNLight()
        dirLight.light?.type = .directional
        dirLight.light?.intensity = 300
        dirLight.light?.color = UIColor(red: 0.8, green: 0.85, blue: 1.0, alpha: 1.0)
        dirLight.position = SCNVector3(0.5, 1.5, 2.0)
        dirLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(dirLight)

        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .directional
        fillLight.light?.intensity = 100
        fillLight.light?.color = UIColor(red: 0.4, green: 0.5, blue: 0.8, alpha: 1.0)
        fillLight.position = SCNVector3(-0.5, -1.0, 1.0)
        fillLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(fillLight)
    }

    // MARK: - Load Outer Cortex Shell

    private func loadCortexMesh(name: String) -> SCNNode? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "obj") else { return nil }

        let asset = MDLAsset(url: url)
        guard asset.count > 0,
              let mdlMesh = asset.object(at: 0) as? MDLMesh else { return nil }

        mdlMesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.7)

        let scnScene = SCNScene(mdlAsset: asset)
        var meshGeometry: SCNGeometry?
        scnScene.rootNode.enumerateChildNodes { node, stop in
            if let geo = node.geometry { meshGeometry = geo; stop.pointee = true }
        }
        guard let geometry = meshGeometry else { return nil }

        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor(red: 0.6, green: 0.65, blue: 0.8, alpha: 0.03)
        material.metalness.contents = NSNumber(value: 0.1)
        material.roughness.contents = NSNumber(value: 0.05)
        material.transparency = 0.04
        material.transparencyMode = .dualLayer
        material.isDoubleSided = true
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.shaderModifiers = [.fragment: BrainView3D.fresnelShader]
        geometry.materials = [material]

        let meshNode = SCNNode(geometry: geometry)
        let containerNode = SCNNode()
        containerNode.addChildNode(meshNode)
        applyBrainTransform(to: containerNode)
        return containerNode
    }

    // MARK: - Build Segmented Inner Brain (Voronoi regions per electrode)

    private func buildRegionMesh() -> (SCNNode, [String: SCNMaterial])? {
        // Load both hemisphere OBJs via MDLAsset (same proven path as outer mesh)
        guard let lhUrl = Bundle.main.url(forResource: "lh.pial", withExtension: "obj"),
              let rhUrl = Bundle.main.url(forResource: "rh.pial", withExtension: "obj") else {
            return nil
        }

        let lhAsset = MDLAsset(url: lhUrl)
        let rhAsset = MDLAsset(url: rhUrl)

        // Convert to SCNScene and extract geometry
        let lhScene = SCNScene(mdlAsset: lhAsset)
        let rhScene = SCNScene(mdlAsset: rhAsset)

        var lhGeometry: SCNGeometry?
        var rhGeometry: SCNGeometry?
        lhScene.rootNode.enumerateChildNodes { node, stop in
            if let geo = node.geometry { lhGeometry = geo; stop.pointee = true }
        }
        rhScene.rootNode.enumerateChildNodes { node, stop in
            if let geo = node.geometry { rhGeometry = geo; stop.pointee = true }
        }

        guard let lhGeo = lhGeometry, let rhGeo = rhGeometry else { return nil }

        // Extract vertex positions from SCNGeometry sources
        let lhVerts = extractVertices(from: lhGeo)
        let rhVerts = extractVertices(from: rhGeo)
        let lhFaces = extractFaces(from: lhGeo)
        let rhFaces = extractFaces(from: rhGeo)

        guard !lhVerts.isEmpty, !rhVerts.isEmpty else { return nil }

        // Merge both hemispheres
        let lhCount = UInt32(lhVerts.count)
        let allVerts = lhVerts + rhVerts
        var allFaces = lhFaces
        for face in rhFaces {
            allFaces.append((face.0 + lhCount, face.1 + lhCount, face.2 + lhCount))
        }

        // Get electrode positions in SceneKit space
        let channels = edfData.eegChannelNames
        var electrodeInfo: [(name: String, pos: SCNVector3)] = []
        for ch in channels {
            if let pos2D = Constants.electrodePositions2D[ch] {
                let pos3D = project2Dto3D(x: pos2D.x, y: pos2D.y, depth: 0.85)
                electrodeInfo.append((ch, pos3D))
            }
        }
        guard !electrodeInfo.isEmpty else { return nil }

        let s = BrainView3D.brainScale
        let cx = BrainView3D.brainCenterFS.x
        let cy = BrainView3D.brainCenterFS.y
        let cz = BrainView3D.brainCenterFS.z

        // Assign each vertex to nearest electrode (transform to SceneKit space for comparison)
        var vertexAssignment = [Int](repeating: 0, count: allVerts.count)
        for vi in 0..<allVerts.count {
            let v = allVerts[vi]
            // FS → SceneKit: SCN.X = (FS.X-cx)*s, SCN.Y = (FS.Z-cz)*s+0.05, SCN.Z = -(FS.Y-cy)*s
            let sx = (v.x - cx) * s
            let sy = (v.z - cz) * s + 0.05
            let sz = -(v.y - cy) * s

            var minDist2: Float = .greatestFiniteMagnitude
            var bestIdx = 0
            for (ei, info) in electrodeInfo.enumerated() {
                let dx = sx - info.pos.x
                let dy = sy - info.pos.y
                let dz = sz - info.pos.z
                let dist2 = dx * dx + dy * dy + dz * dz
                if dist2 < minDist2 {
                    minDist2 = dist2
                    bestIdx = ei
                }
            }
            vertexAssignment[vi] = bestIdx
        }

        // Group faces by electrode (majority vote)
        var facesPerElectrode = [[Int]](repeating: [], count: electrodeInfo.count)
        for (fi, face) in allFaces.enumerated() {
            let a0 = vertexAssignment[Int(face.0)]
            let a1 = vertexAssignment[Int(face.1)]
            let a2 = vertexAssignment[Int(face.2)]
            let winner: Int
            if a0 == a1 || a0 == a2 { winner = a0 }
            else if a1 == a2 { winner = a1 }
            else { winner = a0 }
            facesPerElectrode[winner].append(fi)
        }

        // Build vertex array in FS space (transform applied via node)
        let fsVerts: [SCNVector3] = allVerts.map { SCNVector3($0.x, $0.y, $0.z) }

        // Compute vertex normals
        var normals = [SCNVector3](repeating: SCNVector3(0, 0, 0), count: fsVerts.count)
        for face in allFaces {
            let i0 = Int(face.0), i1 = Int(face.1), i2 = Int(face.2)
            let v0 = fsVerts[i0], v1 = fsVerts[i1], v2 = fsVerts[i2]
            let nx = (v1.y - v0.y) * (v2.z - v0.z) - (v1.z - v0.z) * (v2.y - v0.y)
            let ny = (v1.z - v0.z) * (v2.x - v0.x) - (v1.x - v0.x) * (v2.z - v0.z)
            let nz = (v1.x - v0.x) * (v2.y - v0.y) - (v1.y - v0.y) * (v2.x - v0.x)
            for idx in [i0, i1, i2] {
                normals[idx] = SCNVector3(normals[idx].x + nx, normals[idx].y + ny, normals[idx].z + nz)
            }
        }
        for i in 0..<normals.count {
            let n = normals[i]
            let len = sqrtf(n.x * n.x + n.y * n.y + n.z * n.z)
            if len > 0 { normals[i] = SCNVector3(n.x / len, n.y / len, n.z / len) }
        }

        // Build multi-element SCNGeometry (one element per electrode region)
        let vertexSource = SCNGeometrySource(vertices: fsVerts)
        let normalSource = SCNGeometrySource(normals: normals)

        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []
        var materialMap: [String: SCNMaterial] = [:]

        for (ei, info) in electrodeInfo.enumerated() {
            let regionFaceIndices = facesPerElectrode[ei]
            guard !regionFaceIndices.isEmpty else { continue }

            var indices = [UInt32]()
            indices.reserveCapacity(regionFaceIndices.count * 3)
            for fi in regionFaceIndices {
                let face = allFaces[fi]
                indices.append(face.0)
                indices.append(face.1)
                indices.append(face.2)
            }

            let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
            elements.append(element)

            // Emissive material — visible at rest, lights up dramatically with activity
            let mat = SCNMaterial()
            mat.lightingModel = .constant
            mat.diffuse.contents = UIColor.clear
            mat.emission.contents = UIColor(red: 0.12, green: 0.12, blue: 0.20, alpha: 1.0)
            mat.emission.intensity = 0.5
            mat.transparency = 0.40
            mat.blendMode = .add
            mat.isDoubleSided = true
            mat.writesToDepthBuffer = false
            materials.append(mat)
            materialMap[info.name] = mat
        }

        guard !elements.isEmpty else { return nil }

        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: elements)
        geometry.materials = materials

        let meshNode = SCNNode(geometry: geometry)
        meshNode.scale = SCNVector3(0.98, 0.98, 0.98)  // Slightly inside outer shell

        let containerNode = SCNNode()
        containerNode.addChildNode(meshNode)
        applyBrainTransform(to: containerNode)

        return (containerNode, materialMap)
    }

    // MARK: - Geometry Data Extraction

    /// Extract vertex positions from an SCNGeometry's vertex source.
    private func extractVertices(from geometry: SCNGeometry) -> [simd_float3] {
        guard let source = geometry.sources(for: .vertex).first else { return [] }
        let count = source.vectorCount
        let stride = source.dataStride
        let offset = source.dataOffset
        let data = source.data

        var vertices = [simd_float3]()
        vertices.reserveCapacity(count)

        data.withUnsafeBytes { rawBuffer in
            let basePtr = rawBuffer.baseAddress!
            for i in 0..<count {
                let ptr = basePtr.advanced(by: i * stride + offset).assumingMemoryBound(to: Float.self)
                vertices.append(simd_float3(ptr[0], ptr[1], ptr[2]))
            }
        }

        return vertices
    }

    /// Extract triangle face indices from an SCNGeometry's first element.
    private func extractFaces(from geometry: SCNGeometry) -> [(UInt32, UInt32, UInt32)] {
        guard let element = geometry.elements.first else { return [] }
        let primitiveCount = element.primitiveCount
        let bpi = element.bytesPerIndex
        let data = element.data

        var faces = [(UInt32, UInt32, UInt32)]()
        faces.reserveCapacity(primitiveCount)

        data.withUnsafeBytes { rawBuffer in
            let basePtr = rawBuffer.baseAddress!
            for i in 0..<primitiveCount {
                let a: UInt32
                let b: UInt32
                let c: UInt32
                if bpi == 4 {
                    let ptr = basePtr.advanced(by: i * 3 * 4).assumingMemoryBound(to: UInt32.self)
                    a = ptr[0]; b = ptr[1]; c = ptr[2]
                } else if bpi == 2 {
                    let ptr = basePtr.advanced(by: i * 3 * 2).assumingMemoryBound(to: UInt16.self)
                    a = UInt32(ptr[0]); b = UInt32(ptr[1]); c = UInt32(ptr[2])
                } else {
                    continue
                }
                faces.append((a, b, c))
            }
        }

        return faces
    }

    // MARK: - Brain Coordinate Transform

    private func applyBrainTransform(to node: SCNNode) {
        let s = BrainView3D.brainScale
        let cx = BrainView3D.brainCenterFS.x
        let cy = BrainView3D.brainCenterFS.y
        let cz = BrainView3D.brainCenterFS.z

        var transform = SCNMatrix4Identity
        transform.m11 = s;  transform.m12 = 0;  transform.m13 = 0;  transform.m14 = 0
        transform.m21 = 0;  transform.m22 = 0;  transform.m23 = -s; transform.m24 = 0
        transform.m31 = 0;  transform.m32 = s;  transform.m33 = 0;  transform.m34 = 0
        transform.m41 = -cx * s
        transform.m42 = -cz * s + 0.05
        transform.m43 = cy * s
        transform.m44 = 1
        node.transform = transform
    }

    private func createFallbackHemisphere(isLeft: Bool) -> SCNNode {
        let sphere = SCNSphere(radius: 0.38)
        sphere.segmentCount = 64
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor(red: 0.7, green: 0.75, blue: 0.85, alpha: 0.06)
        material.metalness.contents = NSNumber(value: 0.15)
        material.roughness.contents = NSNumber(value: 0.05)
        material.transparency = 0.05
        material.transparencyMode = .dualLayer
        material.isDoubleSided = true
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.shaderModifiers = [.fragment: BrainView3D.fresnelShader]
        sphere.materials = [material]
        let node = SCNNode(geometry: sphere)
        node.scale = SCNVector3(0.56, 0.50, 0.62)
        node.position = SCNVector3(isLeft ? -0.11 : 0.11, 0.05, 0)
        return node
    }

    // MARK: - Connectivity Lines

    private func addConnectivityLines(to parent: SCNNode) {
        for (ch1, ch2) in BrainView3D.connections {
            guard let p1 = Constants.electrodePositions2D[ch1],
                  let p2 = Constants.electrodePositions2D[ch2] else { continue }
            let pos1 = project2Dto3D(x: p1.x, y: p1.y, depth: 0.70)
            let pos2 = project2Dto3D(x: p2.x, y: p2.y, depth: 0.70)
            let mid = SCNVector3(
                (pos1.x + pos2.x) / 2 * 0.85,
                (pos1.y + pos2.y) / 2 * 0.90,
                (pos1.z + pos2.z) / 2 * 0.85
            )
            if let seg1 = createTractSegment(from: pos1, to: mid) { parent.addChildNode(seg1) }
            if let seg2 = createTractSegment(from: mid, to: pos2) { parent.addChildNode(seg2) }
        }
    }

    private func createTractSegment(from p1: SCNVector3, to p2: SCNVector3) -> SCNNode? {
        let dx = p2.x - p1.x, dy = p2.y - p1.y, dz = p2.z - p1.z
        let length = sqrtf(dx * dx + dy * dy + dz * dz)
        guard length > 0.001 else { return nil }
        let cylinder = SCNCylinder(radius: 0.003, height: CGFloat(length))
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.clear
        mat.emission.contents = UIColor(red: 0.75, green: 0.60, blue: 0.20, alpha: 1.0)
        mat.emission.intensity = 0.35
        mat.transparency = 0.30
        mat.blendMode = .add
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        cylinder.materials = [mat]
        let node = SCNNode(geometry: cylinder)
        node.position = SCNVector3((p1.x + p2.x) / 2, (p1.y + p2.y) / 2, (p1.z + p2.z) / 2)
        let yAxis = simd_float3(0, 1, 0)
        let direction = simd_normalize(simd_float3(dx, dy, dz))
        let dot = simd_dot(yAxis, direction)
        if abs(dot) < 0.999 {
            let cross = simd_cross(yAxis, direction)
            node.simdRotation = simd_float4(cross.x, cross.y, cross.z, acos(max(-1, min(1, dot))))
        } else if dot < 0 { node.eulerAngles.z = .pi }
        return node
    }

    // MARK: - Surface Markers

    private func addSurfaceMarkers(to parent: SCNNode) {
        for ch in edfData.eegChannelNames {
            guard let pos2D = Constants.electrodePositions2D[ch] else { continue }
            let pos3D = project2Dto3D(x: pos2D.x, y: pos2D.y, depth: 0.95)
            let dotGeom = SCNSphere(radius: 0.010)
            dotGeom.segmentCount = 12
            let dotMat = SCNMaterial()
            dotMat.diffuse.contents = UIColor(white: 0.15, alpha: 1.0)
            dotMat.emission.contents = UIColor(red: 0.3, green: 0.4, blue: 0.6, alpha: 1.0)
            dotMat.emission.intensity = 0.4
            dotMat.writesToDepthBuffer = false
            dotGeom.materials = [dotMat]
            let dotNode = SCNNode(geometry: dotGeom)
            dotNode.position = pos3D
            parent.addChildNode(dotNode)
        }
    }

    // MARK: - Particle System

    private func addParticleSystem(to parent: SCNNode) {
        let particles = SCNParticleSystem()
        particles.birthRate = 30
        particles.particleLifeSpan = 2.5
        particles.particleSize = 0.003
        particles.particleSizeVariation = 0.002
        particles.particleColor = UIColor(red: 0.3, green: 0.5, blue: 1.0, alpha: 0.4)
        particles.particleColorVariation = SCNVector4(0.1, 0.15, 0.2, 0.0)
        particles.blendMode = .additive
        particles.emitterShape = SCNSphere(radius: 0.28)
        particles.birthLocation = .volume
        particles.particleVelocity = 0.003
        particles.particleVelocityVariation = 0.002
        particles.spreadingAngle = 180
        particles.isAffectedByGravity = false
        let emitterNode = SCNNode()
        emitterNode.position = SCNVector3(0, 0.05, 0)
        emitterNode.addParticleSystem(particles)
        parent.addChildNode(emitterNode)
    }

    // MARK: - 2D to 3D Projection

    private func project2Dto3D(x: Float, y: Float, depth: Float = 0.95) -> SCNVector3 {
        let headRadius: Float = 0.095
        let brainRadius: Float = 0.5
        let r2D = sqrtf(x * x + y * y)
        let theta = Float.pi / 2 * min(r2D / headRadius, 1.0)
        let phi = atan2(x, y)
        let x3D = brainRadius * sin(theta) * sin(phi) * 0.56 * depth
        let y3D = brainRadius * cos(theta) * 0.50 * depth + 0.05
        let z3D = brainRadius * sin(theta) * cos(phi) * 0.62 * depth
        return SCNVector3(x3D, y3D, z3D)
    }

    // MARK: - Color Update

    private func updateColors() {
        let channels = edfData.eegChannelNames
        let bandKey = selectedBand.rawValue
        guard let powerData = bandPowerData[bandKey], !epochTimes.isEmpty else { return }

        var epochIdx = 0
        for (i, t) in epochTimes.enumerated() {
            if t <= currentTime { epochIdx = i } else { break }
        }
        if epochIdx == lastEpochIdx { return }
        lastEpochIdx = epochIdx

        var values = [Float]()
        for chIdx in 0..<min(channels.count, powerData.count) {
            if epochIdx < powerData[chIdx].count { values.append(powerData[chIdx][epochIdx]) }
        }
        guard !values.isEmpty else { return }

        let mean = values.reduce(0, +) / Float(values.count)
        var variance: Float = 0
        for v in values { variance += (v - mean) * (v - mean) }
        let std = sqrtf(variance / Float(values.count))

        let zscores: [Float] = std > 0.001
            ? values.map { ($0 - mean) / std }
            : [Float](repeating: 0, count: values.count)

        // Update each brain region's material
        for (chIdx, ch) in channels.enumerated() {
            guard chIdx < zscores.count, let mat = regionMaterials[ch] else { continue }
            let zscore = zscores[chIdx]
            let pos = ColorMap.zscoreToPosition(zscore)
            let (r, g, b) = ColorMap.neuroSynchronyRGB(at: pos)
            let color = UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1.0)
            let absZ = min(abs(zscore), 3.0)

            mat.emission.contents = color
            mat.emission.intensity = CGFloat(0.3 + absZ * 1.2)
            mat.transparency = CGFloat(0.25 + absZ * 0.20)
        }
    }

    // MARK: - Playback

    private func togglePlayback() {
        if isPlaying {
            isPlaying = false
            timer?.cancel()
            timer = nil
        } else {
            isPlaying = true
            timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)
                .autoconnect()
                .sink { _ in
                    currentTime += Float(1.0 / 30.0) * speed
                    if currentTime >= edfData.duration - 2.0 { currentTime = 0 }
                }
        }
    }
}
