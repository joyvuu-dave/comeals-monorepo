import { types, getRoot, isAlive } from "mobx-state-tree";
import { api } from "../helpers/api";
import handleAxiosError from "../helpers/handle_axios_error";
import { evictMealCache } from "../helpers/meal_cache";

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

      // Scenario #4: guests, meal closed, guests added before meal closed
      if (
        self.guestsCount > 0 &&
        self.root.meal.closed &&
        self.root.meal.closed_at !== null &&
        Array.from(self.guests).filter(
          (guest) => guest.created_at <= self.root.meal.closed_at,
        ).length > 0
      ) {
        return false;
      }

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

      // Scenario #4: guests, meal closed, added before meal closed
      if (
        self.guestsCount > 0 &&
        self.root.meal.closed &&
        self.attending_at !== null &&
        self.root.meal.closed_at !== null &&
        self.attending_at <= self.root.meal.closed_at
      ) {
        return false;
      }

      return false;
    },
    // The DataStore at the root of the tree.
    get root() {
      return getRoot(self);
    },
  }))
  .actions((self) => ({
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
    toggleAttending(options = { late: false, toggleVeg: false }) {
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

      // Toggle Veg if Necessary
      if (options.toggleVeg) {
        self.vegetarian = !self.vegetarian;
      }

      const currentVeg = self.vegetarian;
      const currentLate = self.late;

      // A raced refetch can destroy this node while the request is in
      // flight. Capture the root store and the meal id now — a dead node
      // cannot reach its parents or its fields — so the success callbacks
      // below can repair by refetching instead of silently dropping the
      // server's change.
      const store = getRoot(self);
      const mealId = self.meal_id;

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
            if (response.status === 200) {
              // The server's created_at is the signup time of record; the
              // client clock can be skewed.
              self.setAttendingAt(new Date(response.data.created_at));
            }
          })
          .catch(function (error) {
            if (!isAlive(self)) return;
            self.setAttending(false);
            self.setAttendingAt(null);
            self.root.meal.incrementExtras();

            // If they were clicking late to add, uncheck late
            if (options.late) {
              self.setLate(false);
            }

            // If they were clicking veg to add, unckeck veg
            if (options.toggleVeg) {
              self.setVeg(false);
            }

            handleAxiosError(error);
          });
      } else {
        var previousLate = self.late;
        self.late = false;
        self.root.meal.incrementExtras();
        api.meals.residents
          .remove(self.meal_id, self.id, {
            socketId: window.Comeals.socketId,
          })
          .then(function (response) {
            evictMealCache(mealId);
            if (!isAlive(self)) {
              store.loadDataAsync();
              return;
            }
            if (response.status === 200) {
              self.setAttendingAt(null);
            }
          })
          .catch(function (error) {
            if (!isAlive(self)) return;
            self.setAttending(true);
            self.setLate(previousLate);
            self.root.meal.decrementExtras();

            handleAxiosError(error);
          });
      }
    },
    toggleLate() {
      if (self.attending === false) {
        self.toggleAttending({ late: true });
        return;
      }

      const val = !self.late;
      self.late = val;
      // Captured while alive; see toggleAttending.
      const store = getRoot(self);
      const mealId = self.meal_id;

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
          if (!isAlive(self)) return;
          self.setLate(!val);

          handleAxiosError(error);
        });
    },
    toggleVeg() {
      if (self.attending === false) {
        self.toggleAttending({ toggleVeg: true });
        return;
      }

      const val = !self.vegetarian;
      self.vegetarian = val;
      // Captured while alive; see toggleAttending.
      const store = getRoot(self);
      const mealId = self.meal_id;

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
          if (!isAlive(self)) return;
          self.setVeg(!val);

          handleAxiosError(error);
        });
    },
    addGuest(options = { vegetarian: false }) {
      // Captured while alive; see toggleAttending.
      const store = getRoot(self);
      const mealId = self.meal_id;
      self.root.meal.decrementExtras();

      api.meals.residents.guests
        .add(self.meal_id, self.id, {
          vegetarian: options.vegetarian,
          socketId: window.Comeals.socketId,
        })
        .then(function (response) {
          evictMealCache(mealId);
          if (!isAlive(self)) {
            // The guest row exists on the server; the refetch brings it
            // back. Without this the user re-clicks and creates a
            // second real guest — a double charge.
            store.loadDataAsync();
            return;
          }
          if (response.status === 200) {
            const guest = response.data;
            guest.created_at = new Date(guest.created_at);
            self.root.appendGuest(guest);
          }
        })
        .catch(function (error) {
          if (!isAlive(self)) return;
          self.root.meal.incrementExtras();

          handleAxiosError(error);
        });
    },
    removeGuest() {
      if (!self.canRemoveGuest) {
        return false;
      }

      // Sort Guests
      const sortedGuests = Array.from(self.guests)
        .slice()
        .sort((a, b) => {
          if (a.created_at > b.created_at) return -1;
          if (a.created_at < b.created_at) return 1;
          return 0;
        });

      // Grab Id of newest guest
      const guestId = sortedGuests[0].id;

      // Captured while alive; see toggleAttending.
      const store = getRoot(self);
      const mealId = self.meal_id;

      api.meals.residents.guests
        .remove(self.meal_id, self.id, guestId, {
          socketId: window.Comeals.socketId,
        })
        .then(function (response) {
          evictMealCache(mealId);
          if (!isAlive(self)) {
            store.loadDataAsync();
            return;
          }
          if (response.status === 200) {
            self.root.removeGuest(guestId);
            self.root.meal.incrementExtras();
          }
        })
        .catch(function (error) {
          handleAxiosError(error);
        });
    },
  }));

export default Resident;
