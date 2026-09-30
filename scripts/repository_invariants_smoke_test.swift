import Foundation

private func read(_ path: String) -> String {
    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else {
        fatalError("Unable to read \(path)")
    }
    return text
}

private func matches(_ pattern: String, in text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: pattern)
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
        guard match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let project = read("GestureControl.xcodeproj/project.pbxproj")
let plist = read("GestureControl/Info.plist")
let readme = read("README.md")
let buildScript = read("build_release.sh")

let marketingVersions = Set(matches(#"MARKETING_VERSION = "([^"]+)";"#, in: project))
let buildVersions = Set(matches(#"CURRENT_PROJECT_VERSION = ([0-9]+);"#, in: project))

require(marketingVersions.count == 1, "Target configurations must share one MARKETING_VERSION")
require(buildVersions.count == 1, "Target configurations must share one CURRENT_PROJECT_VERSION")
guard let marketingVersion = marketingVersions.first else {
    fatalError("Missing MARKETING_VERSION")
}
guard let buildVersion = buildVersions.first else {
    fatalError("Missing CURRENT_PROJECT_VERSION")
}

require(
    plist.contains("<string>$(MARKETING_VERSION)</string>"),
    "Info.plist must derive CFBundleShortVersionString from MARKETING_VERSION"
)
require(
    plist.contains("<string>$(CURRENT_PROJECT_VERSION)</string>"),
    "Info.plist must derive CFBundleVersion from CURRENT_PROJECT_VERSION"
)
require(
    readme.contains("# Gesture Control for macOS V\(marketingVersion)"),
    "README headline must match MARKETING_VERSION"
)
require(
    buildScript.contains("Print :CFBundleShortVersionString"),
    "build_release.sh must read the packaged app version"
)
require(
    buildScript.contains("Print :CFBundleVersion"),
    "build_release.sh must read the packaged build number"
)

print("Repository metadata invariants OK: version \(marketingVersion) (\(buildVersion))")
