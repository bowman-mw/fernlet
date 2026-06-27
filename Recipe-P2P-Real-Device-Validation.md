# Recipe P2P Real-Device Validation

Use two physical iOS devices on the same build. Keep Bluetooth and Wi-Fi enabled.

## Happy Path

1. On receiver, open Fernlet and unlock it.
2. Leave receiver on Home, Food, or Move.
3. On sender, open Food and tap a recipe share button.
4. Confirm receiver appears in the Fernlet nearby list.
5. Send with Include notes enabled.
6. Confirm sender shows Sent and closes the sheet.
7. Confirm receiver sees the recipe review sheet.
8. Import and verify the recipe appears in the correct recipe list.

## Notes Toggle

1. Share a local recipe with notes.
2. Disable Include notes.
3. Import on receiver.
4. Confirm recipe notes are empty and ingredients/macros remain intact.

## Receiver Availability

1. Move receiver to Social or Personal.
2. Open sender share sheet.
3. Confirm receiver does not appear.
4. Move receiver back to Home, Food, or Move.
5. Tap Search again on sender.
6. Confirm receiver appears.

## Privacy Setting

1. On receiver, disable Settings > Privacy > Allow nearby recipe shares.
2. Open sender share sheet.
3. Confirm receiver does not appear.
4. Re-enable the setting and tap Search again.
5. Confirm receiver appears.

## Lock And Background

1. Lock Fernlet on receiver.
2. Confirm receiver disappears or cannot be discovered.
3. Background receiver app.
4. Confirm receiver disappears or cannot be discovered.

## Failure Cases

1. Turn off Bluetooth or Wi-Fi during sending.
2. Confirm sender shows a failure state.
3. Decline the receiver review sheet.
4. Confirm no recipe is imported.
