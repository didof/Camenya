import Foundation
import UIKit

struct TakeThumbnailLoader: Sendable {
    func image(at url: URL?) async -> UIImage? {
        guard let url else { return nil }
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
    }
}
