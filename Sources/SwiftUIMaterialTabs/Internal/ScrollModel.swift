//
//  Created by Timothy Moose on 1/7/24.
//

import SwiftUI

@MainActor
@Observable
class ScrollModel<Tab> where Tab: Hashable {

    // MARK: - API

    /// Stable identifier for the hidden 1pt reserved item placed outside the lazy stack
    /// in `MaterialTabsScroll`. Used as the target for `scrollTo(id:anchor:)` during
    /// programmatic offset sync. See the reserved item comment in `MaterialTabsScroll`
    /// for why `scrollTo(y:)` cannot be used.
    let reservedItemID = UUID()
    private(set) var appeared = false
    private(set) var bottomMargin: CGFloat = 0
    /// The tab's list is bottom-aligned by its own `ScrollView`: no bottom margin, and tab sync never writes the scroll position.
    private(set) var anchoredToBottom = false

    /// Switches the bottom-anchored mode while the tab is on screen: the bottom margin is recomputed, and
    /// leaving the mode brings the scroll position back in line with the header.
    func setAnchoredToBottom(_ value: Bool) {
        guard value != anchoredToBottom else { return }
        anchoredToBottom = value
        configureBottomMargin()
        if !value {
            syncContentOffsetWithHeader(appearance: false)
        }
    }

    /// Whether the finger, or the deceleration that follows it, is moving the scroll view.
    func setFingerDriven(_ value: Bool) {
        isFingerDriven = value
    }

    /// `anchoredToBottom` is the view's current mode. The offset that follows a switch of mode arrives in the same
    /// layout, before `onChange` passes the switch on, and must be read in the new mode: read in the old one, the
    /// list's jump to its new alignment counts as a scroll and moves the header.
    func contentOffsetChanged(_ offset: CGFloat, anchoredToBottom: Bool) {
        setAnchoredToBottom(anchoredToBottom)
        let oldContentOffset = contentOffset
        contentOffset = anchoredToBottom ? max(0, -offset) : -offset
        let deltaOffset = contentOffset - oldContentOffset
        // A bottom-anchored list also moves under programmatic scrolls, growing rows and prepends; only the
        // finger may move the header.
        if anchoredToBottom && !isFingerDriven { return }
        // Only filter out library-internal programmatic scrolls (tab sync). Consumer-initiated
        // scrollTo(id:) should still notify the header model so it can collapse/expand.
        if !isSyncingWithHeader {
            headerModel?.scrolled(tab: tab, contentOffset: contentOffset, deltaContentOffset: deltaOffset)
        }
    }

    func appeared(headerModel: HeaderModel<Tab>?, scrollPositionBinding: Binding<ScrollPosition>, anchorBinding: Binding<UnitPoint?>) {
        appeared = true
        self.headerModel = headerModel
        self.scrollPositionBinding = scrollPositionBinding
        self.anchorBinding = anchorBinding
        selectedTab = headerModel?.headerContext.selectedTab
        syncContentOffsetWithHeader(appearance: true)
        configureBottomMargin()
    }

    func disappeared() {
        appeared = false
    }

    func selectedTabChanged() {
        guard let headerModel else { return }
        let wasSelected = selectedTab == tab
        selectedTab = headerModel.headerContext.selectedTab
        let isSelected = selectedTab == tab
        // Sync content offset when this tab becomes selected
        if !wasSelected && isSelected {
            syncContentOffsetWithHeader(appearance: false)
        }
    }

    func contentSizeChanged(_ contentSize: CGSize) {
        self.contentSize = contentSize
        configureBottomMargin()
    }

    func headerHeightChanged() {
        syncContentOffsetWithHeader(appearance: false)
    }

    func headerStateChanged() {
        configureBottomMargin()
    }

    /// The scroll view's bottom content inset: the container's safe area plus any bar the tab adds itself
    /// (`safeAreaInset(edge: .bottom)`), and the keyboard while that bar rides on it.
    func bottomInsetChanged(_ inset: CGFloat) {
        guard inset != bottomInset else { return }
        bottomInset = inset
        configureBottomMargin()
    }

    init(tab: Tab) {
        self.tab = tab
    }

    // MARK: - Constants

    // MARK: - Variables

    private let tab: Tab
    /// The active scroll position binding, provided by the view during `appeared()`.
    /// Points to either the consumer's external binding or the view's internal @State.
    private var scrollPositionBinding: Binding<ScrollPosition>?
    /// The active anchor binding, provided by the view during `appeared()`.
    /// Updated during sync to match the calculated UnitPoint for the reserved item.
    private var anchorBinding: Binding<UnitPoint?>?
    /// Cached header offset from when this tab was last active.
    private var cachedOffset: CGFloat?
    private var cachedHeight: CGFloat?
    private weak var headerModel: HeaderModel<Tab>?
    private var contentSize: CGSize?
    private var bottomInset: CGFloat = 0

    private var selectedTab: Tab? {
        didSet {
            guard let headerModel else { return }
            switch (oldValue == tab, selectedTab == tab) {
            case (true, false):
                cachedOffset = headerModel.headerContext.offset
                cachedHeight = headerModel.height
            default: break
            }
        }
    }

    private var contentOffset: CGFloat = 0
    /// Set during library-internal programmatic scrolls (syncContentOffsetWithHeader) and cleared
    /// after a short delay. Prevents reporting programmatic scroll offsets to the header model.
    private var isSyncingWithHeader = false
    /// Set from the scroll view's phase: `true` while the finger drags the list or it decelerates after a drag.
    /// A bottom-anchored list reports its offset to the header only then.
    private var isFingerDriven = false

    // MARK: Configuring the bottom margin

    /// Just enough room below short content for the header to collapse fully, and no more. `headerModel.height`
    /// already leaves out the container's safe area; a bar the tab adds on top of it shortens the visible
    /// part of this scroll view only, so its height comes off the margin too. Without that, short content
    /// scrolls past the collapsed header by the bar's height.
    private func configureBottomMargin() {
        guard let headerModel, let contentSize else { return }
        let tabBottomBar = max(0, bottomInset - headerModel.headerContext.safeArea.bottom)
        let margin = anchoredToBottom
            ? 0
            : max(0, headerModel.height - contentSize.height - headerModel.headerContext.minTotalHeight - tabBottomBar)
        // An observed write invalidates the scroll view even when the value is the same; the inset changes on
        // every keyboard frame.
        if margin != bottomMargin {
            bottomMargin = margin
        }
    }

    // MARK: Adjusting scroll and header state

    /// Scrolls to the desired content offset to maintain continuity when switching tabs
    /// after a header height change.
    ///
    /// Uses `scrollTo(id:anchor:)` targeting a hidden 1pt reserved item rather than
    /// `scrollTo(y:)`. See the reserved item comment in `MaterialTabsScroll` for why.
    ///
    /// The UnitPoint formula positions the reserved item within the visible frame such that
    /// the desired content offset is achieved:
    /// ```
    /// UnitPoint.y = (maxOffset - contentOffset) / (safeHeight - reservedItemHeight)
    /// ```
    ///
    /// Important: the `.scrollPosition()` modifier's `anchor` parameter must be updated
    /// to match the `scrollTo(id:anchor:)` anchor. If the modifier's anchor is `nil`,
    /// the scroll view uses "minimal scroll" behavior and ignores the requested anchor.
    func syncContentOffsetWithHeader(appearance: Bool) {
        guard appeared, let headerModel, let scrollPositionBinding,
                tab == headerModel.headerContext.selectedTab || appearance,
                headerModel.tabsRegistered else { return }
        let deltaHeaderOffset: CGFloat
        if let cachedOffset {
            deltaHeaderOffset = headerModel.headerContext.offset - cachedOffset
        } else {
            deltaHeaderOffset = headerModel.headerContext.offset
        }
        cachedOffset = headerModel.headerContext.offset
        cachedHeight = headerModel.height
        if anchoredToBottom {
            return
        }
        switch headerModel.config.crossTabSyncMode {
        case .resetScrollPosition where
            appearance &&
                headerModel.headerContext.offset < headerModel.headerContext.maxOffset &&
                contentOffset > headerModel.headerContext.offset:
            contentOffset = headerModel.headerContext.offset
        default:
            contentOffset = contentOffset + deltaHeaderOffset
        }
        headerModel.contentOffsetChanged(contentOffset)
        isSyncingWithHeader = true
        let unitPointY = (headerModel.headerContext.maxOffset - contentOffset) / (headerModel.safeHeight - 1)
        let syncAnchor = UnitPoint(x: UnitPoint.top.x, y: unitPointY)
        // The container animates tab selection; an animated write would sweep the offset through values that the
        // header then follows.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            // The .scrollPosition() modifier's anchor must match the scrollTo anchor for positioning to work.
            anchorBinding?.wrappedValue = syncAnchor
            scrollPositionBinding.wrappedValue.scrollTo(id: reservedItemID, anchor: syncAnchor)
        }
        Task {
            try? await Task.sleep(for: .seconds(0.05))
            isSyncingWithHeader = false
        }
    }
}
