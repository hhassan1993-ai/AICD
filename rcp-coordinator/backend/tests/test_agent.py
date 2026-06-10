"""Edge-case verification for the RCPCoordinationAgent state machine.

Covers the two mandated edge cases plus sequencing/HITL invariants:
  EC1: Phase 1 coordinate mismatch > 0.001 m → hard halt, phases locked.
  EC2: All Phase 4 proposals rejected → Phase 5 runs and
       update_element_location is never called.
"""
from __future__ import annotations

import asyncio
from typing import Any

import pytest

from agent import PhaseOrderError, RCPCoordinationAgent, StateError
from mcp_client import RevitMCPClient
from models import AgentStatus, LogEvent, ProposalStatus, StateSnapshot


def make_agent(*, mismatch: bool = False) -> RCPCoordinationAgent:
    client = RevitMCPClient(
        latency_range=(0.0, 0.0),
        simulate_coordinate_mismatch=mismatch,
        rng_seed=42,
    )

    async def sink_log(_: LogEvent) -> None: ...
    async def sink_state(_: StateSnapshot) -> None: ...

    return RCPCoordinationAgent(client, on_log=sink_log, on_state=sink_state,
                                simulate_coordinate_mismatch=mismatch)


def run(coro: Any) -> Any:
    return asyncio.run(coro)


def test_phase_order_is_enforced() -> None:
    agent = make_agent()
    with pytest.raises(PhaseOrderError):
        run(agent.run_phase(2))  # Phase 1 not yet complete


def test_edge_case_1_hard_halt_on_coordinate_mismatch() -> None:
    agent = make_agent(mismatch=True)
    run(agent.run_phase(1))
    assert agent.status == AgentStatus.HALTED
    assert agent.completed_phase == 0
    assert agent.halt_reason is not None and "0.001" in agent.halt_reason
    # Subsequent phases must be locked until reset.
    with pytest.raises(StateError):
        run(agent.run_phase(2))


def test_nominal_run_passes_tolerance() -> None:
    agent = make_agent()
    run(agent.run_phase(1))
    assert agent.status == AgentStatus.IDLE
    assert agent.completed_phase == 1
    assert all(m.within_tolerance for m in agent.models)
    assert all(m.deviation_m <= 0.001 for m in agent.models)


def test_phase_4_pauses_and_gates_writes() -> None:
    agent = make_agent()

    async def flow() -> None:
        await agent.run_phase(1)
        await agent.run_phase(2)
        await agent.run_phase(3)
        await agent.run_phase(4)
        assert agent.status == AgentStatus.AWAITING_AUTHORIZATION
        # No writes may have happened while paused.
        assert agent._client.call_counts["update_element_location"] == 0  # type: ignore[attr-defined]
        # Phase 5 must be refused while authorization is pending.
        with pytest.raises(StateError):
            await agent.run_phase(5)

    run(flow())


def test_edge_case_2_reject_all_then_phase_5_without_writes() -> None:
    agent = make_agent()

    async def flow() -> None:
        for p in (1, 2, 3, 4):
            await agent.run_phase(p)
        decisions = {p.proposal_id: False for p in agent.proposals}
        await agent.authorize(decisions)
        assert agent.completed_phase == 4
        assert all(p.status == ProposalStatus.REJECTED for p in agent.proposals)
        await agent.run_phase(5)
        assert agent.status == AgentStatus.COMPLETE
        counts = agent.snapshot().mcp_call_counts
        assert counts["update_element_location"] == 0
        assert counts["create_tag_and_dimension"] == 0  # nothing applied → nothing tagged

    run(flow())


def test_approved_subset_applies_only_approved() -> None:
    agent = make_agent()

    async def flow() -> None:
        for p in (1, 2, 3, 4):
            await agent.run_phase(p)
        ids = [p.proposal_id for p in agent.proposals]
        decisions = {pid: (i == 0) for i, pid in enumerate(ids)}  # approve first only
        await agent.authorize(decisions)
        counts = agent.snapshot().mcp_call_counts
        assert counts["update_element_location"] == 1
        statuses = [p.status for p in agent.proposals]
        assert statuses[0] == ProposalStatus.APPLIED
        assert all(s == ProposalStatus.REJECTED for s in statuses[1:])

    run(flow())


def test_authorization_requires_complete_decision_set() -> None:
    agent = make_agent()

    async def flow() -> None:
        for p in (1, 2, 3, 4):
            await agent.run_phase(p)
        partial = {agent.proposals[0].proposal_id: True}
        from agent import AuthorizationError
        with pytest.raises(AuthorizationError):
            await agent.authorize(partial)
        # Gate must remain closed after invalid payload.
        assert agent.status == AgentStatus.AWAITING_AUTHORIZATION
        assert agent.snapshot().mcp_call_counts["update_element_location"] == 0

    run(flow())
