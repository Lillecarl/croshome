"""The host-to-guest link for the Virtualization.framework builder.

Three small daemons, one shared framing. The proxy and the supervisor run on
the Mac; the guest agent runs inside the Linux builder. Every connection the
host forwards is registered with the supervisor, so idle shutdown counts
sessions instead of grepping the process table.
"""

from __future__ import annotations
