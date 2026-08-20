import SwiftUI

struct TakeThumbnailView: View {
    let url: URL?
    let placeholderSystemName: String
    let cornerRadius: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                Image(systemName: placeholderSystemName)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) { image = await TakeThumbnailLoader().image(at: url) }
    }
}
