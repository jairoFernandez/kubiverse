# Multiplayer (party)

The player who runs the bridge (the **host**) invites friends into a
cluster's world. While the cluster is fine it is a paintball **shooter**;
when the cluster goes into **alarm** everyone switches to a shared
**mission** to fix it, and back to the shooter once it is calm.

Press **F4** in the game for the PARTY panel.

## Decisions

| Question | Decision |
|---|---|
| Inviting over the internet | No hosted relay. LAN with `--lan` (HTTPS, the links the bridge prints); over the internet, put the bridge behind your own tunnel (Tailscale, cloudflared...) and share that URL. |
| What a guest can do on the real cluster | Read only. A guest's change is refused by the bridge (403) and sent to the host as a request; the host applies it with the usual production confirmation. |
| Weapons during a party | Paintball: they only hurt players. Chaos mode (real operations) is off for everyone while the party lasts. |
| What starts a mission | Only an **alarm** (`ControlRoom.level_of`: a node down, a critical alert, 8+ broken pods). Back to the shooter after 10 s without alarm. |

## Invitations (bridge)

- `POST /api/party/invite` `{context?, label?}` (host only): a random
  10-character code, tied to one context, valid 24 h. `GET` lists them,
  `DELETE ?code=` revokes one. The answer carries the LAN URLs with `--lan`.
- The code is a credential of its own, used where the token goes
  (`?token=` or `X-Bridge-Token`). It only opens `GET` on read-only routes
  (`/api/state`, `/api/summary`, `/api/ws`, `/api/play`, `/api/pod`,
  `/api/logs`, `/api/obs`, `/api/series`, `/api/rollout`, `/api/cani`,
  `/api/version`, `/api/whoami`) and always for the invitation's cluster.
  The bridge's real token is never shared.
- Link: `https://<bridge>/?token=CODE&party=1`. The web build served by the
  bridge connects with it and joins the party; the native game takes the
  same link in the PARTY panel.

## Relay (`GET /api/play?name=`)

One WebSocket relay per cluster. Players send small JSON messages; the
bridge stamps them with the sender's id and passes them to the others.
Limits: 2 KB per message, 30 messages/s per player, 8 players.

| Message | Meaning |
|---|---|
| `welcome {id, color, host, players}` | from the bridge, on joining |
| `join {p}`, `leave {id}` | from the bridge |
| `pos {p:[x,y,z], y, l, hp}` | 10 times a second |
| `shot {from, to, w}` | a shot (drawn by the others) |
| `hit {v, d, w}` | the shooter says who they hit; the victim applies it |
| `dead {by}` | the victim went down (score for `by`) |
| `prog {m, s}` | shared mission: step `s` of mission `m` done |
| `ask {req}` | a guest asks the host to apply a change (hosts only) |

Remote players are drawn 100 ms in the past, interpolated between the
position samples, and only on the level the local player is on.

## Shared mission

Every game sees the same snapshot, so each decides the mode itself with
`ControlRoom.level_of(ControlRoom.summarize_state(state))` and picks the
same mission: Kubi's most urgent one (`KubiMissions.generate`, stable ids).
Steps done by anyone are relayed (`prog`) and count for everyone; the
status line says who did each one.

## Demo

`--demo --party[=DRILL_SECONDS]` (or F4 in demo mode): three bots walk,
shoot and help with the mission. After the drill delay (60 s by default)
the demo cluster breaks on purpose (a node down, two apps crashing), the
party switches to the mission, and the bots and you fix it.

## Code

- `bridge/party.go`: invitations, guest admission, relay.
- `game/scripts/party_rules.gd`: pure rules (modes, hits, interpolation, links).
- `game/scripts/party.gd`: party state, relay client, demo bots.
- `game/scripts/party_view.gd`: remote players, status line, scoreboard, F4 panel.
- `game/scripts/entities/remote_player.gd`: another player in the world.

## Not done yet

- End-to-end check with two games on a real local bridge (the relay is
  covered by Go tests over a real WebSocket; the game's client by feeding
  it relay messages).
- Touch-friendly PARTY panel and a button for it in the HUD (F4 only).
- Shared mission for problems Kubi has no mission for (e.g. only a node
  down): the party shows the alarm but no steps.
