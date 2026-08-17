# Turtle Automation Layouts

## Crop grid

The crop turtle walks a width × length serpentine route and inspects the block below each cell. Mature supported vanilla crops are harvested and replanted from the configured turtle slot.

Supported first-pass maturity checks:

- wheat: age 7
- carrots: age 7
- potatoes: age 7
- beetroot: age 3
- nether wart: age 3

The route is recorded so the turtle can rewind to its starting position between repeated cycles.

## Tree service lane

Layout from above:

```text
T = turtle/service lane
X = tree/sapling position
. = clear lane

X . . . X . . . X . . . X
T > > > > > > > > > > > >
```

Trees must be on the turtle's right while it travels along the lane. At each station it turns right, removes a vanilla log column, returns to the lane, replants from the configured slot, then continues.

Keep the service lane unobstructed and test a small number of trees first.

## Job controls

The agent exposes generic turtle job state:

- `running`
- `paused`
- `stopping`
- `complete`
- `stopped`

The browser can pause, resume and stop an active job. Only one movement job is allowed on a turtle at a time.
