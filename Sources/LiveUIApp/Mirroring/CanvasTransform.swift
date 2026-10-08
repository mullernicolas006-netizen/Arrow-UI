import CoreGraphics

/// Maps between the Simulator's own logical point coordinate space (what
/// `RuntimeGeometry` is expressed in, and what the mirrored screenshot's
/// content represents) and the canvas view's rendered coordinate space.
///
/// Uses the same aspect-fit math as SwiftUI's `.aspectRatio(contentMode:
/// .fit)` (which is how the mirrored image itself is displayed), so the
/// selection/drag overlay boxes land exactly on top of the real UI
/// elements they represent instead of drifting as the window is resized.
struct CanvasTransform {
    let scale: CGFloat
    let offset: CGSize

    init(deviceSize: CGSize?, canvasSize: CGSize) {
        guard let deviceSize, deviceSize.width > 0, deviceSize.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else {
            scale = 1
            offset = .zero
            return
        }
        let fitScale = min(canvasSize.width / deviceSize.width, canvasSize.height / deviceSize.height)
        scale = fitScale
        offset = CGSize(
            width: (canvasSize.width - deviceSize.width * fitScale) / 2,
            height: (canvasSize.height - deviceSize.height * fitScale) / 2
        )
    }

    /// Device (Simulator) point space -> canvas view space.
    func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + offset.width, y: p.y * scale + offset.height)
    }

    func size(_ s: CGSize) -> CGSize {
        CGSize(width: s.width * scale, height: s.height * scale)
    }

    /// Canvas view space -> device (Simulator) point space. Used to turn a
    /// click/drag location on the canvas back into the coordinate space
    /// `runtimeGeometry` is expressed in, for hit-testing.
    func devicePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.width) / scale, y: (p.y - offset.height) / scale)
    }
}
