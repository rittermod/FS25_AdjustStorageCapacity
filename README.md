# Adjust Storage Capacity

Need more room in your silos or trailers? Or want to limit storage to make gameplay more challenging? Adjust Storage Capacity lets you customize the capacity of storage facilities and vehicles on your farm.

This mod gives you control over storage capacities for silos, production facilities, animal husbandries, and vehicles. Whether you want massive storage for convenience or reduced capacity for a more realistic challenge, you can set any value you want to bulk storages without editing XML files and mods.

Supports multiplayer with a permission system - server admins can modify any storage or vehicle, while farm managers can adjust their own farm's facilities and vehicles.

> [!WARNING]
> This is an alpha release (early release). Both singleplayer and multiplayer functionality are tested, but there are probably some bugs not found. Please report any issues on [GitHub](https://github.com/rittermod/FS25_AdjustStorageCapacity/issues) or [Discord](https://discord.gg/KXFevNjknB).

> **Note:** Only bulk storage is supported. No pallets, big bags, or terrain heap-based storage like bunker silos.

## Features

- **Easy capacity dialog:** Press K near any storage or vehicle to open the settings
- **In-game menu integration:** Press K in the Production or Animals menu to adjust the selected facility
- **Vehicle support:** Walk near any vehicle with fill units to adjust capacities
- **Per-filltype editing:** Adjust capacity for each fill type or fill unit individually
- **Inline text input:** Double-click or press Enter on a row to edit
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
1. Walk near any vehicle with fill units (trailer, harvester, sprayer, tanker)
2. Press `K` to open the vehicle capacity dialog
3. Edit fill unit capacities the same way as placeables

### From In-Game Menu
1. Open the Production or Animals menu (ESC → Production / Animals)
2. Select a production facility or husbandry
3. Press `K` to open the capacity dialog for the selected facility
4. Edit capacities as described above

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

- **Server/Host:** Can modify any storage
- **Admin (Master User):** Can modify any storage
- **Farm Manager:** Can modify their own farm's storage
- **Farm Worker:** Cannot modify storage (must be farm manager)

## Compatibility

- **Game Version**: Farming Simulator 25
- **Multiplayer**: Supported
- **Platform**: PC (Windows/macOS)

## Changelog

### 0.3.1.0 (Alpha)

- Fixed K keybind conflict when standing near both a placeable and vehicle

### 0.3.0.0 (Alpha)

- Added vehicle capacity adjustment (trailers, harvesters, sprayers, tankers)
- Walk near any vehicle with fill units to press K and adjust capacities
- New console commands: ascListVehicles, ascSetVehicle, ascResetVehicle

### 0.2.0.0 (Alpha)

- Added K button to Production and Animals in-game menus
- Adjust capacity directly from menu without approaching storage
- Fixed dialog overlay issue (now properly covers menu background)

### 0.1.0.0

- Initial alpha release
- GUI dialog for viewing and editing storage capacities (press K near any storage)
- Inline editing: double-click or Enter on a row to edit capacity
- Supports silos, warehouses, production storage, and animal husbandries
- Settings persist across save/load
- Full multiplayer support with permission system
- Console commands for advanced users: ascList, ascSet, ascReset
- Known limitation: bunker silos not supported (terrain-based)

## License

This mod is provided as-is for personal use with Farming Simulator 25.

## Credits

- **Author**: [Ritter](https://github.com/rittermod)

## Support

Found a bug or have a feature request? [Open an issue](https://github.com/rittermod/FS25_AdjustStorageCapacity/issues)
