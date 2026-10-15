import Foundation

public enum GLBError: Error, Equatable {
    case notGLB
    case unsupportedVersion(UInt32)
    case malformed(String)
}

/// Reads the structure of a glTF 2.0 asset (binary .glb or JSON .gltf)
/// without rendering it: triangle count, animation clips, textures and the
/// extensions it relies on. Powers the import warning list (PRD A2) on
/// device and in the `cuardach` command-line tool.
public enum GLBInspector {
    /// Extensions GLTFKit2's RealityKit loader handles well enough to accept quietly.
    public static let supportedExtensions: Set<String> = [
        "KHR_materials_unlit", "KHR_texture_transform", "KHR_materials_emissive_strength",
        "KHR_mesh_quantization", "KHR_materials_clearcoat", "KHR_lights_punctual",
    ]

    /// Inspects a .glb container.
    public static func inspect(glb data: Data, resourceExists: (String) -> Bool = { _ in true }) throws -> AssetMetrics {
        guard data.count >= 20, u32(data, 0) == 0x4654_6C67 else { throw GLBError.notGLB }  // "glTF"
        let version = u32(data, 4)
        guard version == 2 else { throw GLBError.unsupportedVersion(version) }
        let jsonLen = Int(u32(data, 12))
        guard u32(data, 16) == 0x4E4F_534A, 20 + jsonLen <= data.count else {  // "JSON"
            throw GLBError.malformed("missing JSON chunk")
        }
        let json = data.subdata(in: (data.startIndex + 20)..<(data.startIndex + 20 + jsonLen))
        var m = try inspect(gltfJSON: json, resourceExists: resourceExists)
        m.bytes = data.count
        return m
    }

    /// Inspects glTF JSON (the content of a .gltf file or a GLB's JSON chunk).
    /// `resourceExists` checks external URIs relative to the asset.
    public static func inspect(gltfJSON: Data, resourceExists: (String) -> Bool = { _ in true }) throws -> AssetMetrics {
        guard case .object(let root)? = try? JSONDecoder().decode(JSONValue.self, from: gltfJSON) else {
            throw GLBError.malformed("JSON is not an object")
        }
        var m = AssetMetrics(bytes: gltfJSON.count)

        let accessors = root["accessors"]?.arrayValue ?? []
        func count(_ index: JSONValue?) -> Int? {
            guard let i = index?.intValue, accessors.indices.contains(i) else { return nil }
            return accessors[i].objectValue?["count"]?.intValue
        }

        var triangles = 0
        var minP = Vec3(.infinity, .infinity, .infinity), maxP = Vec3(-.infinity, -.infinity, -.infinity)
        for mesh in root["meshes"]?.arrayValue ?? [] {
            for prim in mesh.objectValue?["primitives"]?.arrayValue ?? [] {
                guard let p = prim.objectValue else { continue }
                let mode = p["mode"]?.intValue ?? 4
                let attrs = p["attributes"]?.objectValue ?? [:]
                let n = count(p["indices"]) ?? count(attrs["POSITION"]) ?? 0
                switch mode {
                case 4: triangles += n / 3           // TRIANGLES
                case 5, 6: triangles += max(0, n - 2) // STRIP, FAN
                default: break
                }
                if let i = attrs["POSITION"]?.intValue, accessors.indices.contains(i),
                   let acc = accessors[i].objectValue,
                   let lo = acc["min"]?.arrayValue?.compactMap(\.doubleValue), lo.count == 3,
                   let hi = acc["max"]?.arrayValue?.compactMap(\.doubleValue), hi.count == 3 {
                    minP = Vec3(min(minP.x, lo[0]), min(minP.y, lo[1]), min(minP.z, lo[2]))
                    maxP = Vec3(max(maxP.x, hi[0]), max(maxP.y, hi[1]), max(maxP.z, hi[2]))
                }
            }
        }
        m.triangles = triangles
        if minP.x.isFinite, maxP.x.isFinite { m.boundingSize = maxP - minP }

        m.animationClips = (root["animations"]?.arrayValue ?? []).enumerated().map { i, a in
            a.objectValue?["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Animation \(i + 1)"
        }

        for img in root["images"]?.arrayValue ?? [] {
            guard let uri = img.objectValue?["uri"]?.stringValue, !uri.hasPrefix("data:") else { continue }
            let decoded = uri.removingPercentEncoding ?? uri
            if !resourceExists(decoded) { m.missingTextures.append(decoded) }
        }

        let used = Set((root["extensionsUsed"]?.arrayValue ?? []).compactMap(\.stringValue))
            .union((root["extensionsRequired"]?.arrayValue ?? []).compactMap(\.stringValue))
        m.unsupportedExtensions = used.subtracting(supportedExtensions).sorted()
        return m
    }

    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        let s = d.startIndex + o
        return UInt32(d[s]) | UInt32(d[s + 1]) << 8 | UInt32(d[s + 2]) << 16 | UInt32(d[s + 3]) << 24
    }
}

extension JSONValue {
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var doubleValue: Double? { if case .number(let n) = self { n } else { nil } }
    public var intValue: Int? {
        if case .number(let n) = self, n.rounded() == n, abs(n) < 1e15 { Int(n) } else { nil }
    }
}
