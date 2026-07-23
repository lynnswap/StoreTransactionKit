import Foundation
import Synchronization

package final class DirectOperationReportingAuthority: Sendable {
    private enum ParticipantState: Equatable {
        case attached
        case abandoned
    }

    private struct State {
        var participants: [UUID: ParticipantState] = [:]
        var delivered = false
        var report: StoreTransactionBackgroundFailure?
        var claimed = false
    }

    private final class Node: @unchecked Sendable {
        var parent: Node?
        let state = Mutex(State())
    }

    private static let graph = Mutex(())
    private let node = Node()

    package init() {}

    fileprivate func attach(abandoned: Bool) -> UUID {
        withState { state in
            precondition(!state.claimed)
            let id = UUID()
            state.participants[id] = abandoned ? .abandoned : .attached
            return id
        }
    }

    fileprivate func succeed(participant id: UUID) {
        withState { state in
            _ = state.participants.removeValue(forKey: id)
        }
    }

    fileprivate func fail(
        participant id: UUID,
        report: StoreTransactionBackgroundFailure?
    ) -> StoreTransactionBackgroundFailure? {
        withState { state in
            guard state.participants[id] != nil else { return nil }
            if state.report == nil {
                state.report = report
            }
            return claimReportIfAbandoned(state: &state)
        }
    }

    fileprivate func abandon(
        participant id: UUID
    ) -> StoreTransactionBackgroundFailure? {
        withState { state in
            guard state.participants[id] != nil else { return nil }
            state.participants[id] = .abandoned
            return claimReportIfAbandoned(state: &state)
        }
    }

    fileprivate func deliver(participant id: UUID) {
        withState { state in
            guard state.participants.removeValue(forKey: id) != nil else {
                return
            }
            state.delivered = true
        }
    }

    package func failWithoutParticipant(
        report: StoreTransactionBackgroundFailure
    ) -> StoreTransactionBackgroundFailure? {
        withState { state in
            if state.report == nil {
                state.report = report
            }
            return claimReportIfAbandoned(state: &state)
        }
    }

    package func record(
        report: StoreTransactionBackgroundFailure
    ) {
        withState { state in
            if state.report == nil {
                state.report = report
            }
        }
    }

    package func merge(
        into authority: DirectOperationReportingAuthority
    ) {
        Self.graph.withLock { _ in
            let source = root(of: node)
            let target = root(of: authority.node)
            guard source !== target else { return }

            let sourceState = source.state.withLock { $0 }
            target.state.withLock { targetState in
                precondition(
                    !sourceState.claimed
                        && !sourceState.delivered
                        && !targetState.claimed
                        && !targetState.delivered
                )
                precondition(
                    sourceState.report == nil || targetState.report == nil
                )
                for (id, participant) in sourceState.participants {
                    precondition(targetState.participants[id] == nil)
                    targetState.participants[id] = participant
                }
                if targetState.report == nil {
                    targetState.report = sourceState.report
                }
            }
            source.parent = target
        }
    }

    private func withState<Result: Sendable>(
        _ body: (inout sending State) -> sending Result
    ) -> Result {
        Self.graph.withLock { _ in
            root(of: node).state.withLock(body)
        }
    }

    private func root(of node: Node) -> Node {
        var node = node
        while let parent = node.parent {
            node = parent
        }
        return node
    }

    private func claimReportIfAbandoned(
        state: inout State
    ) -> StoreTransactionBackgroundFailure? {
        guard !state.claimed, !state.delivered, let report = state.report else {
            return nil
        }
        guard state.participants.values.allSatisfy({ $0 == .abandoned }) else {
            return nil
        }
        state.claimed = true
        return report
    }
}

package final class DirectOperationObservation: Sendable {
    package struct Binding: Sendable {
        fileprivate let participantID: UUID
        fileprivate let authority: DirectOperationReportingAuthority
    }

    private enum Disposition: Equatable {
        case attached
        case abandoned
        case delivered
    }

    private struct State {
        var disposition: Disposition = .attached
        var binding: Binding?
    }

    private let state = Mutex(State())

    package init() {}

    package func bind(
        to authority: DirectOperationReportingAuthority
    ) -> Binding {
        state.withLock { state in
            precondition(state.binding == nil)
            precondition(state.disposition != .delivered)
            let binding = Binding(
                participantID: authority.attach(
                    abandoned: state.disposition == .abandoned
                ),
                authority: authority
            )
            state.binding = binding
            return binding
        }
    }

    package func succeed(_ binding: Binding) {
        let active = state.withLock { state -> Binding in
            precondition(state.binding?.participantID == binding.participantID)
            state.binding = nil
            return binding
        }
        active.authority.succeed(participant: active.participantID)
    }

    package func fail(
        _ binding: Binding,
        report: StoreTransactionBackgroundFailure?
    ) -> StoreTransactionBackgroundFailure? {
        let active = state.withLock { state -> Binding in
            precondition(state.binding?.participantID == binding.participantID)
            return binding
        }
        return active.authority.fail(
            participant: active.participantID,
            report: report
        )
    }

    package func abandon() -> StoreTransactionBackgroundFailure? {
        let active = state.withLock { state -> Binding? in
            guard state.disposition != .delivered else { return nil }
            state.disposition = .abandoned
            return state.binding
        }
        guard let active else { return nil }
        return active.authority.abandon(participant: active.participantID)
    }

    package func deliver() {
        let active = state.withLock { state -> Binding? in
            guard state.disposition != .delivered else { return nil }
            state.disposition = .delivered
            defer { state.binding = nil }
            return state.binding
        }
        guard let active else { return }
        active.authority.deliver(participant: active.participantID)
    }
}
