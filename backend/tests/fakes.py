"""Test doubles: a fake database and a scripted model. No network, no keys."""


class FakeDB:
    """Stands in for db.UserDB. `tables` maps a table name to rows (or an Exception to raise)."""

    def __init__(self, tables: dict | None = None, user_id: str = "user-1"):
        self.tables = tables or {}
        self.user_id = user_id
        self.selects: list[tuple] = []
        self.inserted: list[tuple] = []

    async def select(self, table, columns="*", *, filters=None, order=None, limit=None):
        self.selects.append((table, columns, filters))
        rows = self.tables.get(table, [])
        if isinstance(rows, Exception):
            raise rows
        return list(rows)

    async def insert(self, table, rows):
        self.inserted.append((table, rows))


def script_llm(monkeypatch, steps: list, prompts: list | None = None):
    """Make llm.generate_json return the given steps in order (an Exception item is raised)."""
    import llm

    queue = list(steps)

    async def fake(prompt, **kwargs):
        if prompts is not None:
            prompts.append(prompt)
        if not queue:
            raise AssertionError("the model was called more times than the test scripted")
        item = queue.pop(0)
        if isinstance(item, Exception):
            raise item
        return item

    monkeypatch.setattr(llm, "generate_json", fake)
    return queue
