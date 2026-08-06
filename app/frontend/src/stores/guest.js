import { types } from "mobx-state-tree";

const Guest = types.model("Guest", {
  id: types.identifierNumber,
  created_at: types.Date,
  meal_id: types.number,
  resident_id: types.number,
  vegetarian: false,
});

export default Guest;
