import SwiftUI
import SpareCore

/// How to install Spare's privacy profile in System Settings, drawn step by step, and how to remove it later. The
/// pictures are drawings rather than screenshots: they never show anyone's account, and they stay true when Apple
/// moves a button a little.
struct ProfileGuide: View {
    var compact = false

    private var stage: CGFloat { compact ? 104 : 124 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            HStack(alignment: .top, spacing: 6) {
                step(1, "Double-click “Spare Privacy”", "System Settings opens at General › Device Management. It's listed under Downloaded.") {
                    DeviceManagementPicture()
                }
                arrow
                step(2, "Click Install…", "macOS calls it Unverified because it isn't signed by a company. That's expected.") {
                    ProfileSheetPicture()
                }
                arrow
                step(3, "Install, then your password", "macOS asks once more and wants an administrator password. Spare carries on by itself.") {
                    PasswordPicture()
                }
            }
            if !compact {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.uturn.backward.circle.fill").font(.system(size: 15)).foregroundStyle(Ink.sea)
                        .accessibilityHidden(true)
                    Text("Removing it later: click Remove Profile… on this page or on Spare's Profiles page, and enter your password. In System Settings it's under Device Management: select it and click −. Changing a setting later makes a new version that replaces this one once you approve it.")
                        .font(.spare(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle.continuous(10).fill(Ink.wash))
            }
        }
    }

    /// The way from one step to the next, level with the pictures' middle.
    private var arrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Ink.pencil)
            .frame(width: 12)
            .padding(.top, stage / 2 - 6)
            .accessibilityHidden(true)
    }

    private func step<Picture: View>(_ number: Int, _ title: String, _ text: String, @ViewBuilder picture: () -> Picture) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Stage(height: stage) { picture() }
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(number)").font(.spare(size: 10.5, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Ink.brand))
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(title).font(.spare(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if !compact {
                Text(text).font(.spare(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 25)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Pictures

/// A tinted panel the little window rests on, cut off at the bottom so it reads as a close-up.
private struct Stage<Content: View>: View {
    var height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle.continuous(14)
        ZStack(alignment: .top) {
            shape.fill(LinearGradient(colors: [Ink.sea.opacity(0.2), Ink.sea.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
            // A soft light in the corner, for depth.
            Circle().fill(Ink.sparkle.opacity(0.18)).frame(width: 90).blur(radius: 26).offset(x: -50, y: -40)
            content
                .frame(maxWidth: 230)
                .padding(.horizontal, 12).padding(.top, 14)
                .shadow(color: Ink.shade.opacity(0.22), radius: 10, y: 5)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Ink.line, lineWidth: 0.75))
    }
}

/// A small window: title bar with the three coloured buttons, then its content.
private struct PictureWindow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle.continuous(9)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3.5) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) {
                    Circle().fill($0.opacity(0.9)).frame(width: 5.5, height: 5.5)
                }
            }
            .padding(.leading, 7).padding(.top, 6).padding(.bottom, 2)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(shape.fill(Ink.lifted))
        .overlay(shape.strokeBorder(Ink.edge.opacity(0.6), lineWidth: 0.5))
        .clipShape(shape)
    }
}

/// A grey bar standing in for text nobody needs to read.
private struct Bar: View {
    var width: CGFloat
    var height: CGFloat = 3.5
    var body: some View { Capsule().fill(Ink.press).frame(width: width, height: height) }
}

/// Where the pointer goes, with a ring spreading from it like a click.
private struct Pointer: View {
    var symbol = "cursorarrow"
    @State private var pulse = false
    @Environment(\.reduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !reduceMotion {
                Circle().stroke(Color.accentColor, lineWidth: 1.5)
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulse ? 1.5 : 0.4)
                    .opacity(pulse ? 0 : 0.9)
                    .offset(x: -7, y: -7)
                    .animation(.easeOut(duration: 1.3).repeatForever(autoreverses: false), value: pulse)
            }
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .shadow(color: Ink.shade.opacity(0.35), radius: 1.5, y: 1)
        }
        .onAppear { pulse = true }
    }
}

/// System Settings at Device Management, with Spare Privacy under Downloaded.
private struct DeviceManagementPicture: View {
    private let icons: [(Color, Bool)] = [(.gray, false), (.blue, false), (.gray, true), (.orange, false), (.indigo, false)]

    var body: some View {
        PictureWindow {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(icons.indices, id: \.self) { index in
                        let (color, selected) = icons[index]
                        HStack(spacing: 4) {
                            RoundedRectangle.continuous(2).fill(selected ? .white : color.opacity(0.85)).frame(width: 6, height: 6)
                            Capsule().fill(selected ? .white.opacity(0.85) : Ink.press).frame(width: CGFloat([22, 18, 20, 16, 21][index]), height: 3)
                        }
                        .padding(.horizontal, 4).padding(.vertical, 2.5)
                        .background { if selected { RoundedRectangle.continuous(4).fill(Color.accentColor) } }
                    }
                }
                .padding(.horizontal, 4).padding(.top, 4)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Ink.wash)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device Management").font(.spare(size: 8.5, weight: .bold)).lineLimit(1)
                    Text("DOWNLOADED").font(.spare(size: 5.5, weight: .bold)).tracking(0.4).foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.shield.fill").font(.system(size: 10)).foregroundStyle(Ink.sea)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Spare Privacy").font(.spare(size: 7.5, weight: .semibold)).lineLimit(1)
                            Bar(width: 30, height: 2.5)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 5).padding(.vertical, 4)
                    .background(RoundedRectangle.continuous(5).fill(Color.accentColor.opacity(0.14)))
                    .overlay(RoundedRectangle.continuous(5).strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 0.75))
                    .overlay(alignment: .trailing) { Pointer().offset(x: -4, y: 8) }
                    Bar(width: 52, height: 3)
                }
                .padding(.horizontal, 8).padding(.top, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// The profile's own sheet, with Install… to click.
private struct ProfileSheetPicture: View {
    var body: some View {
        PictureWindow {
            VStack(spacing: 3.5) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [Ink.sea.opacity(0.35), Ink.sea.opacity(0.12)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 26, height: 26)
                    Image(systemName: "checkmark.shield.fill").font(.system(size: 14)).foregroundStyle(Ink.sea)
                }
                Text("Spare Privacy").font(.spare(size: 8, weight: .bold))
                HStack(spacing: 2.5) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 5.5))
                    Text("Spare · Unverified").font(.spare(size: 6.5, weight: .semibold))
                }
                .foregroundStyle(Ink.warm)
                Bar(width: 56, height: 2.5).padding(.top, 1)
                HStack(spacing: 5) {
                    Spacer()
                    Text("Cancel").font(.spare(size: 6.5, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2.5).background(Capsule().fill(Ink.press))
                    Text("Install…").font(.spare(size: 6.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2.5).background(Capsule().fill(Color.accentColor))
                        .overlay(alignment: .bottomTrailing) { Pointer().offset(x: 7, y: 11) }
                }
                .padding(.trailing, 8).padding(.top, 3)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// macOS asking to be sure, with the password field.
private struct PasswordPicture: View {
    var body: some View {
        PictureWindow {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle.continuous(5).fill(LinearGradient(colors: [.gray.opacity(0.9), .gray.opacity(0.6)], startPoint: .top, endPoint: .bottom)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Install “Spare Privacy”?").font(.spare(size: 7.5, weight: .bold)).lineLimit(1)
                        Bar(width: 44, height: 2.5)
                    }
                }
                HStack(spacing: 1) {
                    Text("••••••••").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
                    Rectangle().fill(Color.accentColor).frame(width: 1, height: 8)
                }
                .padding(.leading, 5)
                .frame(maxWidth: .infinity, minHeight: 13, alignment: .leading)
                .background(RoundedRectangle.continuous(3.5).fill(Ink.card))
                .overlay(RoundedRectangle.continuous(3.5).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
                HStack {
                    Spacer()
                    Text("Install").font(.spare(size: 6.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2.5).background(Capsule().fill(Color.accentColor))
                        .overlay(alignment: .bottomTrailing) { Pointer().offset(x: 7, y: 11) }
                }
                .padding(.trailing, 2)
            }
            .padding(.horizontal, 9).padding(.top, 3)
        }
    }
}
