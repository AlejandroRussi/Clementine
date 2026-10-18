import SwiftUI

/// Aspect-fit image with a draggable, resizable crop rectangle.
/// `rect` is normalized (0…1) with a top-left origin; `imageSize` is in pixels.
struct CropSelectionView: View {
    let image: CGImage?
    let imageSize: CGSize
    @Binding var rect: CGRect
    let aspect: CropAspect
    @State private var startRect: CGRect?

    enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        GeometryReader { geo in
            let fit = fitRect(imageSize, in: geo.size)
            let r = rect
            let crop = CGRect(x: fit.minX + r.minX * fit.width, y: fit.minY + r.minY * fit.height,
                              width: r.width * fit.width, height: r.height * fit.height)
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(decorative: image, scale: 1).resizable().frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
                }
                Path { p in p.addRect(fit); p.addRect(crop) }
                    .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                Rectangle().stroke(Color.orange, lineWidth: 2)
                    .frame(width: crop.width, height: crop.height).offset(x: crop.minX, y: crop.minY)
                    .contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { g in
                        let s = startRect ?? rect; startRect = s
                        var n = s.offsetBy(dx: g.translation.width / fit.width, dy: g.translation.height / fit.height)
                        n.origin.x = min(max(0, n.minX), 1 - n.width)
                        n.origin.y = min(max(0, n.minY), 1 - n.height)
                        rect = n
                    }.onEnded { _ in startRect = nil })
                    .help("Crop selection. Drag to reposition.")
                ForEach(Corner.allCases, id: \.self) { corner in
                    let p = point(of: corner, in: crop)
                    Circle().fill(Color.orange).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .offset(x: p.x - 7, y: p.y - 7)
                        .gesture(DragGesture().onChanged { g in
                            let s = startRect ?? rect; startRect = s
                            rect = resize(s, corner: corner, by: CGSize(width: g.translation.width / fit.width,
                                                                          height: g.translation.height / fit.height))
                        }.onEnded { _ in startRect = nil })
                }
            }
        }
    }

    private func fitRect(_ size: CGSize, in box: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: box) }
        let s = min(box.width / size.width, box.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    private func point(of corner: Corner, in r: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    /// Moves one corner while the opposite corner stays anchored; honors the aspect ratio.
    private func resize(_ s: CGRect, corner: Corner, by d: CGSize) -> CGRect {
        let minSize: CGFloat = 0.03
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        let anchor = CGPoint(x: left ? s.maxX : s.minX, y: top ? s.maxY : s.minY)
        var moving = CGPoint(x: (left ? s.minX : s.maxX) + d.width, y: (top ? s.minY : s.maxY) + d.height)
        moving.x = min(max(0, moving.x), 1); moving.y = min(max(0, moving.y), 1)
        var w = max(minSize, abs(moving.x - anchor.x)), h = max(minSize, abs(moving.y - anchor.y))

        if let ratio = aspect.ratio(videoSize: imageSize), imageSize.height > 0 {
            // Convert the pixel ratio to normalized units, then fit inside the space available from the anchor.
            let nRatio = ratio * imageSize.height / imageSize.width
            h = w / nRatio
            let maxW = left ? anchor.x : 1 - anchor.x, maxH = top ? anchor.y : 1 - anchor.y
            if h > maxH { h = maxH; w = h * nRatio }
            if w > maxW { w = maxW; h = w / nRatio }
        } else {
            w = min(w, left ? anchor.x : 1 - anchor.x)
            h = min(h, top ? anchor.y : 1 - anchor.y)
        }
        return CGRect(x: left ? anchor.x - w : anchor.x, y: top ? anchor.y - h : anchor.y, width: w, height: h)
    }
}

extension CropAspect {
    /// Largest centered normalized rect of this aspect inside an image of `size`.
    func centeredRect(for size: CGSize) -> CGRect? {
        guard let ratio = ratio(videoSize: size), size.width > 0, size.height > 0 else { return nil }
        let frameRatio = size.width / size.height
        var w: CGFloat = 1, h: CGFloat = 1
        if ratio > frameRatio { h = frameRatio / ratio } else { w = ratio / frameRatio }
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }
}
