{ inputs, system }:
with inputs.llm-agents.packages.${system};
[
  claude-code
  codex
  copilot-cli
  gemini-cli
]
