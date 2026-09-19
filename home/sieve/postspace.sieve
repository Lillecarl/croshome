# Incoming mail rules for carl@postspace.net, on Migadu.
#
# This file is the source of truth. `sieve push` uploads it and makes it the
# active script. Nothing else writes it.
#
# Do not edit filters in the Migadu webmail. A save there uploads the
# webmail's own `rainloop.user` and makes it active, and every rule below
# then stops running. `sieve list` shows which script is active.
#
# Migadu's ManageSieve proxy has no `include`, so one script holds all rules.
# It accepts these extensions, and rejects a `require` of any other:
#
#   fileinto envelope encoded-character imap4flags variables relational
#   vacation copy regex date index mailbox subaddress body editheader
#   comparator-i;octet comparator-i;ascii-casemap comparator-i;ascii-numeric
#   comparator-i;unicode-casemap
#
# `sieve check` validates this file on the server and stores nothing. Run it
# before every push. It reports the line and the column of an error.

require ["fileinto"];

# Both domains carry a catch-all into this one mailbox, so `chatgpt@` is an
# address of it. This rule keeps the mail and sends a copy on.
#
# It reads the To and CC headers, not the envelope. A bcc to this address
# therefore does not match. `envelope "to"` matches a bcc and the server
# supports it. That is a change of behaviour, not a correction, so it needs
# a decision first.
if header :contains ["To", "CC"] "chatgpt@lillecarl.com"
{
    fileinto "INBOX";
    redirect "info@rc-butiken.se";
    stop;
}
