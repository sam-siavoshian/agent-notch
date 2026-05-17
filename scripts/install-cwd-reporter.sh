#!/usr/bin/env bash
# Installs an OSC 7 / preexec hook into the user's interactive shell rc file
# so AgentNotch's TerminalAdapter can read the current cwd reliably.
#
# Idempotent: safe to run multiple times; only adds the hook once.
#
# Supports zsh (preexec hook) and bash (PROMPT_COMMAND).

set -euo pipefail

CACHE_DIR="${HOME}/.cache/agentnotch"
mkdir -p "${CACHE_DIR}"

MARK="# >>> agentnotch cwd reporter >>>"
END_MARK="# <<< agentnotch cwd reporter <<<"

ZSH_HOOK=$(cat <<'EOF'
# >>> agentnotch cwd reporter >>>
_agentnotch_report_cwd() {
  local tty_name
  tty_name=$(tty 2>/dev/null | sed 's|/dev/||; s|/|-|g')
  [[ -z "${tty_name}" ]] && return
  print -n -- "${PWD}" > "${HOME}/.cache/agentnotch/term-cwd-${tty_name}" 2>/dev/null || true
}
typeset -ag chpwd_functions
chpwd_functions+=(_agentnotch_report_cwd)
typeset -ag precmd_functions
precmd_functions+=(_agentnotch_report_cwd)
_agentnotch_report_cwd
# <<< agentnotch cwd reporter <<<
EOF
)

BASH_HOOK=$(cat <<'EOF'
# >>> agentnotch cwd reporter >>>
_agentnotch_report_cwd() {
  local tty_name
  tty_name=$(tty 2>/dev/null | sed 's|/dev/||; s|/|-|g')
  [[ -z "${tty_name}" ]] && return
  printf "%s" "${PWD}" > "${HOME}/.cache/agentnotch/term-cwd-${tty_name}" 2>/dev/null || true
}
PROMPT_COMMAND="_agentnotch_report_cwd${PROMPT_COMMAND:+; ${PROMPT_COMMAND}}"
_agentnotch_report_cwd
# <<< agentnotch cwd reporter <<<
EOF
)

install_into() {
  local file="$1"
  local hook="$2"
  if [[ ! -f "${file}" ]]; then
    touch "${file}"
  fi
  if grep -qF "${MARK}" "${file}"; then
    echo "Already installed in ${file}"
    return
  fi
  printf "\n%s\n" "${hook}" >> "${file}"
  echo "Installed reporter into ${file}"
}

case "${SHELL##*/}" in
  zsh)
    install_into "${HOME}/.zshrc" "${ZSH_HOOK}"
    ;;
  bash)
    install_into "${HOME}/.bashrc" "${BASH_HOOK}"
    ;;
  *)
    echo "Unsupported shell: ${SHELL}. Install hook manually."
    exit 1
    ;;
esac

echo ""
echo "AgentNotch cwd reporter installed. Restart your terminal or 'source' your rc file to activate."
