# CCNexus Integration Model

CCNexus tries to detect **capabilities first** and exact mod names second. This keeps the CraftOS agent useful across modpacks and reduces breakage when a peripheral type is renamed between Minecraft versions.

## Native CC:Tweaked capabilities

| Capability | Detection | Dashboard use |
|---|---|---|
| Speaker | `playAudio` | Remote audio routing |
| Monitor | terminal/monitor methods | In-world status pages |
| Inventory | `list` + `size` | Searchable item index |
| Forge Energy | `getEnergy` + `getEnergyCapacity` | Stored/capacity FE |
| Fluid storage | `tanks` | Fluid/tank cache |
| Turtle | turtle API | Quarry, farms, GPS, fuel/inventory |
| Redstone | computer API | Lights/machines/analogue output |

## Applied Energistics 2

Base AE2 is surfaced to CraftOS through an external peripheral integration. CCNexus targets **Advanced Peripherals ME Bridge** because it exposes item/storage/crafting methods to CC:Tweaked.

Detection accepts:

- peripheral type `meBridge`
- peripheral type `me_bridge`
- compatible peripherals exposing both `listItems` and `craftItem`

This handles the known type-name change between Minecraft/AP versions without forcing the user to edit Lua.

### Current ME features

- bridge discovery and online state
- `listItems` cache
- `listCraftableItems` merge when available
- ME energy methods when available in that AP version
- `craftItem({ name, count })`

## Refined Storage

Advanced Peripherals also provides an RS Bridge with a similar storage-system interface. It is a natural next adapter and can reuse most of the existing Storage & AE2 UI after normalization into a common `storageNetwork` model.

## Performance rules

Large peripheral networks can return thousands of stacks. CCNexus therefore:

- performs deep inventory/energy/ME scans approximately every 15 seconds per CraftOS node
- sends lighter heartbeat telemetry more frequently
- caps cached item lists in the device payload
- keeps server-side global search aggregation separate from the live WebSocket command path

Future historical metrics should use a separate time-series store rather than growing `state.json` indefinitely.

## Safety model

CCNexus does not expose a browser endpoint that can call arbitrary peripheral methods by name. Integrations are implemented as explicit command types (for example `ae2_craft` or `monitor_set`). This reduces the chance that a dashboard credential accidentally becomes unrestricted remote code/peripheral execution.
