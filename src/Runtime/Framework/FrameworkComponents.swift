import Foundation

/// Stages native files and registry entries from Microsoft's component manifests.
struct FrameworkComponents {
  let directory: URL
  let driveC: URL
  let architecture: RuntimeArchitecture
  private let files = FileManager.default

  func install(progress: @MainActor @Sendable (Int, Int) -> Void) async throws -> WineRegistry {
    let manifests = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix(architecture.componentName + "_") && $0.pathExtension == "manifest" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !manifests.isEmpty else {
      throw ApplicationError(message: "The Framework package contains no \(architecture.rawValue) component manifests.")
    }

    var registry = WineRegistry()
    await progress(0, manifests.count)
    for (index, manifest) in manifests.enumerated() {
      try Task.checkCancellation()
      try autoreleasepool {
        try installManifest(manifest, registry: &registry)
      }
      await progress(index + 1, manifests.count)
    }

    return registry
  }

  private func installManifest(_ manifest: URL, registry: inout WineRegistry) throws {
    let document = try XMLDocument(contentsOf: manifest, options: .nodeLoadExternalEntitiesNever)
    guard let assembly = document.rootElement(),
      let identity = children(assembly, named: "assemblyIdentity").first else {
      throw ApplicationError(message: "Component identity missing in \(manifest.lastPathComponent).")
    }

    let sourceRoot = manifest.deletingPathExtension()
    for file in children(assembly, named: "file") {
      try installFile(file, identity: identity, sourceRoot: sourceRoot)
    }
    try installActivationFiles(from: sourceRoot)

    // Keep registry registration alongside the files described by each component.
    for key in try document.nodes(forXPath: "//*[local-name()='registryKey']") {
      guard let key = key as? XMLElement else { continue }

      let entries = try children(key, named: "registryValue").map { entry in
        let value = expand(attribute(entry, named: "value"))
        guard !value.replacingOccurrences(of: "$(Registry:", with: "").contains("$(") else {
          throw ApplicationError(message: "Unresolved registry substitution: \(value)")
        }

        return WineRegistry.Entry(
          name: attribute(entry, named: "name"),
          value: try WineRegistry.Value(
            componentType: requiredAttribute(entry, named: "valueType"), value: value
          )
        )
      }
      registry.addKey(try expand(requiredAttribute(key, named: "keyName")), values: entries)
    }
  }

  private func installFile(_ file: XMLElement, identity: XMLElement, sourceRoot: URL) throws {
    let name = try requiredAttribute(file, named: "name")
    let destinationName = attribute(file, named: "destinationName", default: name)
    let source = try windowsPath(name, under: sourceRoot)

    var destinations = [attribute(file, named: "destinationPath") + destinationName]
    destinations += children(file, named: "link").map { attribute($0, named: "destination") }

    // Native assemblies also need their versioned Global Assembly Cache locations.
    for gac in children(file, named: "gac") where attribute(gac, named: "clrarch") == architecture.componentName {
      let managedName = attribute(gac, named: "name", default: (name as NSString).deletingPathExtension)
      let version = try requiredAttribute(gac, named: "managedversion")
      let token = try requiredAttribute(identity, named: "publicKeyToken")
      destinations.append(
        "$(runtime.windows)/Microsoft.NET/assembly/\(architecture.gacFolder)/\(managedName)/v4.0_\(version)__\(token)/\(destinationName)"
      )
    }

    for destination in destinations {
      let normalized = destination.replacingOccurrences(of: "\\", with: "/").lowercased()
      guard normalized.hasPrefix("$(runtime.windows)/microsoft.net/")
        || (architecture == .x86_64 && normalized.hasPrefix("$(runtime.system32)/")) else { continue }

      // ARM64 keeps only COM's resource-only type libraries in Framework64.
      if architecture == .arm64, normalized.contains("/framework64/"), !normalized.hasSuffix(".tlb") { continue }
      try copy(source, to: windowsPath(destination, under: driveC))
    }
  }

  private func installActivationFiles(from sourceRoot: URL) throws {
    // Registry-only components have no payload directory.
    guard files.fileExists(atPath: sourceRoot.path) else { return }

    let contents = try files.contentsOfDirectory(at: sourceRoot, includingPropertiesForKeys: nil)
    for source in contents {
      let name = source.lastPathComponent.lowercased()
      guard name.hasPrefix(architecture.componentName + "_"), name.hasSuffix("clr0400.dll") else { continue }

      let destination = "windows/system32/" + source.lastPathComponent.dropFirst(architecture.componentName.count + 1)
      try copy(source, to: windowsPath(destination, under: driveC))
    }
  }

  private func windowsPath(_ original: String, under root: URL) throws -> URL {
    let path = original.replacingOccurrences(of: "$(runtime.windows)", with: "windows")
      .replacingOccurrences(of: "$(runtime.system32)", with: "windows/system32")
      .replacingOccurrences(of: "\\", with: "/")

    var result = root
    for part in path.split(separator: "/").map(String.init) {
      guard part != ".", part != "..", !part.contains("$"), !part.contains(":") else {
        throw ApplicationError(message: "Unsupported component destination: \(original)")
      }

      var names: [String] = []
      if files.fileExists(atPath: result.path) {
        names = try files.contentsOfDirectory(atPath: result.path)
      }

      // Match Windows casing when installing onto a case-sensitive filesystem.
      result.appendPathComponent(names.first { $0.caseInsensitiveCompare(part) == .orderedSame } ?? part)
    }

    return result
  }

  private func copy(_ source: URL, to destination: URL) throws {
    try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    if files.fileExists(atPath: destination.path) {
      try files.removeItem(at: destination)
    }

    try files.copyItem(at: source, to: destination)
  }

  private func expand(_ value: String) -> String {
    value.replacingOccurrences(of: "$(runtime.windows)", with: "C:\\windows")
      .replacingOccurrences(of: "$(runtime.system32)", with: "C:\\windows\\system32")
      .replacingOccurrences(of: "$(assembly.empty)", with: "")
  }

  private func children(_ node: XMLElement, named name: String) -> [XMLElement] {
    (node.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == name }
  }

  private func attribute(_ node: XMLElement, named name: String, default fallback: String = "") -> String {
    node.attribute(forName: name)?.stringValue ?? fallback
  }

  private func requiredAttribute(_ node: XMLElement, named name: String) throws -> String {
    let value = attribute(node, named: name)
    guard !value.isEmpty else {
      throw ApplicationError(message: "Component \(node.localName ?? "element") is missing \(name).")
    }

    return value
  }
}
