// Handler for in-playsim level event stuff.
//
// This is "inside" the playsim, so it gets written to save files and so forth,
// and permits us to persist randomizer state across play sessions.

#namespace GZAP;
#debug off;

const AP_RELEASE_IN_WORLD = 1;
const AP_RELEASE_SECRETS = 2;

class ::PerLevelHandler : EventHandler {
  // Archipelago state manager.
  ::RandoState apstate;
  // Locations corresponding to secret sectors. Indexed by sector number.
  // As we find each one we clear it from the map.
  Map<int, ::Location> secret_locations;
  // If set, the player is leaving the level via the level select or similar
  // rather than by reaching the exit.
  bool early_exit;
  // Set when the player triggers an exit linedef. If they don't subsequently
  // exit the level, this is probably because they are dead, and will trigger
  // an exit when they respawn.
  bool line_exit_normal;
  bool line_exit_secret;

  static clearscope ::PerLevelHandler Get() {
    return ::PerLevelHandler(Find("::PerLevelHandler"));
  }

  void InitRandoState(bool restore_items) {
    let datastate = ::PlayEventHandler.GetState();

    if (self.apstate == null) {
      // Newly initialized, use the one from the PlayEventHandler.
      self.apstate = datastate;
    }

    if (self.apstate == datastate) {
      return;
    }

    // If we get this far, we probably just loaded a savegame, we have a saved
    // apstate, and we disagree with the StaticEventHandler on the contents.
    // Treat whichever one has the highest transaction count as the canonical one.
    // When this happens, our apstate will be whatever was in the savegame, and
    // the datastate will be whatever the game-wide state was just before the
    // game was loaded.
    DEBUG("APState conflict resolution: txn[d]=%d txn[p]=%d",
      ::PlayEventHandler.GetState().txn, apstate.txn);

    if (self.apstate.txn >= datastate.txn) {
      // Our state has a higher txn. This usually means someone started up the
      // game, then loaded a savegame, so we have a fresh apstate in the PEH and
      // the real one in the PLH.
      DEBUG("Using state from playscope.");
      ::PlayEventHandler.Get().apstate = self.apstate;
    } else {
      // PEH state has higher txn. This is usually a result of a savegame being
      // loaded or a return to an earlier level in persistent mode.
      //
      // In the latter case, we want to use the PEH state. In the former case,
      // we want to *mostly* use the PEH state -- in particular we want its
      // record of what checks have been collected and what keys/tokens we have
      // -- but we want to rewind our understanding of what items have been
      // *used* to match the loaded save, to avoid a problem where the player
      // saves, picks up a weapon, it vends, and then they load their game and
      // the weapon is gone forever.
      DEBUG("Using state from datascope.");
      if (restore_items) {
        DEBUG("Restoring items from playscope first.");
        datastate.CopyItemUsesFrom(self.apstate);
      }
      self.apstate = datastate;
    }
    apstate.UpdatePlayerInventory();
  }

  //// Handling for loading into the world. ////
  // For loading save games, WorldThingSpawned doesn't get called, so the PEH
  // will call OnLoadGame() for us.

  override void WorldLoaded(WorldEvent evt) {
    DEBUG("PLH WorldLoaded");

    if ((level.MapName == "GZAPHUB" || level.MapName == "GZAPRST")
         && ::PlayEventHandler.Get().IsRandomized()) {
      Menu.SetMenu("ArchipelagoLevelSelectMenu");
      return;
    }
  }

  void SetupSecrets(::Region region) {
    self.secret_locations.Clear();

    foreach (location : region.locations) {
      if (location.secret_sector < 0) continue;

      DEBUG("Init secret location: %s", location.name);
      let sector = level.sectors[location.secret_sector];
      if (location.checked && sector.IsSecret()) {
        // Location is checked but sector is still marked undiscovered -- level
        // probably got reset.
        DEBUG("Clearing secret flag on sector %d", location.secret_sector);
        sector.ClearSecret();
        level.found_secrets++;
      } else if (!location.checked && !sector.IsSecret()) {
        // Location isn't marked checked but the corresponding sector has been
        // discovered, so emit a check event for it.
        ::PlayEventHandler.Get().CheckLocation(location);
      } else if (!location.checked) {
        // Player hasn't found this yet.
        self.secret_locations.Insert(location.secret_sector, location);
      }
    }
  }

  void UpdateSecrets() {
    foreach (sector_id,location : self.secret_locations) {
      if (!level.sectors[sector_id].IsSecret()) {
        ::PlayEventHandler.Get().CheckLocation(location);
        // Only process one so we don't modify secret_locations while iterating it.
        self.secret_locations.Remove(sector_id);
        return;
      }
    }
  }

  // Separate functions for handling "new map" and "game loaded" that are actually
  // called from the StaticEventHandler, since it's the only one that can tell
  // the difference.
  void OnNewMap() {
    DEBUG("PLH OnNewMap");
    InitRandoState(false);
    early_exit = false;
    line_exit_normal = false;
    line_exit_secret = false;

    let region = apstate.GetCurrentRegion();
    SetupSecrets(region);
    foreach (location : region.locations) {
      // Secret-sector locations are handled by SetupSecrets().
      if (location.secret_sector >= 0) continue;
      ::CheckPickup.Create(location);
    }
    apstate.UpdatePlayerInventory();
  }

  void OnReopen() {
    DEBUG("PLH OnReopen");
    InitRandoState(false);
    early_exit = false;
    line_exit_normal = false;
    line_exit_secret = false;

    let region = apstate.GetCurrentRegion();
    SetupSecrets(region);
    apstate.UpdatePlayerInventory();
  }

  void OnLoadGame() {
    DEBUG("PLH OnLoadGame");
    InitRandoState(true);
    early_exit = false;
    apstate.CheckForNewKeys();
    apstate.UpdatePlayerInventory();

    let region = apstate.GetCurrentRegion();
    SetupSecrets(region);
    foreach (::CheckPickup thing : ThinkerIterator.Create("::CheckPickup", Thinker.STAT_DEFAULT)) {
      // At this point, we may have a divergence, depending on whether the apstate
      // contained here or in the StaticEventHandler was deemed canonical.
      // In the latter case, the Location referenced in the actor came from the
      // save game, while the one in the apstate was carried across the save/load
      // barrier outside the playsim.
      // So, we replace the saved one with the real one before evaluating whether
      // it's been checked.
      // TODO: we should probably just store the apid in the check and look up
      // the location that way by asking the eventhandler, rather than baking
      // the entire location into it, so that this workaround becomes unnecessary
      // -- it seems like a footgun waiting to happen.
      DEBUG("CleanupReopened: id %d, matched %d",
          thing.location.apid, thing.location == region.GetLocation(thing.location.apid));
      thing.location = region.GetLocation(thing.location.apid);
      thing.UpdateFromLocation();
    }
  }

  override void WorldTick() {
    apstate.OnTick();

    if (allow_drops > 0) {
      DEBUG("allow_drops: %d", allow_drops);
      --allow_drops;
    }

    if (level.total_secrets - level.found_secrets != self.secret_locations.CountUsed()) {
      UpdateSecrets();
    }
  }

  // Handle exit linedef activation.
  // Under normal circumstances, the game handles this on its own and all is well.
  // However, this fails if it's a death exit and the source and destination
  // maps are in the same hubcluster -- which is the case when persistence is on.
  // To handle that case, we record that the line was activated here, and then
  // if the player respawns without leaving the map, we trigger the exit.
  override void WorldLinePreActivated(WorldEvent evt) {
    let thing = evt.thing;
    let line = evt.ActivatedLine;
    if (!(thing is "PlayerPawn")) return;

    // Key checks are done after WorldLinePreActivated, so we need to check
    // them here just in case that check would normally fail.
    if (!thing.CheckKeys(line.locknumber, false, true)) return;
    if (evt.ActivatedLine.special == 243) { // LS_EXIT_NORMAL
      line_exit_normal = true;
    } else if (evt.ActivatedLine.special == 244) { // LS_EXIT_SECRET
      line_exit_secret = true;
    }
  }

  override void PlayerRespawned(PlayerEvent evt) {
    if (line_exit_secret) {
      level.SecretExitLevel(0);
    } else if (line_exit_normal) {
      level.ExitLevel(0, false);
    }
  }

  //// Handling for individual actors spawning in. ////

  override void WorldThingSpawned(WorldEvent evt) {
    let thing = evt.thing;

    if (!(thing is "::CheckPickup") && thing.bCOUNTITEM) {
      thing.ClearCounters();
    }

    // Handle weapon suppression, if enabled.
    if (!ShouldAllow(Weapon(thing))) {
      ReplaceWithAmmo(thing, Weapon(thing));
      thing.Destroy();
    }
  }

  // How many tics to allow drops for.
  // We set this to a nonzero value when replicating items so that they don't
  // get culled.
  // This does mean that enemy drops that happen at the same time as replication
  // may get through, but I have yet to come up with a better solution.
  // We could in principle replicate and then hand the spawned item to the handler
  // to say "allow this item, specifically", but that breaks for chains like
  // Shotgun replaced with Spawner which produces ModdedShotgun -- we end up
  // allowing the Spawner but not the ModdedShotgun.
  int allow_drops;
  void AllowDropsBriefly(int tics) { allow_drops = tics; }

  bool ShouldAllow(Weapon thing) {
    if (!thing) return true;
    // What happens outside the randomizer stays outside the randomizer.
    // This includes GZAPHUB and GZAPRST, so the player's starting inventory
    // (including fists/pistol) won't get suppressed on game start.
    if (!apstate.GetCurrentRegion()) return true;
    DEBUG("Checking spawn of %s", thing.GetTag());
    if (self.allow_drops) return true;
    if (ap_suppress_weapon_drops == 0) return true;

    let cls = thing.GetClass();
    if (cls is "WeaponGiver") {
      // WeaponGivers are required to have exactly one DropItem
      cls = thing.GetDropItems().Name;
      if (!cls) return true;
    }

    // Allow only if same slot in inventory
    if (ap_suppress_weapon_drops == 1) {
      // Make the simplifying assumption that all players have the same slots.
      let [assigned,slot,idx] = players[0].weapons.LocateWeapon(cls);
      DEBUG("Checking based on slot: assigned=%d slot=%d", assigned, slot);
      if (!assigned) return true; // I guess???
      return apstate.HasWeaponSlot(slot);
    }

    // Allow only if same weapon in inventory
    if (ap_suppress_weapon_drops == 2) {
      DEBUG("Checking based on class: %s", cls.GetClassName());
      return apstate.HasWeapon(cls.GetClassName());
    }

    DEBUG("Unconditionally blocking spawn.");
    return false;
  }

  void ReplaceWithAmmo(readonly<Actor> spawner, readonly<Weapon> thing) {
    if (!spawner || !thing) return;

    if (thing is "WeaponGiver") {
      string name = thing.GetDropItems().Name;
      Class<Weapon> cls = name;
      if (!cls) return;
      ReplaceWithAmmo(thing, GetDefaultByType(cls));
      return;
    }

    DEBUG("ReplaceWithAmmo: %s", thing.GetTag());
    SpawnAmmo(spawner, thing.AmmoType1, thing.AmmoGive1);
    SpawnAmmo(spawner, thing.AmmoType2, thing.AmmoGive2);
  }

  void SpawnAmmo(readonly<Actor> thing, Class<Ammo> cls, int amount) {
    if (!cls || !amount) return;
    DEBUG("SpawnAmmo: %d of %s", amount, cls.GetClassName());
    let ammo = Inventory(thing.Spawn(cls, thing.pos, ALLOW_REPLACE));
    if (!ammo) return;
    DEBUG("Spawned: %s", ammo.GetTag());
    ammo.ClearCounters();
    ammo.amount = amount;
  }

  //// Handling for level exit. ////
  // We try to guess if the player reached the exit or left in some other way.
  // In the former case, we give them credit for clearing the level.

  void OnLevelExit(bool is_save) {
    DEBUG("PLH WorldUnloaded: save=%d warp=%d lnum=%d", is_save, self.early_exit, level.LevelNum);

    let region = apstate.GetRegion(level.MapName);

    if (is_save || !region) {
      cvar.FindCvar("ap_scan_unreachable").SetInt(0);
    }

    if (!region) return;
    apstate.CheckForNewKeys();

    if (is_save || self.early_exit) return;

    if (ap_scan_unreachable >= 2) {
      let region = apstate.GetRegion(level.MapName);
      foreach (location : region.locations) {
        if (location.checked) continue;
        DEBUG("Marking %s as unreachable.", location.name);
        ::PlayEventHandler.Get().CheckLocation(location);
      }
    }
    cvar.FindCvar("ap_scan_unreachable").SetInt(0);

    ::PlayEventHandler.Get().CheckLocation(apstate.GetCurrentRegion().exit_location);

    if (ap_release_on_level_clear) {
      let region = apstate.GetRegion(level.MapName);
      foreach (location : region.locations) {
        if (location.checked) continue;
        if (location.secret_sector < 0) {
          if (ap_release_on_level_clear & AP_RELEASE_IN_WORLD == 0) continue;
        } else {
          if (ap_release_on_level_clear & AP_RELEASE_SECRETS == 0) continue;
        }
        DEBUG("Collecting %s on level exit.", location.name);
        ::PlayEventHandler.Get().CheckLocation(location, true);
      }
    }
  }
}

