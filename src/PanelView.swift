import AppKit
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: PanelModel
    var scrolls = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // The list is capped to what the screen can show and scrolls past that.
            // Without the cap the panel grew with the row count and ran off the bottom.
            // A scroll view has no content height of its own, so it is only used once
            // the estimate says the list is too tall; a short list keeps its exact size.
            if scrolls && model.estimatedContentHeight > PanelModel.maxListHeight {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        content
                    }
                }
            } else {
                content
            }
            if let status = model.status {
                Divider()
                Text(status)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 380)
    }

    @ViewBuilder private var content: some View {
        if let picker = model.picker {
            pickerList(picker)
        } else if let hint = model.emptyHint {
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ForEach(model.groups) { group in
                machineHeader(group)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Button {
                                model.onJump?(row.session)
                            } label: {
                                SessionRowView(row: row)
                                    // Fill the width so the trailing cluster
                                    // sits at the edge, and so the whole row
                                    // stays clickable, not only the text.
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("go to this session")

                            Text(row.age)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .offset(y: 1)

                            // A sibling of the row button, not nested inside
                            // its label: a button inside another button's
                            // label never gets its own clicks.
                            Button {
                                model.onDismiss?(row.session)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    // Padding gives the glyph a hit area.
                                    .padding(6)
                                    .contentShape(Rectangle())
                                    // The symbol's own baseline sits low, so
                                    // align on its centre instead: the point
                                    // half a cap height below centre lands on
                                    // the digit baseline. 3.5 is that half
                                    // height for the 10.5pt age text.
                                    .alignmentGuide(.firstTextBaseline) { box in
                                        box[VerticalAlignment.center] + 3.5
                                    }
                            }
                            .buttonStyle(.plain)
                            .help("hide this row")
                        }
                        .padding(.trailing, 12)
                        if row.id != group.rows.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
        }
    }

    /// Names the machine for the rows under it. Grouping is the only reason this
    /// exists, so a single machine still gets one.
    private func machineHeader(_ group: RowGroup) -> some View {
        HStack(spacing: 5) {
            Text(group.host)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            if group.isLocal {
                Text("this machine")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if let connection = group.connection {
                Text(connection)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 5)
    }

    /// Which of several tabs in the same folder did you mean?
    private func pickerList(_ picker: TabPicker) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(picker.label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 9)
                .padding(.bottom, 5)
            ForEach(picker.tabs) { tab in
                Button {
                    model.onPick?(tab)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(tab.name)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button {
                model.picker = nil
            } label: {
                Text("Cancel")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Agents")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if model.attentionCount > 0 {
                Text("\(model.attentionCount) need you")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            Text(model.subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 8)
    }
}

struct SessionRowView: View {
    let row: SessionRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            SessionDot(accent: row.accent, pulsing: row.isWorking)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(row.agent)
                        .font(.system(size: 11.5, weight: .medium))
                    Text(row.cwd)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let tab = row.tab {
                        Text("(\(tab))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 150, alignment: .leading)
                            .help(tab)
                    }
                }
                Text(row.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(row.state == .idle || row.state == .waiting
                                     ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
        }
        // The age and the x are the row's trailing cluster and live in the
        // container, so the whole row button fills the space between them.
        .padding(.leading, 14)
        .padding(.vertical, 8)
    }
}

/// The row's dot, which breathes while a turn is in flight.
///
/// A working session is quiet on the wire between tool calls, so without the
/// pulse a busy row and a stuck one look the same. The pulse is a layer animation,
/// so the render server runs it and SwiftUI builds no frame for it. A SwiftUI
/// `repeatForever` on a state value read by the body rebuilt the display list
/// every frame, which made an open panel cost a fifth of a core.
struct SessionDot: View {
    let accent: Color
    let pulsing: Bool

    var body: some View {
        DotView(accent: accent, pulsing: pulsing)
            .frame(width: 6, height: 6)
            .offset(y: -3)
    }
}

private struct DotView: NSViewRepresentable {
    let accent: Color
    let pulsing: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 3
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let layer = view.layer else { return }
        layer.backgroundColor = NSColor(accent).cgColor
        if pulsing {
            guard layer.animation(forKey: "pulse") == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: "pulse")
        } else {
            // A row that stops working must stop animating: an animation that is not
            // removed keeps running, and keeps its layer redrawing.
            layer.removeAnimation(forKey: "pulse")
            layer.opacity = 1
        }
    }
}
