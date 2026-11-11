import AppKit
import SwiftUI

// Builds docs/icon.png: the </> mark from the welcome screen, on its own.
// Usage: make icon

@MainActor
func writeIcon(to path: String) -> Int32 {
    let mark = ZStack {
        RoundedRectangle(cornerRadius: 228, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.67, green: 0.37, blue: 0.70),
                        Color(red: 0.50, green: 0.21, blue: 0.56),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        Image(systemName: "chevron.left.forwardslash.chevron.right")
            .font(.system(size: 380, weight: .bold))
            .foregroundStyle(.white)
    }
    .frame(width: 1024, height: 1024)

    let renderer = ImageRenderer(content: mark)
    renderer.scale = 1
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("icon render failed")
        return 1
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
        return 0
    } catch {
        print("icon render failed: \(error.localizedDescription)")
        return 1
    }
}

exit(MainActor.assumeIsolated {
    let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/icon.png"
    return writeIcon(to: path)
})
