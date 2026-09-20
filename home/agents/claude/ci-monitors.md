## CI monitors

Arm one with `gh run watch --exit-status <run-id>` in the background. It
blocks until the run ends and exits non-zero on failure, so the task
notification carries the verdict. No polling.

Run it bare. A pipe (`gh run watch ... | tail`) makes `$?` report the last
command's status, so a red run reads as success.
