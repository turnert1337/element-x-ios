//
// TJ fork: Start chat from inside a room (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3, D3 + §5.1 (ForkStartChat action map). Builds upstream's own
// StartChatFlowCoordinator exactly as ChatsTabFlowCoordinator.swift:615-650 does, presents it through the split's sheet,
// handles every action (room, space, cancelled, room directory) and retains the flow (and the directory screen) for as long
// as it is shown. A new chat opens as a child of the current room (R12).
//

import Combine
import SwiftUI

final class ForkStartChatPresenter {
    private let flowParameters: CommonFlowParameters
    private weak var stack: NavigationStackCoordinator?
    private weak var flow: RoomFlowCoordinator?
    private var startChatFlowCoordinator: StartChatFlowCoordinator?
    private var roomDirectoryCoordinator: RoomDirectorySearchScreenCoordinator?
    private var cancellables = Set<AnyCancellable>()

    init(flowParameters: CommonFlowParameters, stack: NavigationStackCoordinator, flow: RoomFlowCoordinator?) {
        self.flowParameters = flowParameters
        self.stack = stack
        self.flow = flow
    }

    func present() {
        guard let stack, startChatFlowCoordinator == nil else { return }
        let userSession = flowParameters.userSession
        let navigationStackCoordinator = NavigationStackCoordinator()
        let coordinator = StartChatFlowCoordinator(entryPoint: .startChat,
                                                   userDiscoveryService: UserDiscoveryService(clientProxy: userSession.clientProxy),
                                                   navigationStackCoordinator: navigationStackCoordinator,
                                                   flowParameters: flowParameters)
        coordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .finished(let result):
                    dismissSheet()
                    switch result {
                    case .room(let roomID):
                        flow?.handleAppRoute(.childRoom(roomID: roomID, via: []), animated: true)
                    case .space(let spaceRoomListProxy):
                        flow?.handleAppRoute(.childRoom(roomID: spaceRoomListProxy.id, via: []), animated: true)
                    case .cancelled:
                        break
                    }
                case .showRoomDirectory:
                    dismissSheet()
                    presentRoomDirectory()
                }
            }
            .store(in: &cancellables)

        startChatFlowCoordinator = coordinator
        coordinator.start()
        stack.setSheetCoordinator(navigationStackCoordinator, animated: true) { [weak self] in
            // Swipe-down or a hierarchy change also lands here: release the flow.
            self?.startChatFlowCoordinator = nil
        }
    }

    private func dismissSheet() {
        stack?.setSheetCoordinator(nil)
        startChatFlowCoordinator = nil
    }

    private func presentRoomDirectory() {
        guard let stack else { return }
        let coordinator = RoomDirectorySearchScreenCoordinator(parameters: .init(userSession: flowParameters.userSession,
                                                                                 userIndicatorController: flowParameters.userIndicatorController))
        coordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .selectAlias(let alias):
                    dismissRoomDirectory()
                    // RoomFlowCoordinator ignores `.childRoomAlias` ("converted one level above"), so resolve it here
                    // the way ChatsTabFlowCoordinator does, then route the room id.
                    let clientProxy = flowParameters.userSession.clientProxy
                    Task { [weak self] in
                        guard case .success(let resolved) = await clientProxy.resolveRoomAlias(alias) else { return }
                        self?.flow?.handleAppRoute(.childRoom(roomID: resolved.roomId, via: resolved.servers), animated: true)
                    }
                case .selectRoomID(let roomID):
                    dismissRoomDirectory()
                    flow?.handleAppRoute(.childRoom(roomID: roomID, via: []), animated: true)
                case .dismiss:
                    dismissRoomDirectory()
                }
            }
            .store(in: &cancellables)
        roomDirectoryCoordinator = coordinator
        stack.setFullScreenCoverCoordinator(coordinator, animated: true) { [weak self] in
            self?.roomDirectoryCoordinator = nil
        }
    }

    private func dismissRoomDirectory() {
        stack?.setFullScreenCoverCoordinator(nil)
        roomDirectoryCoordinator = nil
    }
}
