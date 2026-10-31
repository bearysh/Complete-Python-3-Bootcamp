# Hermes Agent integration (verified against hermes-agent 0.19.0 source)

The Hermes documentation site was not reachable from the development container, so the
integration was derived from the actual `hermes-agent==0.19.0` package on PyPI. Installed
behaviour is authoritative; re-check these paths after any Hermes upgrade.

## How the API server works
| Fact | Source |
|---|---|
| There is no `hermes api-server` command; the API server is a gateway platform adapter started by `hermes gateway run` | `gateway/platforms/api_server.py:915`, `hermes_cli/subcommands/gateway.py:37-50` |
| Enabled when `API_SERVER_KEY` is set in the profile `.env` (or `API_SERVER_ENABLED`) | `gateway/config.py:2006-2030` |
| Default bind 127.0.0.1:8642; env `API_SERVER_HOST` / `API_SERVER_PORT` | `api_server.py:121-122, 940-948` |
| Refuses to start without a key of ≥16 characters, even on loopback | `api_server.py:5354-5379` |
| Auth: `Authorization: Bearer <API_SERVER_KEY>` (constant-time compare) | `api_server.py:1235-1265` |
| `POST /v1/chat/completions`: system messages become an ephemeral system prompt layered on Hermes' own; `temperature`, `max_tokens`, `model` are ignored | `api_server.py:2650-2790` |
| Session: header `X-Hermes-Session-Id`; a never-used id yields empty history. Without the header Hermes derives a deterministic id from the prompt (could collide across cases), so the app always sends one | `api_server.py:2717-2773`, `852-867` |
| Non-stream response is OpenAI-shaped with final text only; failures add `hermes:{completed,failed,error_code}` and `X-Hermes-Completed` headers | `api_server.py:2908-2975` |
| `DELETE /api/sessions/{id}` removes a transcript from the profile `state.db` | `api_server.py:2353-2402` |
| Toolsets for the API server come only from `platform_toolsets.api_server` in config; default (unset) is a large toolset incl. terminal, browser, web, memory | `hermes_cli/tools_config.py:1721-1760`, `toolsets.py:399-430` |

## Profile isolation
* `hermes profile create little-guy-legal --no-skills --no-alias` creates an **empty** profile
  (`~/.hermes/profiles/little-guy-legal/`): no config, memory, sessions, skills or `.env` copied
  (`hermes_cli/profiles.py:1070-1148`). Only `--clone`/`--clone-all` copy anything.
* Each profile is a full `HERMES_HOME` with its own `config.yaml`, `.env`, `state.db`,
  `memories/`, `sessions/`, `skills/`, `logs/`. Selected with `hermes -p little-guy-legal …`.
* `hermes/little-guy-legal.config.yaml` sets: `model.provider: custom` + loopback `base_url`;
  `fallback_providers: []`; `memory.memory_enabled/user_profile_enabled: false`, `memory.provider: ""`;
  `platform_toolsets.api_server: [no_mcp]`; `agent.disabled_toolsets` for every tool family;
  `skills.creation_nudge_interval: 0`, `curator.enabled: false`; `model_catalog.enabled: false`;
  `sessions.auto_prune: true`; `gateway.api_server.max_concurrent_runs: 1`; `auxiliary.*` pinned to the local endpoint.
* `hermes/verify_profile.py` checks the on-disk config, `.env` permissions and contents,
  absence of inherited memory/skills, and the live server's `/v1/toolsets`, `/v1/models`, and
  that unauthenticated requests are rejected.

## Known outbound calls in Hermes and how they are avoided
| Call | Trigger | Mitigation |
|---|---|---|
| PyPI update check | `hermes version` / banner only, not `gateway run` | not triggered by the app |
| Model catalog (`hermes-agent.nousresearch.com`) | `hermes model` / `/model` | `model_catalog.enabled: false` |
| Nous Portal, Anthropic OAuth, OpenRouter | only for those providers | provider is `custom` loopback; no fallback |
| Skills hub (GitHub) | explicit `hermes skills install` | never run for this profile |
| Honcho / memory plugins | `memory.provider` | set to `""` |

## Discrepancies and uncertainties
* Online docs describe an "API server" feature; the installed package has no dedicated
  subcommand — the gateway must run. If the Mac mini's Hermes version differs from 0.19.0,
  run `hermes gateway run --help` and re-verify with `hermes/verify_profile.py`.
* `auxiliary.*.provider: auto` appears to follow the main custom provider, but this was not
  traced end-to-end; the config pins it explicitly.
* `[no_mcp]` vs `[]` for `platform_toolsets.api_server`: both yield no configurable toolsets;
  `no_mcp` additionally blocks globally configured MCP servers.
* The live checks in `verify_profile.py` could not be executed in the development
  container (no Hermes/OMLX). They are exercised against a loopback fake in
  `tests/test_hermes_adapter.py` that mirrors the 0.19.0 request/response contract.
