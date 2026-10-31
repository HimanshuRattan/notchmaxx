import SwiftUI

/// A stand-in Mac desktop for screenshots and the promo video: a soft gradient wallpaper and a
/// menu bar for the notch to sit in.
struct Desktop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.13, green: 0.14, blue: 0.30), Color(red: 0.30, green: 0.22, blue: 0.42)],
                           startPoint: .top, endPoint: .bottom)
            Circle().fill(Color(red: 0.98, green: 0.58, blue: 0.42)).frame(width: 620).blur(radius: 160).offset(x: -380, y: 300)
            Circle().fill(Color(red: 0.42, green: 0.48, blue: 0.98)).frame(width: 560).blur(radius: 150).offset(x: 420, y: -120)
            Circle().fill(Color(red: 0.86, green: 0.42, blue: 0.70)).frame(width: 420).blur(radius: 140).offset(x: 260, y: 360)
        }
    }
}

struct MenuBar: View {
    var height: CGFloat

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEdMMMjmm")
        return f
    }()

    var body: some View {
        // Each side keeps its natural width, so on a narrow canvas the notch covers items
        // instead of the text wrapping.
        ZStack {
            HStack(spacing: 18) {
                Image(systemName: "apple.logo").font(.system(size: 14))
                Text("Terminal").fontWeight(.bold)
                Text("Shell")
                Text("Edit")
                Text("View")
            }
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 18) {
                Image(systemName: "battery.75percent")
                Image(systemName: "magnifyingglass")
                Text(Self.clock.string(from: .now))
            }
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 20)
        .frame(height: height)
        .clipped()
        .background(Color.black.opacity(0.22))
    }
}
