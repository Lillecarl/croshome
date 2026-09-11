import sqlite3


class Mailbox:
    """Store-and-forward queue for messages sent to offline sessions."""

    def __init__(self, path):
        self._db = sqlite3.connect(str(path))
        self._db.execute(
            """CREATE TABLE IF NOT EXISTS mailbox (
            msg_id TEXT PRIMARY KEY, to_name TEXT NOT NULL, to_session TEXT,
            kind TEXT, from_addr TEXT, topic TEXT, reply_to TEXT, ts REAL NOT NULL,
            payload BLOB NOT NULL)"""
        )
        cols = {row[1] for row in self._db.execute("PRAGMA table_info(mailbox)")}
        if "kind" not in cols:
            # The v0 store predates message kinds.
            self._db.execute("ALTER TABLE mailbox ADD COLUMN kind TEXT")
        self._db.commit()

    def put(
        self,
        msg_id,
        to_name,
        to_session,
        kind,
        from_addr,
        topic,
        reply_to,
        ts,
        payload,
    ):
        # Column names, not position: a store migrated from v0 has `kind`
        # appended last, and a positional INSERT would feed `ts` a NULL.
        self._db.execute(
            """INSERT OR REPLACE INTO mailbox
            (msg_id, to_name, to_session, kind, from_addr, topic, reply_to, ts, payload)
            VALUES (?,?,?,?,?,?,?,?,?)""",
            (msg_id, to_name, to_session, kind, from_addr, topic, reply_to, ts, payload),
        )
        self._db.commit()

    def take(self, to_name, to_session):
        rows = self._db.execute(
            """SELECT msg_id, to_name, to_session, kind, from_addr, topic, reply_to, ts, payload
            FROM mailbox WHERE to_name = ? AND (to_session IS NULL OR to_session = ?)
            ORDER BY ts""",
            (to_name, to_session),
        ).fetchall()
        if rows:
            self._db.executemany(
                "DELETE FROM mailbox WHERE msg_id = ?", [(r[0],) for r in rows]
            )
            self._db.commit()
        return rows

    def prune(self, max_age, now_ts):
        cur = self._db.execute("DELETE FROM mailbox WHERE ts < ?", (now_ts - max_age,))
        self._db.commit()
        return cur.rowcount
