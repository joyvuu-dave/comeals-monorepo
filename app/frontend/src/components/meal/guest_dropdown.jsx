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

  function handleClick() {
    setOpen((prevOpen) => !prevOpen);
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
        disabled={reconciled || !canAdd}
      >
        <div
          className="dropdown-add"
          aria-label={`Add Guest of ${resident.name}`}
        />
      </button>
      <div className="dropdown-menu">
        <a onClick={() => resident.addGuest({ vegetarian: false })}>
          <img src={Cow} className="pointer" alt="cow-icon" />
        </a>
        <a onClick={() => resident.addGuest({ vegetarian: true })}>
          <img src={Carrot} className="pointer" alt="carrot-icon" />
        </a>
      </div>
    </div>
  );
}

export default GuestDropdown;
