# The libraries in agent-python, the venv ../modules/home/agent-python.nix
# builds for agents' one-off scripts. Loaded on purpose: nearly every module is
# already in some other closure on these hosts.
{ pkgs, inputs, ... }:
{
  programs.agentPython.enable = true;
  programs.agentPython.packages =
    ps: with ps; [
      anyio
      trio
      httpx
      h2
      websockets
      asyncssh
      uvloop
      watchfiles
      attrs
      cattrs
      pydantic
      pydantic-settings
      msgspec
      orjson
      typing-extensions
      rich
      typer
      click
      structlog
      tenacity
      humanize
      tabulate
      platformdirs
      packaging
      pyyaml
      ruamel-yaml
      tomli-w
      jinja2
      jsonschema
      jmespath
      ijson
      markdown-it-py
      beautifulsoup4
      lxml
      python-dateutil
      psutil
      pexpect
      sh
      more-itertools
      toolz
      cryptography
      pyjwt
      dnspython
      netaddr
      paramiko
      xxhash
      sqlalchemy
      aiosqlite
      numpy
      polars
      pygit2
      libcst
      tree-sitter
      boto3
      kubernetes-asyncio
      # The umbrella's kr8s fork, the client `ekn` uses. Not in nixpkgs.
      (callPackage (inputs.nixidae.outPath + "/nanopynix/nix/kr8s.nix") {
        src =
          (import inputs.nixidae {
            inherit pkgs;
            inherit (pkgs.stdenv.hostPlatform) system;
          }).sources.kr8s;
      })
      anthropic
      openai
      pytest
      hypothesis
      respx
      # What agent-written snippets import unasked: requests over httpx,
      # pandas over polars. Failing on an import costs more than the bytes.
      requests
      aiohttp
      pandas
      matplotlib
      scipy
      networkx
      duckdb
      sqlite-utils
      psycopg
      asyncpg
      redis
      pillow
      pypdf
      openpyxl
      xmltodict
      selectolax
      html2text
      markdownify
      charset-normalizer
      regex
      tomlkit
      python-dotenv
      jsonpatch
      deepdiff
      unidiff
      pathspec
      semver
      whenever
      python-slugify
      cachetools
      diskcache
      tqdm
      kubernetes
      docker
      freezegun
      syrupy
    ];
}
