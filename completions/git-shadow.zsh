#compdef git-shadow
# git-shadow zsh completion
#
# Installation:
#   Add to your ~/.zshrc:
#     source /path/to/git-shadow/completions/git-shadow.zsh
#
#   Or place this file in a directory on your $fpath and run:
#     compinit

_git_shadow() {
  local context state line
  typeset -A opt_args

  _arguments -C \
    '1: :_git_shadow_commands' \
    '*:: :->args'

  case $state in
    args)
      case $line[1] in
        feature)    _git_shadow_feature ;;
        base)       _git_shadow_base ;;
        check)      _git_shadow_check ;;
        config)     _git_shadow_config ;;
        status)     _arguments '--json[output as JSON]' ;;
        commit)     _arguments '-m[public commit message]:message:' '--message[public commit message]:message:' ;;
        show)       _arguments '--with-annotations[render the annotated view]' ;;
        annotations) _git_shadow_annotations ;;
        completion) _arguments '1: :_git_shadow_completion_subcommands' ;;
        push|re-anchor) _arguments '*:branch:__git_refs2' ;;
      esac
      ;;
  esac
}

_git_shadow_commands() {
  local commands
  commands=(
    'version:show the current git-shadow version'
    'install-hooks:install pre-commit and pre-push git hooks'
    'doctor:run diagnostic checks on the environment and repository'
    'status:show publishable/public-ahead/diverged state'
    'commit:split staged changes into public and [MEMORY] commits'
    'show:render source with local annotations'
    'annotations:manage local annotation sidecars'
    'completion:manage shell completion'
    'feature:manage the feature branch lifecycle'
    'base:sync the public/@local base pair'
    're-anchor:re-anchor a @local branch to new public history'
    'push:push a public branch with GIT_SHADOW=1'
    'check:audit a public branch'
    'config:manage git-shadow configuration'
  )
  _describe 'command' commands
}

_git_shadow_feature() {
  local context state line

  _arguments -C \
    '1: :_git_shadow_feature_subcommands' \
    '*:: :->args'

  case $state in
    args)
      case $line[1] in
        sync)
          _arguments \
            '--recover[recover after public history rewrite]' \
            '--continue[resume after manual conflict resolution]' \
            '--abort[abort the sync]'
          ;;
        start)
          _arguments \
            '--worktree[create a worktree under WORKTREE_ROOT for <name>@local]' \
            '--worktree-dir[create the feature worktree at the given path]:path:_files -/'
          ;;
        finish)
          _arguments \
            '--no-pull[skip git pull of the public base]' \
            '--keep-branches[keep both feature branches]' \
            '--keep-worktree[keep the feature worktree and <name>@local]' \
            '--continue[resume after manual conflict resolution]' \
            '--abort[abort the finish]' \
            '--mark-applied[record a [MEMORY] sha as already applied]:sha'
          ;;
      esac
      ;;
  esac
}

_git_shadow_feature_subcommands() {
  local subcommands
  subcommands=(
    'start:create a new public/@local feature branch pair'
    'publish:publish public commits from the @local feature branch'
    'finish:finalize the feature and integrate [MEMORY] commits'
    'sync:apply public net diff onto the @local feature branch'
  )
  _describe 'subcommand' subcommands
}

_git_shadow_base() {
  local context state line

  _arguments -C \
    '1: :_git_shadow_base_subcommands' \
    '*:: :->args'

  case $state in
    args)
      case $line[1] in
        sync)
          _arguments \
            '--recover[recover after public history rewrite]' \
            '--continue[resume after manual conflict resolution]' \
            '--abort[abort the sync]'
          ;;
      esac
      ;;
  esac
}

_git_shadow_base_subcommands() {
  local subcommands
  subcommands=(
    'sync:sync the public/@local base pair'
  )
  _describe 'subcommand' subcommands
}

_git_shadow_config_keys() {
  local -a keys
  keys=(${(f)"$(git-shadow config list 2>/dev/null | awk '{print $1}')"})
  _describe 'config key' keys
}

_git_shadow_config() {
  local context state line

  _arguments -C \
    '1: :_git_shadow_config_subcommands' \
    '*:: :->args'

  case $state in
    args)
      case $line[1] in
        get)
          _arguments \
            '1: :_git_shadow_config_keys' \
            '--json[output as JSON]'
          ;;
        set|unset)
          _arguments \
            '1: :_git_shadow_config_keys' \
            '--project-config[save to project-level config (.git-shadow.env)]' \
            '--user-config[save to user-level config (~/.config/git-shadow/config.env)]'
          ;;
        show|list)
          _arguments '--json[output as JSON]'
          ;;
      esac
      ;;
  esac
}

_git_shadow_config_subcommands() {
  local subcommands
  subcommands=(
    'list:list all known configuration keys'
    'show:display the effective merged configuration with source tiers'
    'get:get a single configuration value'
    'set:set a configuration value'
    'unset:remove a configuration value'
  )
  _describe 'subcommand' subcommands
}

_git_shadow_annotations() {
  _arguments \
    '1: :_git_shadow_annotations_subcommands' \
    '*:: :->args'

  case $state in
    args)
      case $line[1] in
        reapply) _arguments '*:path:_path_files' ;;
      esac
      ;;
  esac
}

_git_shadow_annotations_subcommands() {
  local subcommands
  subcommands=(
    'reapply:write stored markers into the working tree'
  )
  _describe 'subcommand' subcommands
}

_git_shadow_check() {
  _arguments '1: :_git_shadow_check_subcommands' '*:branch:__git_refs2'
}

_git_shadow_check_subcommands() {
  local subcommands
  subcommands=(
    'public:audit a public branch for unpromoted files'
  )
  _describe 'subcommand' subcommands
}

_git_shadow_completion_subcommands() {
  local subcommands
  subcommands=(
    'install:install shell completion into your shell config'
  )
  _describe 'subcommand' subcommands
}

# Register completion for git-shadow binary
compdef _git_shadow git-shadow

# Register for "git shadow" invocation (zsh git completion integration)
# zsh's _git function calls _git-<subcommand> for external git commands.
_git-shadow() { _git_shadow }
