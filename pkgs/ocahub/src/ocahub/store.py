import sqlite3


class Mailbox:
    """Store-and-forward queue for messages sent to offline sessions."""

    def __init__(self, path):
        self._db = sqlite3.connect(str(path))
        self._db.execute(
            """CREATE TABLE IF NOT EXISTS mailbox (
            msg_id TEXT PRIMARY KEY, to_name TEXT NOT NULL, to_session TEXT,
            from_addr TEXT, topic TEXT, reply_to TEXT, ts REAL NOT NULL,
            payload BLOB NOT NULL)"""
        )
        self._db.commit()

    def put(self, msg_id, to_name, to_session, from_addr, topic, reply_to, ts, payload):
        self._db.execute(
            "INSERT OR REPLACE INTO mailbox VALUES (?,?,?,?,?,?,?,?)",
            (msg_id, to_name, to_session, from_addr, topic, reply_to, ts, payload),
        )
        self._db.commit()

    def take(self, to_name, to_session):
        rows = self._db.execute(
            """SELECT msg_id, to_name, to_session, from_addr, topic, reply_to, ts, payload
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
