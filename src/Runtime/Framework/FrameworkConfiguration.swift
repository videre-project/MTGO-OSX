import Foundation

/// Configures .NET Framework in a Wine prefix.
struct FrameworkConfiguration {
  let directory: URL

  func enableNativeSHA256() throws {
    let config = directory.appendingPathComponent("Config/machine.config")
    let document = try XMLDocument(contentsOf: config, options: .nodeLoadExternalEntitiesNever)
    guard let root = document.rootElement(), root.name == "configuration" else {
      throw ApplicationError(message: "The .NET Framework configuration is invalid.")
    }

    // Preserve unrelated machine.config entries and avoid rewriting an unchanged file.
    var changed = false
    func child(_ name: String, in parent: XMLElement) -> XMLElement {
      if let existing = parent.elements(forName: name).first { return existing }

      let element = XMLElement(name: name)
      parent.addChild(element)
      changed = true

      return element
    }

    func setAttribute(_ name: String, to value: String, on element: XMLElement) {
      if let attribute = element.attribute(forName: name) {
        guard attribute.stringValue != value else { return }

        attribute.stringValue = value
      } else {
        let attribute = XMLNode(kind: .attribute)
        attribute.name = name
        attribute.stringValue = value
        element.addAttribute(attribute)
      }

      changed = true
    }

    let settings = child("cryptographySettings", in: child("mscorlib", in: root))
    let mapping = child("cryptoNameMapping", in: settings)
    let classes = child("cryptoClasses", in: mapping)

    let alias = "MTGOSHA256"
    let definition = classes.elements(forName: "cryptoClass").first {
      $0.attribute(forName: alias) != nil
    } ?? XMLElement(name: "cryptoClass")
    if definition.parent == nil { classes.addChild(definition) }
    setAttribute(
      alias,
      to: "System.Security.Cryptography.SHA256Cng, System.Core, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089",
      on: definition
    )

    // MTGO's SHA256.Create() calls use CNG without changing game assemblies.
    for name in ["SHA256", "System.Security.Cryptography.SHA256"] {
      let entry = mapping.elements(forName: "nameEntry").first {
        $0.attribute(forName: "name")?.stringValue == name
      } ?? XMLElement(name: "nameEntry")
      if entry.parent == nil { mapping.addChild(entry) }
      setAttribute("name", to: name, on: entry)
      setAttribute("class", to: alias, on: entry)
    }

    if changed {
      try document.xmlData.write(to: config, options: .atomic)
    }
  }
}
