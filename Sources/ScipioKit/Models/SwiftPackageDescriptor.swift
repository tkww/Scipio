import Foundation
import PathKit

public struct SwiftPackageDescriptor: DependencyProducts {

    public let name: String
    public let version: String
    public let path: Path
    public let manifest: PackageManifest
    public let buildables: [SwiftPackageBuildable]

    public var productNames: [String]? {
        return buildables.map(\.name)
    }

    public init(path: Path, name: String) throws {
        self.name = name
        self.path = path

        var gitPath = path + ".git"

        guard gitPath.exists else {
            log.fatal("Missing git directory for package: \(name)")
        }

        if gitPath.isFile {
            guard let actualPath = (try gitPath.read()).components(separatedBy: "gitdir: ").last?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                log.fatal("Couldn't parse .git file in \(path)")
            }

            gitPath = (gitPath.parent() + Path(actualPath)).normalize()
        }

        let headPath = gitPath + "HEAD"

        guard headPath.exists else {
            log.fatal("Missing HEAD file in \(gitPath)")
        }

        self.version = (try headPath.read())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest: PackageManifest = try .load(from: path)
        self.manifest = manifest
        self.buildables = manifest.getBuildables()
    }

    public func version(for productName: String) -> String {
        return version
    }
}

// MARK: - PackageManifest
public struct PackageManifest: Codable, Equatable {
    public let name: String
    public let products: [Product]
    public let targets: [Target]

    public static func load(from path: Path) throws -> PackageManifest {
        precondition(path.isDirectory)
        
        let cachedManifestPath = Config.current.cachePath + "\(path.lastComponent)-\(try (path + "Package.swift").checksum(.sha256)).json"
        let data: Data
        if cachedManifestPath.exists {
            log.verbose("Loading cached Package.swift for \(path.lastComponent)")
            data = try cachedManifestPath.read()
        } else {
            log.verbose("Reading Package.swift for \(path.lastComponent)")
            data = try xcrun("swift", "package", "dump-package", "--package-path", "\(path.string)")
                .output()
            try cachedManifestPath.write(data)
        }
        let decoder = JSONDecoder()

        do {
            return try decoder.decode(PackageManifest.self, from: data)
        } catch {
            try cachedManifestPath.delete()

            return try load(from: path)
        }
    }

    public func getBuildables() -> [SwiftPackageBuildable] {
        return products
            .flatMap { getBuildables(in: $0) }
            .uniqued()
    }

    private func getBuildables(in product: Product) -> [SwiftPackageBuildable] {
        let targets = recursiveTargets(in: product)

        return targets
            .compactMap { target -> SwiftPackageBuildable? in
                let dependencies = target.dependencies.flatMap(\.names)

                if target.type == .binary {
                    return .binaryTarget(target)
                } else if dependencies.count == 1,
                          targets.first(where: { $0.name == dependencies[0] })?.type == .binary {

                    return nil
                } else {
                    return .target(target.name)
                }
            }
    }

    private func recursiveTargets(in product: Product) -> [PackageManifest.Target] {
        return product
            .targets
            .compactMap { target in targets.first { $0.name == target } }
            .flatMap { recursiveTargets(in: $0) }
    }

    private func recursiveTargets(in target: Target) -> [PackageManifest.Target] {
        return [target] + target
            .dependencies
            .flatMap { recursiveTargets(in: $0) }
    }

    private func recursiveTargets(in dependency: TargetDependency) -> [PackageManifest.Target] {
        let byName = dependency.byName?.compactMap { $0?.name }

        return (dependency.target?.compactMap({ $0?.name }) + byName)
            .compactMap { target in targets.first { $0.name == target } }
            .flatMap { recursiveTargets(in: $0) }
    }
}

extension PackageManifest {

    public struct Product: Codable, Equatable, Hashable {
        public let name: String
        public let targets: [String]
    }

    public struct Target: Codable, Equatable, Hashable {
        public let dependencies: [TargetDependency]
        public let name: String
        public let path: String?
        public let publicHeadersPath: String?
        public let type: TargetType
        public let checksum: String?
        public let url: String?
        public let settings: [Setting]?

        public struct Setting: Codable, Equatable, Hashable {
            public let kind: Kind

            enum CodingKeys: String, CodingKey {
                case kind
            }

            public enum Kind: Codable, Hashable  {
                case define(String)
                case headerSearchPath(String)
                case linkedFramework(String)
                case linkedLibrary(String)

                enum CodingKeys: String, CodingKey {
                    case define
                    case headerSearchPath
                    case linkedFramework
                    case linkedLibrary
                }

                enum ValueKeys: String, CodingKey {
                    case _0
                }

                public init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: PackageManifest.Target.Setting.Kind.CodingKeys.self)
                    var allKeys = ArraySlice(container.allKeys)
                    guard let onlyKey = allKeys.popFirst(), allKeys.isEmpty else {
                        throw DecodingError.typeMismatch(PackageManifest.Target.Setting.Kind.self, DecodingError.Context.init(codingPath: container.codingPath, debugDescription: "Invalid number of keys found, expected one.", underlyingError: nil))
                    }
                    switch onlyKey {
                    case .define:
                        let nestedContainer = try container.nestedContainer(keyedBy: PackageManifest.Target.Setting.Kind.DefineCodingKeys.self, forKey: PackageManifest.Target.Setting.Kind.CodingKeys.define)
                        self = PackageManifest.Target.Setting.Kind.define(try nestedContainer.decode(String.self, forKey: ._0))
                    case .headerSearchPath:
                        let nestedContainer = try container.nestedContainer(keyedBy: PackageManifest.Target.Setting.Kind.HeaderSearchPathCodingKeys.self, forKey: PackageManifest.Target.Setting.Kind.CodingKeys.headerSearchPath)
                        self = PackageManifest.Target.Setting.Kind.headerSearchPath(try nestedContainer.decode(String.self, forKey: ._0))
                    case .linkedFramework:
                        let nestedContainer = try container.nestedContainer(keyedBy: PackageManifest.Target.Setting.Kind.LinkedFrameworkCodingKeys.self, forKey: PackageManifest.Target.Setting.Kind.CodingKeys.linkedFramework)
                        self = PackageManifest.Target.Setting.Kind.linkedFramework(try nestedContainer.decode(String.self, forKey: ._0))
                    case .linkedLibrary:
                        let nestedContainer = try container.nestedContainer(keyedBy: PackageManifest.Target.Setting.Kind.LinkedLibraryCodingKeys.self, forKey: PackageManifest.Target.Setting.Kind.CodingKeys.linkedLibrary)
                        self = PackageManifest.Target.Setting.Kind.linkedLibrary(try nestedContainer.decode(String.self, forKey: ._0))
                    }
                }
            }
        }
    }

    public struct TargetDependency: Codable, Equatable, Hashable {
        public let byName: [Dependency?]?
        public let product: [Dependency?]?
        public let target: [Dependency?]?

        public var names: [String] {
            return [byName, product, target]
                .compactMap { $0 }
                .flatMap { $0 }
                .compactMap(\.?.name)
        }

        public enum Dependency: Codable, Equatable, Hashable {
            case name(String)
            case constraint(platforms: [String])

            public var name: String? {
                switch self {
                case .name(let name):
                    return name
                case .constraint:
                    return nil
                }
            }

            enum CodingKeys: String, CodingKey {
                case platformNames
            }

            public init(from decoder: Decoder) throws {
                if let container = try? decoder.singleValueContainer(),
                   let stringValue = try? container.decode(String.self) {

                    self = .name(stringValue)
                } else {
                    let container = try decoder.container(keyedBy: CodingKeys.self)

                    self = .constraint(platforms: try container.decode([String].self, forKey: .platformNames))
                }
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .name(let name):
                    var container = encoder.singleValueContainer()
                    try container.encode(name)
                case .constraint(let platforms):
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(platforms, forKey: .platformNames)
                }
            }
        }
    }

    public enum TargetType: String, Codable {
        case binary = "binary"
        case regular = "regular"
        case test = "test"
    }
}

public enum SwiftPackageBuildable: Equatable, Hashable {
    case target(String)
    case binaryTarget(PackageManifest.Target)

    public var name: String {
        switch self {
        case .target(let name):
            return name
        case .binaryTarget(let target):
            if let urlString = target.url, let url = URL(string: urlString) {
                return url.lastPathComponent
                    .components(separatedBy: ".")[0]
            } else if let path = target.path {
                return Path(path).lastComponent
                    .components(separatedBy: ".")[0]
            } else {
                return target.name
            }
        }
    }
}
