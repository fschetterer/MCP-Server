# ~DockerInit.sh 
# dockec exec -it MCP-Server claude
# To use minimax-m2 change: D:\My Projects\Claude-ai\settings.global.json
#  "env": {
#    "ANTHROPIC_BASE_URL": "http://ollama.lan:11434",
#    "ANTHROPIC_AUTH_TOKEN": "ollama",
#    "API_TIMEOUT_MS": "3000000",
#    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
#    "ANTHROPIC_MODEL": "minimax-m2.5:cloud",
#    **** These lines are the only ones needed for Claude code use ****	 
#    "ANTHROPIC_MODEL": "sonnet", 
#    "CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL": "1"
#  },
# more in: https://wiki.lan/index.php/Docker_Desktop
# Unix Line Endings, he backslash must be the last character on the line, with absolutely no spaces or tabs after it. Any whitespace after the backslash will cause the continuation to fail, treating the space as the escaped character instead of the newline.
export CONTAINER_NAME="MCP-Server"
~/.DockerFile/DockerInit.sh