# Adjust Storage Capacity

Need more room in your silos or trailers? Or want to limit storage to make gameplay more challenging? Adjust Storage Capacity lets you customize the capacity of storage facilities and vehicles on your farm.

This mod gives you control over storage capacities for silos, production facilities, animal husbandries, and vehicles. Adjust from anywhere - approach a facility, open in-game menus, or press K while driving to adjust your vehicle and attached implements on the go. Whether you want massive storage for convenience or reduced capacity for a more realistic challenge, you can set any value you want to bulk storages without editing XML files and mods.

Optional auto-scale settings keep expanded vehicles drivable by adjusting mass and load/discharge speed proportionally to capacity changes.

Supports multiplayer with a permission system - server admins can modify any storage or vehicle, while farm managers can adjust their own farm's facilities and vehicles.

> **Note:** Only bulk storage is supported. No pallets, big bags, or terrain heap-based storage like bunker silos.

## Features

- **Easy capacity dialog:** Press K near any storage or vehicle to open the settings
- **In-vehicle adjustment:** Press K while driving to adjust your vehicle and attached implements
- **In-game menu integration:** Press K in Production, Animals, Workshop, or Construction menus
- **Per-filltype editing:** Adjust capacity for each fill type or fill unit individually
- **Inline text input:** Double-click or press Enter on a row to edit
- **Reset All:** Button to restore original capacities for a storage or vehicle
- **Capacity protection:** Automatically clamps to current fill level to prevent data loss
- **Auto-scale vehicle mass:** Keeps expanded vehicles drivable by scaling weight to match original capacity
- **Auto-scale load/discharge speed:** Optional setting to scale speed proportionally with capacity changes
- **Optional trigger shortcuts:** Setting to hide K at placeables/vehicles (menu access always available)
- **Configurable key binding:** Change the default K key in game settings
- **Multiplayer support:** Permission system for server admins and farm managers
- **Console commands:** Available for advanced users

## Supported Storage Types

### Placeables
- Silos and warehouses (PlaceableSilo)
- Production point storage (PlaceableProductionPoint)
- Husbandry input/output storage - straw, water, milk, manure, etc. (PlaceableHusbandry)
- Animal food troughs (PlaceableHusbandryFood)

### Vehicles
- Trailers (grain carts, auger wagons)
- Harvesters (grain tanks)
- Sprayers and spreaders
- Tankers (slurry, water, milk)
- Any vehicle with bulk fill units

## Limitations

**Placeables:**
- Bunker silos not supported (terrain heap-based storage has no capacity property)
- Pallets and bales not supported (object storage, not bulk storage)

**Vehicles:**
- Pallets and big bags not supported (products being transported, not containers)
- Leveler fill units excluded (internal buffers for bunker silo mechanics)

## Installation

### From GitHub Releases

1. Download the latest release from [Releases](https://github.com/rittermod/FS25_AdjustStorageCapacity/releases)
2. Place the `.zip` file in your mods folder:
   - **Windows**: `%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\`
   - **macOS**: `~/Library/Application Support/FarmingSimulator2025/mods/`
3. Enable the mod in-game

### Manual Installation

1. Clone or download this repository
2. Copy the `FS25_AdjustStorageCapacity` folder to your mods folder
3. Enable the mod in-game

## Usage

### At a Storage Facility
1. Load a savegame with the mod enabled
2. Approach a storage facility (silo, production, husbandry)
3. Press `K` to open the capacity settings dialog
4. Double-click or press Enter on a fill type to edit its capacity
5. Enter the new value and press Enter to apply
6. Press Escape to cancel editing or close the dialog

### At a Vehicle
1. Walk near any vehicle with fill units (trailer, harvester, sprayer, tanker) and press `K`
2. Or press `K` while driving to adjust your current vehicle and attached implements
3. Edit fill unit capacities the same way as placeables

### From In-Game Menus
- **Production menu:** Select a production point, press `K`
- **Animals menu:** Select a husbandry, press `K`
- **Workshop/Repair screen:** Select a vehicle, press `K`
- **Construction mode:** View placeable info, press `K`

## Console Commands

For advanced users, the following console commands are available:

### Placeable Commands

| Command | Description |
|---------|-------------|
| `ascList` | Show all storages with their capacities |
| `ascSet <index> <fillType> <capacity>` | Set a custom capacity |
| `ascReset <index> [fillType]` | Reset to original capacity |

**Examples:**

```
ascSet 1 WHEAT 100000
ascSet 2 -1 50000          (husbandry food uses -1)
ascReset 1 WHEAT
ascReset 1                  (reset all fill types)
```

### Vehicle Commands

| Command | Description |
|---------|-------------|
| `ascListVehicles` | Show all vehicles with fill units |
| `ascSetVehicle <index> <fillUnit> <capacity>` | Set a custom capacity |
| `ascResetVehicle <index> [fillUnit]` | Reset to original capacity |

**Examples:**

```
ascSetVehicle 1 1 50000     (set fill unit 1 to 50000L)
ascResetVehicle 1 1         (reset fill unit 1)
ascResetVehicle 1           (reset all fill units)
```

## Multiplayer

The mod supports multiplayer with a permission system:

- **Server/Host:** Can modify any owned storage
- **Admin (Master User):** Can modify any owned storage
- **Farm Manager:** Can modify their own farm's storage
- **Farm Worker:** Cannot modify storage (must be farm manager)

**Note:** NPC farm (Farm 0) and spectator assets cannot be modified by any player.

## Compatibility

- **Game Version**: Farming Simulator 25
- **Multiplayer**: Supported
- **Platform**: PC (Windows/macOS)

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the full changelog.

### 1.0.0.0

- Fixed 3D fill visuals (vehicle heaps, food troughs) not showing correctly after loading a savegame
- Fixed straw bedding and water visuals not updating when capacity is changed
- Fixed 3D fill plane rendering issues in silos and food troughs

### 0.6.1.0 (Beta)

- Fixed excess fill not being removed when resetting capacity to original (shared capacity storages reduce proportionally)
- Fixed reset failing on newly placed buildings with "No original capacities recorded" error

## License

This mod is provided as-is for personal use with Farming Simulator 25.

## Credits

- **Author**: [Ritter](https://github.com/rittermod)

## Support

Found a bug or have a feature request? [Open an issue](https://github.com/rittermod/FS25_AdjustStorageCapacity/issues)
