# git-shadow fish completion
#
# Installation (automatic via symlink):
#   git shadow completion install
#
# Manual installation:
#   ln -sf /path/to/git-shadow/completions/git-shadow.fish \
#     ~/.config/fish/completions/git-shadow.fish

# Disable file completion by default
complete -c git-shadow -f

# ---------------------------------------------------------------------------
# Top-level commands
# ---------------------------------------------------------------------------

set -l top_cmds version install-hooks doctor status commit show annotations completion feature base re-anchor push check config

complete -c git-shadow -n "not __fish_seen_subcommand_from $top_cmds" -a version              -d "show the current version"
complete -c git-shadow -n "not __fish_seen_subcommand_from $top_cmds" -a install-hooks        -d "install pre-commit and pre-push git hooks"
complete -c git-shadow -n "not __fish_seen_subcommand_from $top_cmds" -a doctor               -d "run diagnostic checks on the environment"
complete -c git-shadow -n "not __fish_seen_subcommand_from $top_cmds" -a status               -d "show publishable/public-ahead/diverged state"
complete -c git-shadow -n "not __fish_seen_subcommand_from $top_cmds" -a commit               -d "split staged changes into public and [MEMORY] commits"
complete -c git-shadow -n "not __fish_seen_subcommand_from $top_cmds" -a show                 -d "render source with local annotations"
complete -c git-shadow -n "not __fish_seen_subcommand_from $top_cmds" -a annotations          -d "manage local annotation sidecars"
complete -c git-shadow -n "not __fish_seen_subcommand_from $top_cmds" -a completion           -d "manage shell completion"
complete -c git-shadow -n "not __fish_seen_subcommand_from $top_cmds" -a feature              -d "manage feature branch lifecycle"
complete -c git-shadow -n "not __fish_seen_subcommand_from $top_cmds" -a base                 -d "sync the public/@local base pair"
complete -c git-shadow -n "not __fish_seen_subcommand_from $top_cmds" -a re-anchor            -d "re-anchor a @local branch to new public history"
complete -c git-shadow -n "not __fish_seen_subcommand_from $top_cmds" -a push                 -d "push a public branch with GIT_SHADOW=1"
complete -c git-shadow -n "not __fish_seen_subcommand_from $top_cmds" -a check                -d "audit a public branch"
complete -c git-shadow -n "not __fish_seen_subcommand_from $top_cmds" -a config               -d "manage git-shadow configuration"

# ---------------------------------------------------------------------------
# feature subcommands and flags
# ---------------------------------------------------------------------------

set -l feature_subcmds start publish finish sync

complete -c git-shadow -n "__fish_seen_subcommand_from feature; and not __fish_seen_subcommand_from $feature_subcmds" -a start   -d "create a new public/@local feature branch pair"
complete -c git-shadow -n "__fish_seen_subcommand_from feature; and not __fish_seen_subcommand_from $feature_subcmds" -a publish -d "publish public commits from the @local feature branch"
complete -c git-shadow -n "__fish_seen_subcommand_from feature; and not __fish_seen_subcommand_from $feature_subcmds" -a finish  -d "finalize the feature and integrate [MEMORY] commits"
complete -c git-shadow -n "__fish_seen_subcommand_from feature; and not __fish_seen_subcommand_from $feature_subcmds" -a sync    -d "apply public net diff onto the @local feature branch"

complete -c git-shadow -n "__fish_seen_subcommand_from feature; and __fish_seen_subcommand_from sync" -l recover  -d "recover after public history rewrite"
complete -c git-shadow -n "__fish_seen_subcommand_from feature; and __fish_seen_subcommand_from sync" -l continue -d "resume after manual conflict resolution"
complete -c git-shadow -n "__fish_seen_subcommand_from feature; and __fish_seen_subcommand_from sync" -l abort    -d "abort the sync"

# ---------------------------------------------------------------------------
# base subcommands and flags
# ---------------------------------------------------------------------------

set -l base_subcmds sync

complete -c git-shadow -n "__fish_seen_subcommand_from base; and not __fish_seen_subcommand_from $base_subcmds" -a sync -d "sync the public/@local base pair"

complete -c git-shadow -n "__fish_seen_subcommand_from base; and __fish_seen_subcommand_from sync" -l recover  -d "recover after public history rewrite"
complete -c git-shadow -n "__fish_seen_subcommand_from base; and __fish_seen_subcommand_from sync" -l continue -d "resume after manual conflict resolution"
complete -c git-shadow -n "__fish_seen_subcommand_from base; and __fish_seen_subcommand_from sync" -l abort    -d "abort the sync"

# ---------------------------------------------------------------------------
# check subcommands and flags
# ---------------------------------------------------------------------------

complete -c git-shadow -n "__fish_seen_subcommand_from check; and not __fish_seen_subcommand_from public" -a public -d "audit a public branch for unpromoted files"

# ---------------------------------------------------------------------------
# status flags
# ---------------------------------------------------------------------------

complete -c git-shadow -n "__fish_seen_subcommand_from status" -l json -d "output as JSON"

# ---------------------------------------------------------------------------
# commit flags
# ---------------------------------------------------------------------------

complete -c git-shadow -n "__fish_seen_subcommand_from commit" -s m -l message -d "public commit message"

# ---------------------------------------------------------------------------
# show flags
# ---------------------------------------------------------------------------

complete -c git-shadow -n "__fish_seen_subcommand_from show" -l with-annotations -d "render the annotated view"

# ---------------------------------------------------------------------------
# annotations subcommands and flags
# ---------------------------------------------------------------------------

set -l annotations_subcmds reapply

complete -c git-shadow -n "__fish_seen_subcommand_from annotations; and not __fish_seen_subcommand_from $annotations_subcmds" -a reapply -d "write stored markers into the working tree"

complete -c git-shadow -n "__fish_seen_subcommand_from annotations; and __fish_seen_subcommand_from reapply" -a "(__fish_complete_path)" -d "source path"

# ---------------------------------------------------------------------------
# config subcommands and flags
# ---------------------------------------------------------------------------

function __git_shadow_config_keys
  git-shadow config list 2>/dev/null | awk '{print $1}'
end

set -l config_subcmds list show get set unset

complete -c git-shadow -n "__fish_seen_subcommand_from config; and not __fish_seen_subcommand_from $config_subcmds" -a list  -d "list all known configuration keys"
complete -c git-shadow -n "__fish_seen_subcommand_from config; and not __fish_seen_subcommand_from $config_subcmds" -a show  -d "display the effective merged configuration"
complete -c git-shadow -n "__fish_seen_subcommand_from config; and not __fish_seen_subcommand_from $config_subcmds" -a get   -d "get a single configuration value"
complete -c git-shadow -n "__fish_seen_subcommand_from config; and not __fish_seen_subcommand_from $config_subcmds" -a set   -d "set a configuration value"
complete -c git-shadow -n "__fish_seen_subcommand_from config; and not __fish_seen_subcommand_from $config_subcmds" -a unset -d "remove a configuration value"

complete -c git-shadow -n "__fish_seen_subcommand_from config; and __fish_seen_subcommand_from get set unset" -a "(__git_shadow_config_keys)" -d "config key"
complete -c git-shadow -n "__fish_seen_subcommand_from config; and __fish_seen_subcommand_from show get list" -l json           -d "output as JSON"
complete -c git-shadow -n "__fish_seen_subcommand_from config; and __fish_seen_subcommand_from set unset"     -l project-config -d "save to project-level config (.git-shadow.env)"
complete -c git-shadow -n "__fish_seen_subcommand_from config; and __fish_seen_subcommand_from set unset"     -l user-config    -d "save to user-level config (~/.config/git-shadow/config.env)"

# ---------------------------------------------------------------------------
# completion subcommands
# ---------------------------------------------------------------------------

complete -c git-shadow -n "__fish_seen_subcommand_from completion; and not __fish_seen_subcommand_from install" -a install -d "install shell completion into your shell config"

# ---------------------------------------------------------------------------
# re-anchor / push take a branch name
# ---------------------------------------------------------------------------

complete -c git-shadow -n "__fish_seen_subcommand_from re-anchor push" -a "(git branch --format='%(refname:short)' 2>/dev/null)" -d "branch"
