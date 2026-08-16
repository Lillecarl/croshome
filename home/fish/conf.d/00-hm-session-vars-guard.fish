#! /usr/bin/env fish

# hm-session-vars.sh exports __HM_SESS_VARS_SOURCED and returns early when it
# is already set, so a nested shell inherits whatever the outer one started
# with and never sees a newer generation. conf.d is read before config.fish,
# where home-manager sources the vars, so erasing the guard here makes every
# shell re-read them.
set --erase __HM_SESS_VARS_SOURCED
