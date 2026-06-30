# Friend Shop Real-Device Validation

Custom-clothing Increment 3 (in-person friend shop). The MultipeerConnectivity transport and the
NearbyInteraction proximity gate can't run on the simulator, so verify on **two physical iOS devices** on
the same build, with Bluetooth and Wi-Fi enabled and both apps unlocked. Without UWB hardware the session
falls back to manual proximity commit — confirm the connection from the Friends screen if prompted.

Roles below: **Seller** lists items for sale; **Buyer** browses and buys. Each device is both, so run the
happy path once in each direction.

## Setup (both devices)

1. On each device, design at least one item in Wardrobe > Design a new item (paint the canvas, name it).
2. On the Seller, open the item, turn on **Available in my shop**, set a price, and Save.
3. Confirm the Wardrobe row shows **In your shop · N coins**.
4. Put both devices on the **Friends** (Social) tab so clothing discovery is running.

## Happy Path

1. Bring the two devices together so they connect in person (confirm the connection if prompted).
2. On the Buyer, tap the **bag** button in the Friends header to open **Friend shops**.
3. Confirm the Seller's shop section appears (titled "<Seller>'s shop") with their listed items.
4. Confirm each tile shows the thumbnail, name, **designed by <Seller>**, and a **<price> coins** button.
5. Confirm the wallet badge at the top shows the Buyer's coin balance.
6. Tap a buy button on an affordable item.
7. Confirm the "Added … to your closet" message and that the balance drops by exactly the price.
8. Open the Buyer's Wardrobe and confirm the item is present, in the correct slot section, labelled
   **Designed by <Seller>** (never "You"), and is **not** marked "In your shop".
9. Equip it and confirm it renders on the companion.

## Provenance

1. After a buy, confirm the bought item shows **Designed by <Seller>** in both the Friend shop tile and
   the Buyer's Wardrobe.
2. Confirm the Buyer cannot list the bought item for sale (no Sell action on a friend's design).
3. Confirm the Seller's own copy still shows **In your shop** and is unaffected by the sale.

## Coins And Buy Rules

1. Buy an item, then reopen the shop and confirm that item's button now reads **Owned** and is disabled.
2. Find an item priced above the Buyer's balance and confirm its button is disabled with
   **Not enough coins yet**.
3. In Wardrobe, delete a previously bought item, return to the shop, and buy it again — confirm it returns
   to the closet and the balance is **not** charged a second time (you already paid for it).

## Seller Listing Management

1. Try to list a **7th** item for sale and confirm a gentle "Your shop is full" notice (cap is 6).
2. Name an item with an offensive word, turn on Available in my shop, Save, and confirm a gentle
   "Pick a friendlier name" notice — the item stays saved but **unlisted** (private items can be named
   anything).
3. Adjust an item's price with the stepper (range 1–100) and confirm the new price shows in the shop on
   the Buyer after the catalog refreshes.
4. Unlist an item at any time and confirm it disappears from the Buyer's shop on the next refresh.
5. **Intended, not a bug:** after changing your shop you'll see a gentle "you've refreshed your shop
   today" note. This is informational — the once-per-day re-publish limit is a soft note, not a hard lock.

## Ephemerality (the core in-person guarantee)

1. With the shop open on the Buyer and items visible, walk the devices apart (or leave the Friends tab on
   either device).
2. Confirm the Seller's shop section disappears from the Buyer's Friend shops view once disconnected.
3. Confirm any item the Buyer already **bought** remains in their Wardrobe.
4. Reconnect and confirm the shop reappears.

## Privacy Setting

1. On either device, disable Allow nearby clothing shares (Settings).
2. Confirm that device neither broadcasts its shop nor shows others' shops.
3. Re-enable and confirm shops reappear after reconnecting.

## Lock And Background

1. Lock Fernlet on the Buyer and confirm shop discovery stops (no nearby shops).
2. Background the app and confirm the same.
3. Leave the Friends/Social tab and confirm clothing discovery stops (it is social-tab only).

## Multi-Device, Same Account (iCloud sync on)

1. With iCloud sync enabled on two devices signed into the same account, design and list items on each.
2. Buy a friend's item on device A, then open device B after it syncs.
3. Confirm device A's purchased item appears on device B **and** that device B's own designs are still
   present (the append-only store fix means a buy on one device can't wipe the other's items).
4. Confirm the coin balance on both devices reflects the spend (no item is silently lost; an offline
   double-spend of the same coins is bounded and floors at 0 — expected without a server).

## Failure Cases

1. Turn off Bluetooth or Wi-Fi mid-session and confirm the shop empties gracefully (no crash) and
   reconnects when re-enabled.
2. Tap buy with exactly enough coins, then immediately again — confirm a single debit and a single closet
   copy (idempotent by item id).
