# CC Gunship

Fully automatic Create Big Cannons on a moving **Sable** ship. One computer on the ship finds a target on the radar, works out the shell arc (gravity, drag, target lead, your own ship's speed), aims every cannon that can bear, and fires each one only when its barrel is within `AIM_MARGIN` degrees.

Needs CC: Tweaked, CC: Sable, cc-cbc (Cannon Mount peripheral) and Create Radar.

## Build

On the ship, all on **one wired modem network** (right-click every modem so it turns red):

- the **computer**
- every **Cannon Mount** (each needs rotation on its yaw and pitch shafts, since it turns at their speed)
- a **radar**: a Radar Bearing with its dish, or a Plane Radar
- optional: a **radar monitor**. Clicking a target on it makes the cannons switch to that target.

Keep each cannon loaded with an autoloader or hopper chain. The computer can't see ammo, so it just waits `RELOAD` seconds between shots.

## Install

```
wget https://raw.githubusercontent.com/levisnakes/cc-gunship/main/gunship.lua startup.lua
reboot
```

It starts **SAFE**: the cannons aim but don't fire. Press **A** to arm.

| Key | |
|---|---|
| A | arm / safe |
| N | next target |
| C | back to automatic targeting (nearest) |
| F | fire every cannon that's on target now, even when SAFE |
| X | ignore this target for good (use it on parts of your own ship, like swivel-bearing sublevels) |
| U | un-ignore everything |
| T | test mode: every cannon swings through a few angles every 4 s (never fires) |

Each cannon row shows its error in degrees, its state, and `yaw/pitch now > wanted`.

## Cannons not moving?

Press **T**. Every cannon should swing every 4 seconds. If one doesn't, its row tells you why:

- **no yaw power** / **no pitch power**: that shaft isn't turning. Power the mount's yaw input (bottom) and pitch input (side).
- **not assembled**: arm once (A), and it assembles the cannon, or assemble it by hand.
- **error: ...**: the mount refused the command; send a screenshot.

## Check the aim before arming

1. Let it pick a target while SAFE and watch the barrels.
2. If every cannon points the same wrong direction, set `YAW_OFFSET` (try 180, 90 or -90).
3. If the barrels aim down when they should aim up, set `PITCH_SIGN = -1`.
4. If shells fall short or fly long, set `CANNON_SPEED` to 2 x your powder charges (4 charges = 8).

## Radar Bearing notes

A Radar Bearing only updates a contact when its spinning dish sweeps over it, and drops contacts it hasn't swept for a while. Gunship keeps its lock through those gaps and aims at where the target should be now (screen: "radar lost it Ns ago"). A faster-spinning dish means fresher positions and better aim.

Parts of your own ship that are separate sublevels (anything on a swivel or physics bearing) show up as their own "ships". Press **X** while one is the target and it's ignored for good.

## Which cannon shoots when

Each cannon works out which side of the ship it's on and only fires inside a `ARC`-degree arc on that side, so it never shoots across your own deck. Override one with `ARCS["cannon_mount_0"] = { center = 90, width = 120 }` (yaw in the ship's frame: 0 = +Z, 90 = -X, 180 = -Z, 270 = +X).

Cannons hold fire while the ship rocks faster than `MAX_ROCK` deg/s, and shots are spaced `STAGGER` seconds apart because recoil on Sable ships is strong (x40 in this pack).

## Settings (top of startup.lua)

| Setting | Default | |
|---|---|---|
| `CANNON_SPEED` | 8 | shell speed, blocks/tick (2 per Powder Charge) |
| `BARREL_LENGTH` | 4 | blocks from the mount to the muzzle |
| `GRAVITY` / `DRAG` | -0.05 / 0.01 | Big Cannons defaults for HE, AP and solid shot |
| `AIM_MARGIN` | 1.0 | degrees off before it won't fire |
| `RELOAD` | 6 | seconds between shots of one cannon |
| `STAGGER` | 0.75 | seconds between any two shots |
| `MAX_ROCK` | 8 | hold fire above this ship rotation speed (deg/s) |
| `MIN_RANGE` / `MAX_RANGE` | 20 / 400 | |
| `TARGETS` | Sable ships only | also `PLAYER`, `HOSTILE`, `MOB`, `ANIMAL` |
| `OWN_SHIP_RADIUS` | 20 | your own ship is also skipped by its id |
| `LOCK_MEMORY` | 15 | seconds it keeps following a target after the radar last saw it |

Updates install by themselves (every 15 min and on reboot), keeping your settings. `AUTO_UPDATE = false` turns that off.
