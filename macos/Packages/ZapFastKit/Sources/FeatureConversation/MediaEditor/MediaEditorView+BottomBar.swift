/// The editor's bottom bar: the thumbnails, the recipient, the caption
/// field and the send button.

import SwiftUI
import UniformTypeIdentifiers
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

extension MediaEditorView {
    @ViewBuilder
    var bottomBar: some View {
        switch state.mode {
        case .browse:
            browseBottom
        case .crop:
            HStack {
                Button(action: cancelCropping) { Image(systemName: "xmark") }
                    .editorButton()
                    .help("Cancel")
                Spacer()
                if let current, current.edit.hasGeometry {
                    Button("Reset") {
                        change(recorded: false) { $0.resetGeometry() }
                        state.aspect = .free
                    }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.yellow)
                    .transition(.opacity)
                }
                Spacer()
                doneButton(finishCropping)
            }
            .frame(height: 48)
        case .draw:
            HStack(spacing: Metrics.l) {
                ForEach(availableBrushes, id: \.self) { brush in
                    Button {
                        state.brush = brush
                    } label: {
                        Image(systemName: brush.symbol)
                    }
                    .editorButton(active: state.brush == brush, diameter: 44)
                    .help(brush.title)
                    .accessibilityLabel(brush.title)
                }
            }
            .frame(height: 56)
            .frame(maxWidth: .infinity)
        case .text:
            Color.clear.frame(height: 56)
        }
    }

    private var browseBottom: some View {
        VStack(spacing: Metrics.m) {
            if let current {
                caption(for: current)
                    .frame(maxWidth: 560)
            }
            HStack(alignment: .center, spacing: Metrics.m) {
                recipient
                    .frame(maxWidth: .infinity, alignment: .leading)
                thumbnails
                    .layoutPriority(1)
                sendButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .transition(.opacity)
    }

    private var recipient: some View {
        Text(model.chats.chat(chatID).map(model.chats.title(for:)) ?? "")
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, Metrics.m)
            .padding(.vertical, 7)
            .background(.white.opacity(0.1), in: .rect(cornerRadius: Metrics.controlRadius))
            .help("Sending to this chat")
    }

    private var sendButton: some View {
        Button { send() } label: {
            Image(systemName: "paperplane.fill").font(.system(size: 20))
        }
        .editorButton(prominent: true, diameter: 50)
        .overlay(alignment: .topTrailing) {
            if staged.count > 1 {
                Text(staged.count, format: .number)
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(.white, in: .capsule)
                    .offset(x: 4, y: -4)
                    .contentTransition(.numericText())
            }
        }
        .help(staged.count > 1 ? "Send \(staged.count) items" : "Send")
    }

    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: Metrics.s) {
                    ForEach(staged) { attachment in
                        Thumbnail(
                            attachment: attachment,
                            state: state,
                            selected: attachment.id == current?.id,
                            showsRemove: staged.count > 1
                        ) {
                            select(attachment.id)
                        } remove: {
                            withAnimation(.zf(reduceMotion)) { model.removeAttachment(attachment.id, in: chatID) }
                        }
                        .id(attachment.id)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                    Button { addingFiles = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(.white.opacity(0.1), in: .rect(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            )
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Add photos, videos or files")
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: 520)
            .fixedSize(horizontal: true, vertical: false)
            .onChange(of: state.selectedID) { _, id in
                withAnimation(.zf(reduceMotion)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    func caption(for current: Attachment) -> some View {
        VStack(spacing: Metrics.s) {
            if !emoji.suggestions.isEmpty {
                EmojiSuggestions(tracker: emoji)
                    .transition(.opacity)
            } else if !mentions.suggestions.isEmpty {
                MentionSuggestions(tracker: mentions, model: model)
                    .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: Metrics.s) {
                ZStack(alignment: .topLeading) {
                    if current.caption.isEmpty {
                        Text("Add a caption")
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.top, 4)
                            .allowsHitTesting(false)
                    }
                    ComposerTextView(
                        text: captionBinding(current.id),
                        height: $captionHeight,
                        focusToken: "media#\(current.id)",
                        maxHeight: 120,
                        enterSends: model.preferences.enterSends,
                        onSubmit: send,
                        onEdit: {},
                        onPasteFiles: { model.stage(files: $0, in: chatID) },
                        onPasteImage: { picture in
                            if let image = PastedImage(picture) { model.stage(image: image, in: chatID) }
                        },
                        mentions: mentions,
                        emoji: emoji,
                        mentionNames: (model.composerMentions[chatID] ?? []).map(\.name)
                    )
                    .frame(height: captionHeight)
                }
                .frame(minHeight: 30)
            }
            .padding(.horizontal, Metrics.l)
            .padding(.vertical, 5)
            .background(.white.opacity(0.1), in: .rect(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12)))
        }
    }
}
