# Changelog

## 1.0.0.0

- Fixed 3D fill visuals (vehicle heaps, food troughs) not showing correctly after loading a savegame
- Fixed straw bedding and water visuals not updating when capacity is changed
- Fixed 3D fill plane rendering issues in silos and food troughs

## 0.6.1.0 (Beta)

- Fixed excess fill not being removed when resetting capacity to original (shared capacity storages reduce proportionally)
- Fixed reset failing on newly placed buildings with "No original capacities recorded" error

## 0.6.0.0 (Beta)

- Added in-vehicle capacity adjustment: press K while driving to adjust capacity of your vehicle and attached implements
- Added auto-scale vehicle mass setting: keeps expanded vehicles drivable by scaling weight to original capacity
- Added "Reset All" button (X) to storage and vehicle capacity dialogs to restore original capacities
- Fixed multiplayer client not resetting all storage capacities when using reset
- Added auto-scale speed setting: controls whether load and discharge speed scales proportionally with capacity changes

## 0.5.1.0 (Beta)

- K now automatically yields to any active native trigger in another try to prevent occlusion

## 0.5.0.0 (Beta)

- Added K button to Workshop/Repair screen for vehicle capacity adjustment
- Added K button to Construction mode placeable info dialog
- Added setting to hide trigger shortcuts (K at placeables/vehicles) - menu access always available

## 0.4.1.0 (Beta)

- Fixed production point menu (R) not showing when K keybind is active

## 0.4.0.0 (Beta)

- Visual fill levels now update instantly when changing capacity
- Includes vehicle heaps, silo fill planes, and animal food troughs

## 0.3.5.0 (Alpha)

- Fixed the fix for K keybind. It stole priority from animal trigger etc

## 0.3.4.0 (Alpha)

- Fixed K keybind for placeables getting stuck when entering vehicles
- Scaled load/discharge speed proportionally to capacity change from original capacity

## 0.3.3.0 (Alpha)

- Fixed fill levels being lost when loading savegames with expanded storage capacity

## 0.3.2.0 (Alpha)

- Added capacity protection: capacity now clamps to current fill level to prevent data loss
- Fixed K keybind getting stuck on screen when entering/exiting vehicles
- Added permission blocking for NPC farm (Farm 0) and spectator assets
- Console lists now show only assets you have permission to modify
- Fixed shared capacity marker (*) not showing in console list output
- Fixed multiplayer sync corruption when adjusting animal food trough capacity

## 0.3.1.0 (Alpha)

- Fixed K keybind conflict when standing near both a placeable and vehicle

## 0.3.0.0 (Alpha)

- Added vehicle capacity adjustment (trailers, harvesters, sprayers, tankers)
- Walk near any vehicle with fill units to press K and adjust capacities
- New console commands: ascListVehicles, ascSetVehicle, ascResetVehicle

## 0.2.0.0 (Alpha)

- Added K button to Production and Animals in-game menus
- Adjust capacity directly from menu without approaching storage
- Fixed dialog overlay issue (now properly covers menu background)

## 0.1.0.0

- Initial alpha release
- GUI dialog for viewing and editing storage capacities (press K near any storage)
- Inline editing: double-click or Enter on a row to edit capacity
- Supports silos, warehouses, production storage, and animal husbandries
- Settings persist across save/load
- Full multiplayer support with permission system
- Console commands for advanced users: ascList, ascSet, ascReset
- Known limitation: bunker silos not supported (terrain-based)
