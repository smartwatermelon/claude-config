"""Reference controller state machine for denial and completion integrity.

No CLI, hook, transport or live policy is attached. A future trusted controller
must own this state outside the agent environment and authenticate observations,
parent registration, completion evidence and human decisions. These methods
are not proof that same-user Claude hooks can implement that trust boundary.
"""

from dataclasses import dataclass, field


@dataclass
class Workflow:
    root: str
    members: set = field(default_factory=set)
    pending: set = field(default_factory=set)
    acknowledged: set = field(default_factory=set)
    blocked: bool = False
    completed: bool = False
    evidence: set = field(default_factory=set)

    def __post_init__(self):
        self.members.add(self.root)

    def register_child(self, parent, child):
        if parent not in self.members or child in self.members or not child:
            raise ValueError("invalid session relationship")
        self.members.add(child)

    def deny(self, session, event_id):
        if session not in self.members or not event_id:
            raise ValueError("uncorrelated denial")
        self.pending.add(event_id)
        self.blocked = True
        self.completed = False
        # Invalidate evidence from before a denial. New completion must be
        # independently verified after the human has resolved the blockage.
        self.evidence.clear()
        return {"status": "blocked", "notify": self.root,
                "denial_id": event_id, "resume": "human decision required"}

    def may_execute(self, session):
        # Freeze every tool in this tree: aliases, MCP and child processes do
        # not require a shell equivalence engine to be treated consistently.
        return session in self.members and not self.blocked and not self.completed

    def acknowledge(self, event_id):
        if event_id not in self.pending:
            raise ValueError("unknown denial")
        self.acknowledged.add(event_id)

    def resolve_by_controller(self, event_ids):
        """Trusted-controller API, NEVER expose this as an agent capability.

        The real adapter must require a fresh human decision bound to these
        denial IDs and this workflow. A model saying 'approved' is not one.
        Resolution permits replanning; it does not expand execution authority.
        """
        event_ids = set(event_ids)
        if not event_ids or not event_ids <= self.acknowledged:
            raise ValueError("denial has not been reported")
        self.pending -= event_ids
        self.acknowledged -= event_ids
        self.blocked = bool(self.pending)

    def verify_by_controller(self, evidence_id):
        if self.blocked or not evidence_id:
            raise ValueError("cannot verify blocked work")
        self.evidence.add(evidence_id)

    def finish(self, status, required_evidence=()):
        if status not in ("completed", "partial", "blocked"):
            raise ValueError("invalid completion status")
        if status == "completed":
            required = set(required_evidence)
            if self.blocked or not required or not required <= self.evidence:
                raise ValueError("completion is not verified")
            self.completed = True
        else:
            self.completed = False
            if self.blocked:
                status = "blocked"
        return {"status": status, "unresolved_denials": len(self.pending)}
