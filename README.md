# Adjust Storage Capacity

Need more room in your silos? Or want to limit storage to make gameplay more challenging? Adjust Storage Capacity lets you customize the capacity of any bulk storage facility on your farm.

This mod gives you full control over storage capacities for silos, production facilities, and animal husbandries. Whether you want massive storage for convenience or reduced capacity for a more realistic challenge, you can set any value you want.

Supports multiplayer with a permission system - server admins can modify any storage, while farm managers can adjust their own farm's facilities.

> **Note:** Only bulk storage is supported. No pallets or terrain heap-based storage like bunker silos.

**Alpha Version:** This is an early release. Please report any issues on GitHub.

## Features

- **Easy capacity dialog:** Press K at any storage to open the settings
- **Per-filltype editing:** Adjust capacity for each fill type individually
- **Inline text input:** Double-click or press Enter on a row to edit
- **Persistent settings:** Changes save with your game
- **Full multiplayer support:** Permission system for server admins and farm managers
- **Console commands:** Advanced users can use ascList, ascSet, ascReset

## Supported Storage Types

- Silos and warehouses (PlaceableSilo)
- Production point storage (PlaceableProductionPoint)
- Husbandry input/output storage - straw, water, milk, manure, etc. (PlaceableHusbandry)
- Animal food troughs (PlaceableHusbandryFood)

## Limitations

- Bunker silos not supported (terrain heap-based storage has no capacity property)
- Pallets and bales not supported (object storage)

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

1. Load a savegame with the mod enabled
2. Approach a storage facility (silo, production, husbandry)
3. Press `K` to open the capacity settings dialog
4. Double-click or press Enter on a fill type to edit its capacity
5. Enter the new value and press Enter to apply
6. Press Escape to cancel editing or close the dialog

## Console Commands

For advanced users, the following console commands are available:

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
