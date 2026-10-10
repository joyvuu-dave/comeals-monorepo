import { types, getRoot, isAlive } from "mobx-state-tree";
import { api } from "../helpers/api";
import { evictMealCache } from "../helpers/meal_cache";
import { showSignupFailure, tappedOf } from "../helpers/signup_failure";

const Resident = types
  .model("Resident", {
    id: types.identifierNumber,
    meal_id: types.number,
    // "102 - Jane": the unit prefix tells two Janes apart in lists.
    name: types.string,
    // "Jane": for sentences. Defaults to "" because cached meal
    // payloads from before this field exist; plainName falls back.
    short_name: "",
    attending: false,
    attending_at: types.maybeNull(types.Date),
    late: false,
    vegetarian: false,
    can_cook: true,
    active: true,
  })
  .volatile(() => ({
    // What this resident had on the meal when the meal was loaded. The
    // sign-up list keeps showing a retired resident who was signed up
    // then, or had a guest then, even after a tap takes them off or
    // removes their last guest. So a wrong tap can be undone: a second
    // tap signs them up again, or adds the guest again (#91, #134).
    // loadData sets these on every row it makes, and the next load makes
    // new rows.
    attendingAtLoad: false,
    guestsCountAtLoad: 0,
  }))
  .views((self) => ({
    get plainName() {
      return self.short_name !== "" ? self.short_name : self.name;
    },
    get guests() {
      return Array.from(self.root.guests.values()).filter(
        (guest) => guest.resident_id === self.id,
      );
    },
    get guestsCount() {
      return self.guests.length;
    },
    get canRemoveGuest() {
      // Scenario #1: no guests
      if (self.guestsCount === 0) {
        return false;
      }

      // Scenario #2: guests, meal open
      if (self.guestsCount > 0 && !self.root.meal.closed) {
        return true;
      }

      // Scenario #3: guests, meal closed, guests added after meal closed
      if (
        self.guestsCount > 0 &&
        self.root.meal.closed &&
        self.root.meal.closed_at !== null &&
        self.guests.filter(
          (guest) => guest.created_at > self.root.meal.closed_at,
        ).length > 0
      ) {
        return true;
      }

      // Otherwise: every guest was added at or before the close.
      return false;
    },
    get canRemove() {
      // Scenario #1: not attending
      if (self.attending === false) {
        return false;
      }

      // Scenario #2: attending, meal open
      if (self.attending && !self.root.meal.closed) {
        return true;
      }

      // Scenario #3: attending, meal closed, added after meal closed
      if (
        self.attending &&
        self.root.meal.closed &&
        self.attending_at !== null &&
        self.root.meal.closed_at !== null &&
        self.attending_at > self.root.meal.closed_at
      ) {
        return true;
      }

      // Otherwise: signed up at or before the close, guests or not.
      return false;
    },
    // The DataStore at the root of the tree.
    get root() {
      return getRoot(self);
    },
  }))
  .actions((self) => ({
    // loadData calls this once on each row it makes, after it has put
    // the meal's guests.
    rememberAtLoad() {
      self.attendingAtLoad = self.attending;
      self.guestsCountAtLoad = self.guestsCount;
    },
    setAttending(val) {
      self.attending = val;
      return val;
    },
    setAttendingAt(val) {
      self.attending_at = val;
      return val;
    },
    setLate(val) {
      self.late = val;
      return val;
    },
    setVeg(val) {
      self.vegetarian = val;
      return val;
    },
    toggleAttending(options = { late: false, veg: false }) {
      // A settled meal's sign-ups are final. The screen locks the name
      // cell only with pointer-events: none, which a click sent to the
      // cell itself (a screen reader, a script) does not go through, so
      // this action and the four below check the meal themselves.
      if (self.root.meal.reconciled) {
        return;
      }

      // A retired resident can be signed up only when they were signed
      // up when the meal was loaded, so a wrong tap that took them off
      // can be undone (#91). A retired host who is on the sign-up list
      // only because of a guest cannot be signed up (#134). The screen
      // locks that row's name and switches, and this check stops a
      // click sent straight to the name cell.
      if (!self.active && !self.attending && !self.attendingAtLoad) {
        return;
      }

      // Scenario #1: Meal is closed, you're not attending
      //              there are no extras -- can't add yourself
      if (
        self.root.meal.closed &&
        !self.attending &&
        self.root.meal.extras < 1
      ) {
        return;
      }

      // Scenario #2: Meal is closed, you are attending -- can't remove yourself
      if (self.root.meal.closed && self.attending && !self.canRemove) {
        return;
      }

      const val = !self.attending;
      self.attending = val;

      // Toggle Late if Necessary
      if (options.late) {
        self.late = !self.late;
      }

      // The tap was on the Veg switch, so they join as a vegetarian.
      // A resident who is not attending holds their profile's veg value
      // (MealFormSerializer), and a tap on the name joins with it. Their
      // Veg switch is off whatever the profile says, because nothing is
      // saved for them yet (attendees_box.jsx), so a tap on it always
      // means "sign me up as a vegetarian". A refused add puts the
      // profile's value back (issue #109).
      const previousVeg = self.vegetarian;
      if (options.veg) {
        self.vegetarian = true;
      }

      const currentVeg = self.vegetarian;
      const currentLate = self.late;

      // A raced refetch can destroy this node while the request is in
      // flight. Capture the root store, the meal id, and whose row this
      // is now — a dead node cannot reach its parents or its fields — so
      // the callbacks below can repair by refetching instead of silently
      // dropping the server's change, and a failure can still say whose
      // tap failed (S2).
      const store = getRoot(self);
      const mealId = self.meal_id;
      const tapped = tappedOf(self);

      if (val) {
        self.root.meal.decrementExtras();
        api.meals.residents
          .add(self.meal_id, self.id, {
            late: currentLate,
            vegetarian: currentVeg,
            socketId: window.Comeals.socketId,
          })
          .then(function (response) {
            // The server saved the change, so the cached meal payload is
            // now stale — whether or not this node is still alive.
            evictMealCache(mealId);
            if (!isAlive(self)) {
              // The node died but the server saved the change; fetch
              // the confirmed state so the screen shows it.
              store.loadDataAsync();
              return;
            }
            // The server's created_at is the signup time of record; the
            // client clock can be skewed.
            self.setAttendingAt(new Date(response.data.created_at));
          })
          .catch(function (error) {
            // A row built again since the tap shows what the server has,
            // so only the row that was tapped is put back.
            if (isAlive(self)) {
              self.setAttending(false);
              self.setAttendingAt(null);
              self.root.meal.incrementExtras();

              // If they were clicking late to add, uncheck late
              if (options.late) {
                self.setLate(false);
              }

              // If they were clicking veg to add, put back the veg value
              // from before the tap.
              if (options.veg) {
                self.setVeg(previousVeg);
              }
            }

            showSignupFailure(store, tapped, error);
          });
      } else {
        var previousLate = self.late;
        self.late = false;
        self.root.meal.incrementExtras();
        api.meals.residents
          .remove(self.meal_id, self.id, {
            socketId: window.Comeals.socketId,
          })
          .then(function () {
            evictMealCache(mealId);
            if (!isAlive(self)) {
              store.loadDataAsync();
              return;
            }
            self.setAttendingAt(null);
          })
          .catch(function (error) {
            if (isAlive(self)) {
              self.setAttending(true);
              self.setLate(previousLate);
              self.root.meal.decrementExtras();
            }

            showSignupFailure(store, tapped, error);
          });
      }
    },
    toggleLate() {
      if (self.root.meal.reconciled) {
        return;
      }
      if (self.attending === false) {
        self.toggleAttending({ late: true });
        return;
      }

      const val = !self.late;
      self.late = val;
      // Captured while alive; see toggleAttending.
      const store = getRoot(self);
      const mealId = self.meal_id;
      const tapped = tappedOf(self);

      api.meals.residents
        .update(self.meal_id, self.id, {
          late: val,
          socketId: window.Comeals.socketId,
        })
        .then(function () {
          evictMealCache(mealId);
          if (!isAlive(self)) store.loadDataAsync();
        })
        .catch(function (error) {
          if (isAlive(self)) self.setLate(!val);

          showSignupFailure(store, tapped, error);
        });
    },
    toggleVeg() {
      if (self.root.meal.reconciled) {
        return;
      }
      if (self.attending === false) {
        self.toggleAttending({ veg: true });
        return;
      }

      const val = !self.vegetarian;
      self.vegetarian = val;
      // Captured while alive; see toggleAttending.
      const store = getRoot(self);
      const mealId = self.meal_id;
      const tapped = tappedOf(self);

      api.meals.residents
        .update(self.meal_id, self.id, {
          vegetarian: val,
          socketId: window.Comeals.socketId,
        })
        .then(function () {
          evictMealCache(mealId);
          if (!isAlive(self)) store.loadDataAsync();
        })
        .catch(function (error) {
          if (isAlive(self)) self.setVeg(!val);

          showSignupFailure(store, tapped, error);
        });
    },
    // The seat goes at the tap. The request, its Idempotency-Key, and
    // what the answer means are in data_store_guest_adds.ts (S2).
    addGuest(options = { vegetarian: false }) {
      if (self.root.meal.reconciled) {
        return;
      }
      self.root.meal.decrementExtras();
      self.root.sendGuestAdd({
        row: self,
        mealId: self.meal_id,
        hostId: self.id,
        vegetarian: options.vegetarian,
        tapped: tappedOf(self),
        guestIdsAtTap: self.guests.map((guest) => guest.id),
      });
    },
    removeGuest() {
      if (self.root.meal.reconciled || !self.canRemoveGuest) {
        return false;
      }

      // Newest first. created_at is a Date, so the subtraction is
      // milliseconds.
      const sortedGuests = Array.from(self.guests)
        .slice()
        .sort((a, b) => b.created_at - a.created_at);

      // Grab Id of newest guest
      const guestId = sortedGuests[0].id;

      // Captured while alive; see toggleAttending.
      const store = getRoot(self);
      const mealId = self.meal_id;
      const tapped = tappedOf(self);

      api.meals.residents.guests
        .remove(self.meal_id, self.id, guestId, {
          socketId: window.Comeals.socketId,
        })
        .then(function () {
          evictMealCache(mealId);
          if (!isAlive(self)) {
            store.loadDataAsync();
            return;
          }
          self.root.removeGuest(guestId);
          self.root.meal.incrementExtras();
        })
        .catch(function (error) {
          showSignupFailure(store, tapped, error);
        });
    },
  }));

export default Resident;
