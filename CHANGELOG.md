# Changelog

## 1.0.1.2:
- Fixed the game getting stuck on the loading screen when the Pumps n' Hoses Pack is enabled; silos now load correctly

## 1.0.1.1:
- Fixed a corrupted or hand-edited capacity in a savegame loading the storage empty; the game's default capacity is now restored instead
- Fixed storage staying stuck over its limit after such a capacity was discarded on load; the excess fill is now trimmed
- Added Russian (ru) translation - contributed by Maestro-Ralf

## 1.0.1.0:
- Stopped offering the game's auto-managed fill units for editing (baler bale chamber, net/twine/film slots, straw-blower buffer); additive tanks stay adjustable
- Made a stationary baler's fixed material bunker adjustable again, and stopped listing collected-bale platforms (their capacity is a bale count, not bulk storage)
- Stopped listing count-based units on tree planters, feller bunchers, and bale carriers (saplings, trees, and bales are counted, not stored in bulk)
- Fixed joining players not seeing the correct fill level in multiplayer for silos, productions, husbandries, and vehicles filled above their original capacity
- Fixed animal-food troughs not showing the correct feed level to other players in multiplayer when filled above the original capacity
- Fixed shovels, loaders, and telehandlers reverting a raised capacity after scooping; it now sticks across save and reload
- Fixed savegames holding more than capacity (corrupt or hand-edited) getting stuck; the excess fill is now trimmed on load
- Fixed very large capacities (above ~2.1 billion) wrapping to negative values; capacity now caps at the maximum with a notification

## 1.0.0.0:
- Fixed 3D fill visuals (vehicle heaps, food troughs) not showing correctly after loading a savegame
- Fixed straw bedding and water visuals not updating when capacity is changed
- Fixed 3D fill plane rendering issues in silos and food troughs

## 0.6.1.0 (Beta):
- Fixed excess fill not being removed when resetting capacity to original (shared capacity storages reduce proportionally)
- Fixed reset failing on newly placed buildings with "No original capacities recorded" error

## 0.6.0.0 (Beta):
- Added in-vehicle capacity adjustment - press K while driving to adjust capacity of your vehicle and attached implements
- Added auto-scale vehicle mass setting, which keeps expanded vehicles drivable by scaling weight to original capacity
- Added "Reset All" button (X) to storage and vehicle capacity dialogs to restore original capacities
- Added auto-scale speed setting, which controls whether load and discharge speed scales proportionally with capacity changes
- Fixed multiplayer client not resetting all storage capacities when using reset

## 0.5.1.0 (Beta):
- Changed the K keybind to automatically yield to any active native trigger, in another try to prevent occlusion

## 0.5.0.0 (Beta):
- Added K button to Workshop/Repair screen for vehicle capacity adjustment
- Added K button to Construction mode placeable info dialog
- Added setting to hide trigger shortcuts (K at placeables/vehicles) - menu access always available

## 0.4.1.0 (Beta):
- Fixed production point menu (R) not showing when K keybind is active

## 0.4.0.0 (Beta):
- Changed visual fill levels to update instantly when changing capacity, covering vehicle heaps, silo fill planes, and animal food troughs

## 0.3.5.0 (Alpha):
- Fixed the K keybind stealing input priority from the animal trigger and other native triggers

## 0.3.4.0 (Alpha):
- Scaled load/discharge speed proportionally to capacity change from original capacity
- Fixed K keybind for placeables getting stuck when entering vehicles

## 0.3.3.0 (Alpha):
- Fixed fill levels being lost when loading savegames with expanded storage capacity

## 0.3.2.0 (Alpha):
- Added capacity protection - capacity now clamps to the current fill level to prevent data loss
- Added permission blocking for NPC farm (Farm 0) and spectator assets
- Changed console lists to show only assets you have permission to modify
- Fixed K keybind getting stuck on screen when entering/exiting vehicles
- Fixed shared capacity marker (*) not showing in console list output
- Fixed multiplayer sync corruption when adjusting animal food trough capacity

## 0.3.1.0 (Alpha):
- Fixed K keybind conflict when standing near both a placeable and vehicle

## 0.3.0.0 (Alpha):
- Added vehicle capacity adjustment (trailers, harvesters, sprayers, tankers)
- Added K at any vehicle with fill units to adjust its capacities
- Added console commands ascListVehicles, ascSetVehicle, and ascResetVehicle

## 0.2.0.0 (Alpha):
- Added K button to Production and Animals in-game menus
- Added capacity adjustment directly from the menu without approaching storage
- Fixed dialog overlay issue (now properly covers menu background)

## 0.1.0.0:
- Added the initial alpha release
- Added a GUI dialog for viewing and editing storage capacities (press K near any storage)
- Added inline editing - double-click or press Enter on a row to edit its capacity
- Added support for silos, warehouses, production storage, and animal husbandries
- Added settings persistence across save/load
- Added full multiplayer support with a permission system
- Added console commands for advanced users - ascList, ascSet, and ascReset
- Documented that bunker silos are not supported (terrain-based)
