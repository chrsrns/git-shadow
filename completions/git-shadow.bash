#!/usr/bin/env bash
# git-shadow bash completion
#
# Installation:
#   Add to your ~/.bashrc or ~/.bash_profile:
#     source /path/to/git-shadow/completions/git-shadow.bash
#
#   Or for npm/curl installs:
#     source ~/.local/share/git-shadow/completions/git-shadow.bash

_git_shadow() {
  local cur
  cur="${COMP_WORDS[COMP_CWORD]}"

  # Support both "git-shadow <cmd>" and "git shadow <cmd>" invocations.
  # Determine the offset of the first subcommand in COMP_WORDS.
  local offset=1
  [[ "${COMP_WORDS[0]}" == "git" ]] && offset=2

  local cmd="${COMP_WORDS[$offset]:-}"
  local subcmd="${COMP_WORDS[$((offset + 1))]:-}"
  local pos=$(( COMP_CWORD - offset ))

  # Options that take a value consume the next word: no help candidates there.
  if [[ $pos -ge 1 ]]; then
    local prev="${COMP_WORDS[$((COMP_CWORD - 1))]:-}"
    case "$prev" in
      --worktree-dir)
        mapfile -t COMPREPLY < <(compgen -d -- "$cur")
        return
        ;;
      -m|--message|--mark-applied)
        COMPREPLY=()
        return
        ;;
    esac
  fi

  local branches
  branches="$(git branch --format='%(refname:short)' 2>/dev/null)"

  # Complete top-level command
  if [[ $pos -le 0 ]]; then
    mapfile -t COMPREPLY < <(compgen -W "version install-hooks doctor status commit show annotations local completion feature base re-anchor push check config help -h --help" -- "$cur")
    return
  fi

  case "$cmd" in
    feature)
      if [[ $pos -eq 1 ]]; then
        mapfile -t COMPREPLY < <(compgen -W "start publish finish sync list help -h --help" -- "$cur")
      else
        case "$subcmd" in
          sync)    mapfile -t COMPREPLY < <(compgen -W "--recover --continue --abort -h --help" -- "$cur") ;;
          start)   mapfile -t COMPREPLY < <(compgen -W "--worktree --worktree-dir -h --help" -- "$cur") ;;
          list)    mapfile -t COMPREPLY < <(compgen -W "--json -h --help" -- "$cur") ;;
          finish)  mapfile -t COMPREPLY < <(compgen -W "--no-pull --keep-branches --keep-worktree --continue --abort --mark-applied -h --help" -- "$cur") ;;
          publish) mapfile -t COMPREPLY < <(compgen -W "-h --help" -- "$cur") ;;
        esac
      fi
      ;;
    base)
      if [[ $pos -eq 1 ]]; then
        mapfile -t COMPREPLY < <(compgen -W "sync help -h --help" -- "$cur")
      else
        case "$subcmd" in
          sync) mapfile -t COMPREPLY < <(compgen -W "--recover --continue --abort -h --help" -- "$cur") ;;
        esac
      fi
      ;;
    config)
      if [[ $pos -eq 1 ]]; then
        mapfile -t COMPREPLY < <(compgen -W "list show get set unset help -h --help" -- "$cur")
      elif [[ $pos -eq 2 ]]; then
        case "$subcmd" in
          get|set|unset)
            local keys
            keys="$(git-shadow config list 2>/dev/null | awk '{print $1}')"
            mapfile -t COMPREPLY < <(compgen -W "$keys -h --help" -- "$cur")
            ;;
          show|list) mapfile -t COMPREPLY < <(compgen -W "--json -h --help" -- "$cur") ;;
        esac
      else
        case "$subcmd" in
          show|get|list) mapfile -t COMPREPLY < <(compgen -W "--json -h --help" -- "$cur") ;;
          set|unset)     mapfile -t COMPREPLY < <(compgen -W "--project-config --user-config -h --help" -- "$cur") ;;
        esac
      fi
      ;;
    doctor)
      mapfile -t COMPREPLY < <(compgen -W "--fix -h --help" -- "$cur")
      ;;
    status)
      mapfile -t COMPREPLY < <(compgen -W "--json -h --help" -- "$cur")
      ;;
    commit)
      mapfile -t COMPREPLY < <(compgen -W "-m --message -h --help" -- "$cur")
      ;;
    show)
      mapfile -t COMPREPLY < <(compgen -W "--with-annotations --color -h --help" -- "$cur")
      ;;
    annotations)
      if [[ $pos -eq 1 ]]; then
        mapfile -t COMPREPLY < <(compgen -W "reapply help -h --help" -- "$cur")
      else
        mapfile -t COMPREPLY < <(compgen -W "-h --help" -- "$cur")
      fi
      ;;
    local)
      if [[ $pos -eq 1 ]]; then
        mapfile -t COMPREPLY < <(compgen -W "add rm diff apply help -h --help" -- "$cur")
      elif [[ $pos -eq 2 && "$subcmd" == "rm" ]]; then
        mapfile -t COMPREPLY < <(compgen -W "--revert -h --help" -- "$cur")
      else
        mapfile -t COMPREPLY < <(compgen -W "-h --help" -- "$cur")
      fi
      ;;
    check)
      if [[ $pos -eq 1 ]]; then
        mapfile -t COMPREPLY < <(compgen -W "public help -h --help" -- "$cur")
      else
        mapfile -t COMPREPLY < <(compgen -W "$branches -h --help" -- "$cur")
      fi
      ;;
    completion)
      if [[ $pos -eq 1 ]]; then
        mapfile -t COMPREPLY < <(compgen -W "install help -h --help" -- "$cur")
      else
        mapfile -t COMPREPLY < <(compgen -W "-h --help" -- "$cur")
      fi
      ;;
    push|re-anchor)
      mapfile -t COMPREPLY < <(compgen -W "$branches -h --help" -- "$cur")
      ;;
    version|install-hooks)
      mapfile -t COMPREPLY < <(compgen -W "-h --help" -- "$cur")
      ;;
  esac
}

# Register for direct git-shadow invocation
complete -F _git_shadow git-shadow

# Register for "git shadow" invocation via git's completion framework (if available)
if declare -f __git_complete &>/dev/null; then
  __git_complete git-shadow _git_shadow
fi
