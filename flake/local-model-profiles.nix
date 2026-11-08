let
  laptop = {
    name = "Qwen3.5-4B";
    quant = "Q5_K_M";
    model = {
      name = "Qwen3.5-4B-Q5_K_M.gguf";
      url = "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q5_K_M.gguf";
      sha256 = "8814232b85594dcd46c50e5b8b29324a7efe9e746edbe8a3d1df3d3fce7aad39";
    };
    contextSize = 8192;
    maxTokens = 2048;
    # null leaves the inference thread count to llama-server.
    threads = null;
    memoryMax = "75%";
    samplingParams = {
      temperature = 0.7;
      top_p = 0.8;
      top_k = 20;
      presence_penalty = 1.5;
      chat_template_kwargs.enable_thinking = false;
    };
  };
in
{
  inherit laptop;
  # A 40 GiB guest leaves 8 GiB outside the model service for the task and OS.
  nocturn = laptop // {
    name = "Qwen3.6-35B-A3B";
    quant = "UD-Q4_K_M";
    model = {
      name = "Qwen3.6-35B-A3B-UD-Q4_K_M.gguf";
      url = "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/a483e9e6cbd595906af30beda3187c2663a1118c/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf";
      sha256 = "ac0e2c1189e055faa36eff361580e79c5bd6f8e76bffb4ce547f167d53e31a61";
    };
    contextSize = 32768;
    maxTokens = 8192;
    threads = 8;
    memoryMax = "32G";
  };
}
