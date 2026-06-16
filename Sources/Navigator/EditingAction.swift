//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared
import UIKit

/// An `EditingAction` is an item in the text selection menu.
///
/// iOS provides default actions for copy, share, etc. (see `UIMenuController`),
/// but you can provide custom actions with
/// `EditingAction(title: "Highlight", action: #selector(highlight:))`.
/// Then, implement the selector in one of your classes in the responder chain.
/// Typically, in the `UIViewController` wrapping the navigator view
/// controller.
public struct EditingAction: Hashable {
    /// Default editing actions enabled in the navigator.
    public static var defaultActions: [EditingAction] {
        [copy, share, lookup, translate]
    }

    /// Copy the text selection.
    public static let copy = EditingAction(kind: .native(["copy:"]))

    /// Look up the text selection in the dictionary and other sources.
    ///
    /// On iOS 16+, enabling this action will show two items: Look Up and
    /// Search Web.
    public static let lookup = EditingAction(kind: .native(["lookup", "_lookup:", "define:", "_define:"]))

    /// Translate the text selection.
    public static let translate = EditingAction(kind: .native(["translate:", "_translate:"]))

    /// Share the text selection.
    public static let share = EditingAction(kind: .native(["share:", "_share:"]))

    /// Create a custom editing action.
    ///
    /// You need to implement the selector in one of your classes in the
    /// responder chain. Typically, in the `UIViewController` wrapping the
    /// navigator view controller.
    public init(title: String, action: Selector) {
        self.init(kind: .custom(UIMenuItem(title: title, action: action)))
    }

    enum Kind: Hashable {
        case native([String])
        case custom(UIMenuItem)
    }

    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }

    var actions: [Selector] {
        switch kind {
        case let .native(actions):
            return actions.map { Selector($0) }
        case let .custom(item):
            return [item.action]
        }
    }

    var menuItem: UIMenuItem? {
        switch kind {
        case .native:
            return nil
        case let .custom(item):
            return item
        }
    }
}

protocol EditingActionsControllerDelegate: AnyObject {
    func editingActionsDidPreventCopy(_ editingActions: EditingActionsController)
    func editingActions(_ editingActions: EditingActionsController, shouldShowMenuForSelection selection: Selection) -> Bool
    func editingActions(_ editingActions: EditingActionsController, canPerformAction action: EditingAction, for selection: Selection) -> Bool
}

/// Handles the authorization and check of editing actions.
final class EditingActionsController {
    weak var delegate: EditingActionsControllerDelegate?

    private let actions: [EditingAction]
    private let rights: UserRights
    private let canShare: Bool
    private var isEnabled = true

    init(
        actions: [EditingAction],
        publication: Publication
    ) {
        self.actions = actions
        rights = publication.rights
        canShare = !publication.isProtected
    }

    /// Current user selection contents and frame in the publication view.
    var selection: Selection? {
        didSet {
            if let selection = selection {
                isEnabled = delegate?.editingActions(self, shouldShowMenuForSelection: selection) ?? true
            } else {
                isEnabled = false
            }
            updateSharedMenuController()
        }
    }

    func canPerformAction(_ action: EditingAction) -> Bool {
        action.actions.contains { canPerformAction($0) }
    }

    func canPerformAction(_ selector: Selector) -> Bool {
        // Accessibility editing actions (e.g. Spoken Option in Accessibility
        // system settings) cannot be properly disabled.
        guard !selector.description.hasPrefix("_accessibility") else {
            return true
        }

        guard
            isEnabled,
            let selection = selection,
            let action = actions.first(where: { $0.actions.contains(selector) }),
            isActionAllowed(action)
        else {
            return false
        }

        return delegate?.editingActions(self, canPerformAction: action, for: selection) ?? true
    }

    /// Verifies that the user has the rights to use the given `action`.
    private func isActionAllowed(_ action: EditingAction) -> Bool {
        switch action {
        case .share:
            return canShare
        default:
            return true
        }
    }

    @available(iOS 13.0, *)
    func buildMenu(with builder: UIMenuBuilder) {
        if !canPerformAction(.lookup) {
            builder.remove(menu: .lookup)
        }
        if !canPerformAction(.share) {
            builder.remove(menu: .share)
        }

        // Learn is removed as it seems bugged on iOS 17: it opens a Text
        // Expansion setting which allows to copy the selection.
        // To reproduce, comment out and select Japanese text on a PDF.
        builder.remove(menu: .learn)

        if #available(iOS 16.0, *) {
            // When Copy is enabled, remove the system Copy menu (`.standardEdit`)
            // so it no longer pins Copy to the front of the selection menu. This
            // lets the native Look Up lead; Copy is re-added as a trailing inline
            // command in `insertCustomActions`, keeping it available in the
            // overflow. `.standardEdit` also carries Cut/Paste/Select, which are
            // irrelevant for the read-only navigator selection.
            let demoteCopy = actions.contains(.copy)
            if demoteCopy {
                builder.remove(menu: .standardEdit)
            }
            insertCustomActions(with: builder, demoteCopy: demoteCopy)
        }
    }

    /// Inserts the custom editing actions right after the native Look Up menu,
    /// preserving the order in which the app declared them, and (when Copy was
    /// demoted in `buildMenu`) re-adds Copy as a trailing inline command so it
    /// stays available in the overflow. Without explicit placement, custom
    /// actions bridged through the deprecated `UIMenuController` land at the very
    /// end of the edit menu, after Look Up/Translate/Share.
    @available(iOS 16.0, *)
    private func insertCustomActions(with builder: UIMenuBuilder, demoteCopy: Bool) {
        // The main menu system builds the iPad/Catalyst menu bar; selection
        // actions only belong in the edit menu.
        guard builder.system != .main else {
            return
        }

        let commands = actions
            .compactMap(\.menuItem)
            .map { UICommand(title: $0.title, action: $0.action) }

        if !commands.isEmpty {
            if builder.menu(for: .lookup) != nil {
                // iOS bundles Look Up, Translate and Search Web into a single
                // atomic `.lookup` menu, so inserting a sibling after it would
                // push the custom actions behind all three (into the overflow).
                // Instead, reorder the group's own children: keep Look Up first,
                // then the app's custom actions, then Translate / Search Web.
                // The system-provided elements are reused as-is, so no private
                // lookup selectors are introduced.
                builder.replaceChildren(ofMenu: .lookup) { children in
                    guard !children.isEmpty else { return commands }
                    let lookupSelectors = EditingAction.lookup.actions
                    if let index = children.firstIndex(where: {
                        ($0 as? UICommand).map { lookupSelectors.contains($0.action) } ?? false
                    }) {
                        var rest = children
                        let lookUp = rest.remove(at: index)
                        return [lookUp] + commands + rest
                    }
                    // Fall back to assuming the first item is Look Up.
                    return [children[0]] + commands + Array(children.dropFirst())
                }
            } else {
                // Look Up isn't available (e.g. disabled): keep the custom
                // actions as their own inline group near the front.
                let menu = UIMenu(
                    identifier: UIMenu.Identifier("org.readium.customEditingActions"),
                    options: .displayInline,
                    children: commands
                )
                if builder.menu(for: .standardEdit) != nil {
                    builder.insertSibling(menu, afterMenu: .standardEdit)
                } else {
                    builder.insertChild(menu, atStartOfMenu: .root)
                }
            }
        }

        // Re-add Copy (removed from the front in `buildMenu`) as the last item.
        // The `copy:` selector routes to the navigator view's `copy(_:)`
        // override, so it stays DRM-aware and functional.
        if demoteCopy {
            let copyMenu = UIMenu(
                identifier: UIMenu.Identifier("org.readium.relocatedCopy"),
                options: .displayInline,
                children: [UICommand(
                    title: "Copy",
                    action: #selector(UIResponderStandardEditActions.copy(_:))
                )]
            )

            if builder.menu(for: .share) != nil {
                builder.insertSibling(copyMenu, afterMenu: .share)
            } else {
                builder.insertChild(copyMenu, atEndOfMenu: .root)
            }
        }
    }

    func updateSharedMenuController() {
        if #available(iOS 16.0, *) {
            // Custom actions are inserted through `buildMenu(with:)`;
            // publishing them through the deprecated `UIMenuController` as
            // well would duplicate them in the edit menu.
            return
        }

        var items: [UIMenuItem] = []
        if isEnabled, let selection = selection {
            items = actions
                .filter { delegate?.editingActions(self, canPerformAction: $0, for: selection) ?? true }
                .compactMap(\.menuItem)
        }
        UIMenuController.shared.menuItems = items
        UIMenuController.shared.update()
    }

    // MARK: - Copy

    /// Returns whether the copy interaction is at all allowed. It doesn't
    /// guarantee that the next copy action will be valid, if the license
    /// cancels it.
    var canCopy: Bool {
        canPerformAction(.copy)
    }

    /// Copies the authorized portion of the selection text into the pasteboard.
    @MainActor
    func copy() async {
        guard let text = selection?.locator.text.highlight else {
            return
        }
        guard await rights.copy(text: text) else {
            delegate?.editingActionsDidPreventCopy(self)
            return
        }

        UIPasteboard.general.string = text
    }
}
