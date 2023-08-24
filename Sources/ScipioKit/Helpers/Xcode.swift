import Combine
import Foundation
import PathKit

@discardableResult
func xcrun(_ command: String, _ arguments: String..., passEnvironment: Bool = false, file: StaticString = #file, line: UInt = #line, lineReader: ((String) -> Void)? = nil) throws -> ShellCommand {
    let developerDirectory = Path((try sh("/usr/bin/xcode-select", "--print-path").outputString())
        .trimmingCharacters(in: .whitespacesAndNewlines))
    let commandPath = developerDirectory + "Toolchains/XcodeDefault.xctoolchain/usr/bin/\(command)"

    return try sh(commandPath, arguments, passEnvironment: passEnvironment, file: file, line: line, lineReader: lineReader)
}

struct Xcode {
    static func getArchivePath(for scheme: String, sdk: Xcodebuild.SDK) -> Path {
        return Config.current.buildPath + "\(scheme)-\(sdk.rawValue).xcarchive"
    }

    static func archive(scheme: String, in path: Path, for sdk: Xcodebuild.SDK, derivedDataPath: Path, sourcePackagesPath: Path? = nil, additionalBuildSettings: [String: String]?) throws -> Path {

        var buildSettings: [String: String] = [
            "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
            "SKIP_INSTALL": "NO",
            "INSTALL_PATH": "/Library/Frameworks",
            "CODE_SIGN_IDENTITY": ""
        ]

        if let additionalBuildSettings = additionalBuildSettings {
            buildSettings.merge(additionalBuildSettings) { l, r in r }
        }

        let archivePath = getArchivePath(for: scheme, sdk: sdk)

        log.info("🏗  Building \(scheme)-\(sdk.rawValue)...")

        let command = Xcodebuild(
            command: .archive,
            workspace: path.extension == "xcworkspace" ? path.string : nil,
            project: path.extension == "xcodeproj" ? path.string : nil,
            scheme: scheme,
            archivePath: archivePath.string,
            derivedDataPath: derivedDataPath.string,
            clonedSourcePackageDirectory: sourcePackagesPath?.string,
            sdk: sdk,
            additionalBuildSettings: buildSettings
        )

        try path.chdir {
            try command.run()
        }

        return archivePath
    }

    static func createXCFramework(archivePaths: [Path], skipIfExists: Bool, filter isIncluded: ((String) -> Bool)? = nil) throws -> [Path] {
        precondition(!archivePaths.isEmpty, "Cannot create XCFramework from zero archives")

        let firstArchivePath = archivePaths[0]
        let buildDirectory = firstArchivePath.parent()
        let frameworkPaths = (firstArchivePath + "Products/Library/Frameworks")
            .glob("*.framework")
            .filter { isIncluded?($0.lastComponentWithoutExtension) ?? true }

        let filteredFrameworkNames = frameworkPaths.map { $0.lastComponentWithoutExtension }

        return try frameworkPaths.compactMap { frameworkPath in
            let productName = frameworkPath.lastComponentWithoutExtension

            let frameworks: [(path: Path, debugSymbolsPath: Path)] = archivePaths.map { archivePath in
                (path: archivePath + "Products/Library/Frameworks/\(productName).framework",
                 debugSymbolsPath: archivePath + "dSYMs/\(productName).framework.dSYM")
            }

            let output = buildDirectory + "\(productName).xcframework"

            if skipIfExists, output.exists {
                return output
            }

            log.info("📦  Creating \(productName).xcframework...")

            if output.exists {
                try output.delete()
            }

            // TODO: Need a robust solution
            // The following snippet of code is used to solve issue: https://github.com/apple/swift/issues/56573
            // But the solution is fragile
            try frameworks.forEach { framework in
                    let frameworkName = framework.path.lastComponentWithoutExtension
                    let swiftInterfaces = (framework.path + "Modules/\(frameworkName).swiftmodule").glob("*.swiftinterface")
                try swiftInterfaces.forEach { interface in
                    let content = try interface.read(.utf8)
                    var replaced = content

                    filteredFrameworkNames.forEach { filteredFrameworkName in
                        replaced = replaced.replacingOccurrences(of: "\(filteredFrameworkName).\(filteredFrameworkName)", with: filteredFrameworkName)
                    }
                    try interface.write(replaced as String)
                }
            }

            let additionalArguments = frameworks
                .flatMap { framework in
                    var arguments = ["-framework", framework.path.string]
                    // Check DSYM path exists
                    if framework.debugSymbolsPath.exists {
                        arguments = arguments + ["-debug-symbols", framework.debugSymbolsPath.string]
                    }
                    return arguments
                }
                + ["-output", output.string]

            let command = Xcodebuild(
                command: .createXCFramework,
                additionalArguments: additionalArguments
            )
            try buildDirectory.chdir {
                try command.run()
            }

            return output
        }
    }
}
