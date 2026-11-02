{ inputs, system }:
with inputs.llm-agents.packages.${system};
[
  antigravity-cli
  claude-code
  codex
  copilot-cli
]
