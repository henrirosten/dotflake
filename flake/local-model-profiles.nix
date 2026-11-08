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
}
