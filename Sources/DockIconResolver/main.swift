// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

final class ResolverDockTile: NSDockTile {
    override var size: NSSize { NSSize(width: 256, height: 256) }
    override func display() {}
}

func renderedImage(from tile: NSDockTile) -> NSImage? {
    if let image = (tile.contentView as? NSImageView)?.image { return image }
    guard let view = tile.contentView else { return nil }
    view.frame = NSRect(origin: .zero, size: tile.size)
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let image = NSImage(size: view.bounds.size)
    image.addRepresentation(bitmap)
    return image
}

func writePNG(_ image: NSImage, to url: URL) -> Bool {
    let output = NSImage(size: NSSize(width: 256, height: 256))
    output.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: output.size))
    output.unlockFocus()
    guard let tiff = output.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else { return false }
    do {
        try data.write(to: url, options: .atomic)
        return true
    } catch {
        return false
    }
}

guard CommandLine.arguments.count == 4 else { exit(2) }
let pluginURL = URL(fileURLWithPath: CommandLine.arguments[1])
let appearanceName: NSAppearance.Name = CommandLine.arguments[2] == "dark" ? .darkAqua : .aqua
let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])
guard pluginURL.pathExtension == "plugin",
      let bundle = Bundle(url: pluginURL),
      bundle.load(),
      let principalClass = bundle.principalClass as? NSObject.Type,
      let plugin = principalClass.init() as? NSDockTilePlugIn,
      let appearance = NSAppearance(named: appearanceName) else { exit(3) }

NSApplication.shared.appearance = appearance
let tile = ResolverDockTile()
plugin.setDockTile(tile)
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
guard let image = renderedImage(from: tile), writePNG(image, to: outputURL) else { exit(4) }
plugin.setDockTile(nil)
