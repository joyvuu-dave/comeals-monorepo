import { useLocation, useNavigate } from "react-router";
import axios from "axios";
import handleAxiosError from "../../helpers/handle_axios_error";

const styles = {
  sideBar: {
    display: "flex",
    flexDirection: "column",
    justifyContent: "flex-start",
  },
  button: {
    maxWidth: "95vw",
  },
};

function SideBar() {
  const navigate = useNavigate();
  const location = useLocation();

  function openNewGuestRoomReservation() {
    navigate(`${location.pathname}guest-room-reservations/new`);
  }

  function openNewCommonHouseReservation() {
    navigate(`${location.pathname}common-house-reservations/new`);
  }

  function openNewEvent() {
    navigate(`${location.pathname}events/new`);
  }

  function openNextMeal() {
    axios
      .get(`/api/v1/meals/next`)
      .then(function (response) {
        if (response.status === 200) {
          navigate(`/meals/${response.data.meal_id}/edit`);
        }
      })
      .catch(function (error) {
        handleAxiosError(error, { silent: true });
      });
  }

  return (
    <div style={styles.sideBar}>
      <h3 className="mar-sm">Reserve</h3>
      <button
        onClick={openNewGuestRoomReservation}
        className="mar-sm press"
        style={styles.button}
      >
        Guest Room
      </button>
      <button
        onClick={openNewCommonHouseReservation}
        className="mar-sm press"
        style={styles.button}
      >
        Common House
      </button>
      <hr />
      <h3 className="mar-sm">Add</h3>
      <button
        onClick={openNewEvent}
        className="mar-sm button-secondary press"
        style={styles.button}
      >
        Event
      </button>
      <hr />
      <h3 className="mar-sm">Goto</h3>
      <button
        onClick={openNextMeal}
        className="button-info mar-sm press"
        style={styles.button}
      >
        Next Meal
      </button>
    </div>
  );
}

export default SideBar;
