using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;


if (args.Length != 2)
{
  Console.Error.WriteLine("Usage: ExtractLauncher <MTGOSDK.dll> <output-directory>");
  return 1;
}

try
{
  string output = args[1];
  Directory.CreateDirectory(output);

  // Copy the published launcher and its embedded dependency without modifying either.
  string launcher = Path.Combine(output, "Launcher.exe");
  File.WriteAllBytes(launcher, ReadResource(args[0], "Resources/Launcher.exe"));
  File.WriteAllBytes(
    Path.Combine(output, "System.Deployment.dll"),
    ReadResource(launcher, "System.Deployment.dll"));
  return 0;
}
catch (Exception error) when (
  error is IOException or InvalidDataException or BadImageFormatException or UnauthorizedAccessException)
{
  Console.Error.WriteLine($"Could not extract the MTGOSDK launcher: {error.Message}");
  return 1;
}

static byte[] ReadResource(string assembly, string name)
{
  // Read metadata directly so extraction never loads the Windows-only SDK on macOS.
  using var stream = File.OpenRead(assembly);
  using var pe = new PEReader(stream);
  var header = pe.PEHeaders.CorHeader
    ?? throw new InvalidDataException($"File '{assembly}' is not a managed assembly.");
  var metadata = pe.GetMetadataReader();

  foreach (var handle in metadata.ManifestResources)
  {
    var resource = metadata.GetManifestResource(handle);
    if (!metadata.StringComparer.Equals(resource.Name, name)) continue;

    if (!resource.Implementation.IsNil)
      throw new InvalidDataException($"Resource '{name}' is not embedded in '{assembly}'.");

    int address = checked(header.ResourcesDirectory.RelativeVirtualAddress + (int)resource.Offset);
    var data = pe.GetSectionData(address).GetReader();
    return data.ReadBytes(data.ReadInt32());
  }

  throw new InvalidDataException($"Assembly '{assembly}' does not contain resource '{name}'.");
}
