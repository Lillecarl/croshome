# The model API keys (DeepSeek, Claude, OpenCode Zen and Go, Gemini, vLLM,
# OpenAI, OpenRouter) as KEY=value lines, for every host that reads user.yaml.
# Nothing loads them: a shell or a project sources the file where it wants them.
# Not in the session environment, because a tool that finds OPENAI_API_KEY or
# GEMINI_API_KEY bills the API instead of its login.
{
  croshome.userSecrets.ai-keys = { };
}
