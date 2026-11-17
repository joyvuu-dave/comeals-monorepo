import { useEffect, useRef, useState } from "react";
import Cow from "../../images/cow.png";
import Carrot from "../../images/carrot.png";

const styles = {
  topButton: {
    marginBottom: "1px",
  },
};

function GuestDropdown({ resident, canAdd, frozen, addWaiting }) {
  const [open, setOpen] = useState(false);
  const wrapperRef = useRef(null);
  const toggleRef = useRef(null);
  // No guest can be added: the meal has no seat left, or it is settled
  // or cancelled. The button looks disabled.
  const blocked = frozen || !canAdd;
  // The control takes no taps. That is so when guests are blocked, and
  // also while this host's guest add waits for its answer, so a second
  // tap cannot send a second guest (S4). While the add waits, the button
  // keeps its look: the disabled look says no guest can be added, and
  // the page has no look for "waiting" here. aria-disabled tells a
  // screen reader. The props can change while the menu is open (a
  // Pusher refresh), so everything below checks this, not only the
  // button.
  const locked = blocked || addWaiting;

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

  // The menu closes whenever `locked` changes: an open menu closes
  // when guests become blocked (issue #116), and it cannot be open
  // while the control is locked, so it stays closed when it takes taps
  // again.
  useEffect(
    function () {
      setOpen(false);
    },
    [locked],
  );

  // The wrapper, not only the button, takes the click: the disabled
  // button's right margin belongs to the wrapper.
  function handleClick() {
    if (locked) return;
    setOpen((prevOpen) => !prevOpen);
  }

  // A tap can land on the menu in the render before the effect above
  // closes it.
  function addGuest(vegetarian) {
    if (locked) return;
    resident.addGuest({ vegetarian: vegetarian });
    // The click also reaches the wrapper, which closes the menu, and a
    // hidden button cannot keep the focus. Put it back on + Guest, so a
    // keyboard user is where they started.
    toggleRef.current.focus();
  }

  // Escape closes the menu and puts the focus back on + Guest.
  function handleKeyDown(event) {
    if (event.key !== "Escape" || !open) return;
    event.stopPropagation();
    setOpen(false);
    toggleRef.current.focus();
  }

  // Tab out of the menu closes it, as a click outside does. Only when
  // the focus went to another element: Safari does not focus a button
  // that is clicked, so a click on a menu item can blur + Guest with no
  // element to go to, and closing then would hide the item before the
  // click lands on it. The mousedown listener above handles clicks.
  function handleBlur(event) {
    const next = event.relatedTarget;
    if (next && !wrapperRef.current.contains(next)) setOpen(false);
  }

  return (
    <div
      ref={wrapperRef}
      className={
        open ? "dropdown dropdown-left active" : "dropdown dropdown-left"
      }
      onClick={handleClick}
      onKeyDown={handleKeyDown}
      onBlur={handleBlur}
    >
      <button
        ref={toggleRef}
        type="button"
        key={`dropdown_${resident.id}`}
        className="mar-r-sm"
        style={styles.topButton}
        disabled={blocked}
        aria-disabled={locked}
        aria-label={`Add Guest of ${resident.name}`}
        aria-expanded={open}
      >
        <div className="dropdown-add" aria-hidden="true" />
      </button>
      {/* Plain buttons, so Tab reaches them while the menu is open. The
          button's label is what a screen reader says; the image's alt
          text is not read. */}
      <div className="dropdown-menu">
        <button
          type="button"
          aria-label={`Add a guest of ${resident.name} who eats meat`}
          onClick={() => addGuest(false)}
        >
          <img src={Cow} className="pointer" alt="cow-icon" />
        </button>
        <button
          type="button"
          aria-label={`Add a vegetarian guest of ${resident.name}`}
          onClick={() => addGuest(true)}
        >
          <img src={Carrot} className="pointer" alt="carrot-icon" />
        </button>
      </div>
    </div>
  );
}

export default GuestDropdown;
