import { useEffect, useRef, useState } from "react";
import Cow from "../../images/cow.png";
import Carrot from "../../images/carrot.png";

const styles = {
  topButton: {
    marginBottom: "1px",
  },
};

function GuestDropdown({ resident, canAdd, reconciled }) {
  const [open, setOpen] = useState(false);
  const wrapperRef = useRef(null);
  // No guest can be added: the meal has no seat left, or it is
  // reconciled. The props can change while the menu is open (a Pusher
  // refresh), so everything below checks this, not only the button.
  const blocked = reconciled || !canAdd;

  useEffect(function () {
    function handleClickOutside(event) {
      if (wrapperRef.current && !wrapperRef.current.contains(event.target)) {
        setOpen(false);
      }
    }

    document.addEventListener("mousedown", handleClickOutside);
    return function () {
      document.removeEventListener("mousedown", handleClickOutside);
    };
  }, []);

  // The menu closes whenever `blocked` changes: an open menu closes
  // when guests become blocked (issue #116), and it cannot be open
  // while they are blocked, so it stays closed when they are allowed
  // again.
  useEffect(
    function () {
      setOpen(false);
    },
    [blocked],
  );

  // The wrapper, not only the button, takes the click: the disabled
  // button's right margin belongs to the wrapper.
  function handleClick() {
    if (blocked) return;
    setOpen((prevOpen) => !prevOpen);
  }

  // A tap can land on the menu in the render before the effect above
  // closes it.
  function addGuest(vegetarian) {
    if (blocked) return;
    resident.addGuest({ vegetarian: vegetarian });
  }

  return (
    <div
      ref={wrapperRef}
      className={
        open ? "dropdown dropdown-left active" : "dropdown dropdown-left"
      }
      onClick={handleClick}
    >
      <button
        key={`dropdown_${resident.id}`}
        className="mar-r-sm"
        style={styles.topButton}
        disabled={blocked}
      >
        <div
          className="dropdown-add"
          aria-label={`Add Guest of ${resident.name}`}
        />
      </button>
      <div className="dropdown-menu">
        <a onClick={() => addGuest(false)}>
          <img src={Cow} className="pointer" alt="cow-icon" />
        </a>
        <a onClick={() => addGuest(true)}>
          <img src={Carrot} className="pointer" alt="carrot-icon" />
        </a>
      </div>
    </div>
  );
}

export default GuestDropdown;
